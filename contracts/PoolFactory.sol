// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Timestamp } from "./base/Timestamp.sol";
import { Errors } from "./libraries/Errors.sol";
// import { CorePool } from "./CorePool.sol";
import { ICorePool } from "./interfaces/ICorePool.sol";
import { IERC20Mintable } from "./interfaces/IERC20Mintable.sol";
import { IFactory } from "./interfaces/IFactory.sol";

import "hardhat/console.sol";

/**
 * @title Pool Factory V2
 *
 * @notice ILV Pool Factory manages Illuvium Yield farming pools, provides a single
 *      public interface to access the pools, provides an interface for the pools
 *      to mint yield rewards, access pool-related info, update weights, etc.
 *
 * @notice The factory is authorized (via its owner) to register new pools, change weights
 *      of the existing pools, removing the pools (by changing their weights to zero)
 *
 * @dev The factory requires ROLE_TOKEN_CREATOR permission on the ILV token to mint yield
 *      (see `mintYieldTo` function)
 *
 */
contract PoolFactory is UUPSUpgradeable, OwnableUpgradeable, Timestamp {
    // err lib used on fn selectors
    using Errors for bytes4;

    /// @dev Auxiliary data structure used only in getPoolData() view function
    struct PoolData {
        // @dev pool token address (like ILV)
        address poolToken;
        // @dev pool address (like deployed core pool instance)
        address poolAddress;
        // @dev pool weight (200 for ILV pools, 800 for ILV/ETH pools - set during deployment)
        uint32 weight;
        // @dev flash pool flag
        bool isFlashPool;
    }

    /// @dev TODO: set correct UID
    uint256 public constant FACTORY_UID = 0xc5cfd88c6e4d7e5c8a03c255f03af23c0918d8e82cac196f57466af3fd4a5ec7;

    uint192 public ilvPerSecond;

    uint32 public totalWeight;

    uint32 public secondsPerUpdate;

    uint32 public endTime;

    uint32 public lastRatioUpdate;

    address public ilv;

    address public silv;

    mapping(address => address) public pools;

    mapping(address => bool) public poolExists;

    /**
     * @dev Fired in registerPool()
     *
     * @param by an address which executed an action
     * @param poolToken pool token address (like ILV)
     * @param poolAddress deployed pool instance address
     * @param weight pool weight
     * @param isFlashPool flag indicating if pool is a flash pool
     */
    event LogRegisterPool(
        address indexed by,
        address indexed poolToken,
        address indexed poolAddress,
        uint64 weight,
        bool isFlashPool
    );

    /**
     * @dev Fired in changePoolWeight()
     *
     * @param by an address which executed an action
     * @param poolAddress deployed pool instance address
     * @param weight new pool weight
     */
    event LogChangePoolWeight(address indexed by, address indexed poolAddress, uint32 weight);

    /**
     * @dev Fired in updateILVPerSecond()
     *
     * @param by an address which executed an action
     * @param newIlvPerSecond new ILV/second value
     */
    event LogUpdateILVPerSecond(address indexed by, uint256 newIlvPerSecond);

    /**
     * @dev Fired in setEndTime()
     *
     * @param by an address which executed the action
     * @param endTime new endTime value
     */
    event LogSetEndTime(address indexed by, uint32 endTime);

    /**
     * @dev Initializes a factory instance
     *
     * @param _ilv ILV ERC20 token address
     * @param _silv sILV ERC20 token address
     * @param _ilvPerSecond initial ILV/second value for rewards
     * @param _secondsPerUpdate how frequently the rewards gets updated (decreased by 3%), seconds
     * @param _initTime timestamp to measure _secondsPerUpdate from
     * @param _endTime timestamp number when farming stops and rewards cannot be updated anymore
     */

    function initialize(
        address _ilv,
        address _silv,
        uint192 _ilvPerSecond,
        uint32 _secondsPerUpdate,
        uint32 _initTime,
        uint32 _endTime
    ) external initializer {
        // we're using selector to simplify input and state validation
        bytes4 fnSelector = PoolFactory(this).initialize.selector;

        // verify the inputs are set
        fnSelector.verifyNonZeroInput(_ilv, 0);
        fnSelector.verifyNonZeroInput(_silv, 1);
        fnSelector.verifyNonZeroInput(_ilvPerSecond, 2);
        fnSelector.verifyNonZeroInput(_secondsPerUpdate, 3);
        fnSelector.verifyNonZeroInput(_initTime, 4);
        fnSelector.verifyInput(_endTime > _initTime, 5);

        __Ownable_init();

        // save the inputs into internal state variables
        ilv = _ilv;
        silv = _silv;
        ilvPerSecond = _ilvPerSecond;
        secondsPerUpdate = _secondsPerUpdate;
        lastRatioUpdate = _initTime;
        endTime = _endTime;
    }

    function getPoolAddress(address poolToken) external view returns (address) {
        // read the mapping and return
        return address(pools[poolToken]);
    }

    function getPoolData(address _poolToken) public view returns (PoolData memory) {
        // get the pool address from the mapping
        ICorePool pool = ICorePool(pools[_poolToken]);

        // throw if there is no pool registered for the token specified
        PoolFactory(this).getPoolData.selector.verifyNonZeroInput(pools[_poolToken], 0);

        // read pool information from the pool smart contract
        // via the pool interface (ICorePool)
        address poolToken = pool.poolToken();
        bool isFlashPool = pool.isFlashPool();
        uint32 weight = pool.weight();

        // create the in-memory structure and return it
        return PoolData({ poolToken: poolToken, poolAddress: address(pool), weight: weight, isFlashPool: isFlashPool });
    }

    function shouldUpdateRatio() public view returns (bool) {
        // if yield farming period has ended
        if (_now256() > endTime) {
            // ILV/second reward cannot be updated anymore
            return false;
        }

        // check if seconds/update have passed since last update
        return _now256() >= lastRatioUpdate + secondsPerUpdate;
    }

    function registerPool(address pool) public onlyOwner {
        // read pool information from the pool smart contract
        // via the pool interface (ICorePool)
        address poolToken = ICorePool(pool).poolToken();
        bool isFlashPool = ICorePool(pool).isFlashPool();
        uint32 weight = ICorePool(pool).weight();

        // create pool structure, register it within the factory
        pools[poolToken] = pool;
        poolExists[pool] = true;
        // update total pool weight of the factory
        totalWeight += weight;

        // emit an event
        emit LogRegisterPool(msg.sender, poolToken, address(pool), weight, isFlashPool);
    }

    function updateILVPerSecond() external {
        // checks if ratio can be updated i.e. if seconds/update have passed
        require(shouldUpdateRatio(), "too frequent");

        // decreases ILV/second reward by 3%
        ilvPerSecond = (ilvPerSecond * 97) / 100;

        // set current timestamp as the last ratio update timestamp
        lastRatioUpdate = uint32(_now256());

        // emit an event
        emit LogUpdateILVPerSecond(msg.sender, ilvPerSecond);
    }

    function mintYieldTo(
        address _to,
        uint256 _value,
        bool _useSILV
    ) external {
        // verify that sender is a pool registered withing the factory
        require(poolExists[msg.sender], "access denied");

        if (!_useSILV) {
            IERC20Mintable(ilv).mint(_to, _value);
        } else {
            IERC20Mintable(silv).mint(_to, _value);
        }
    }

    function changePoolWeight(address pool, uint32 weight) external {
        // verify function is executed either by factory owner or by the pool itself
        require(msg.sender == owner() || poolExists[msg.sender]);

        // recalculate total weight
        totalWeight = totalWeight + weight - ICorePool(pool).weight();

        // set the new pool weight
        ICorePool(pool).setWeight(weight);

        // emit an event
        emit LogChangePoolWeight(msg.sender, address(pool), weight);
    }

    function setEndTime(uint32 _endTime) external onlyOwner {
        require(_endTime > lastRatioUpdate, "invalid _endTime");
        endTime = _endTime;

        emit LogSetEndTime(msg.sender, _endTime);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
