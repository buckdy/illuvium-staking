// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import { ICorePool } from "./interfaces/ICorePool.sol";
import { ICorePoolV1 } from "./interfaces/ICorePoolV1.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import { IUniswapV2Router02 } from "./interfaces/IUniswapV2Router02.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Illuvium Vault.
 *
 * @dev The Vault is responsible to gather revenue from the protocol, swap to ILV
 *      periodically and distribute to core pool users from time to time.
 * @dev The contract connects with Sushi's router in order to buy ILV from the
 *      ILV/ETH liquidity pool.
 * @dev Since we can change the vault address in the staking pools (see VaultRecipient),
 *      the Vault contract doesn't need to implement upgradeability.
 * @dev It receives ETH from the receive() function and allows conversion to ILV by
 *      the address with the role ROLE_VAULT_MANAGER (0x0001_0000). This conversion
 *      can be done in multiple steps, which means it doesn’t require converting
 *      all ETH balance in 1 function call. The vault is also responsible to be
 *      calling receiveVaultRewards() function in the core pools, which takes care
 *      of calculations of how much ILV should be sent to each pool as revenue distribution.
 *
 */
contract Vault is Ownable {
    /**
     * @dev Auxiliary data structure to store ILV, LP and Locked pools,
     *      linked to this smart contract and receiving vault rewards
     */
    struct Pools {
        ICorePoolV1 ilvPoolV1;
        ICorePoolV1 pairPoolV1;
        ICorePool ilvPool;
        ICorePool pairPool;
        ICorePool lockedPoolV1;
        ICorePool lockedPoolV2;
    }

    /**
     * @dev struct with each core pool address
     */
    Pools public pools;

    /**
     * @dev Link to Sushiswap's router deployed instance
     */
    IUniswapV2Router02 public sushiRouter;

    /**
     * @dev Link to IlluviumERC20 token deployed instance
     */
    IERC20Upgradeable public ilv;

    /**
     * @dev Internal multiplier used to calculate amount to send
     *      to each staking pool
     */
    uint256 internal constant AMOUNT_TO_SEND_MULTIPLIER = 1e12;

    /**
     * @dev Fired in _swapEthForIlv() and sendIlvRewards() (via swapEthForIlv)
     *
     * @param by an address which executed the function
     * @param ethSpent ETH amount sent to Sushiswap
     * @param ilvReceived ILV amount received from Sushiswap
     */
    event LogSwapEthForILV(address indexed by, uint256 ethSpent, uint256 ilvReceived);

    /**
     * @dev Fired in sendIlvRewards()
     *
     * @param by an address which executed the function
     * @param value ILV amount sent to the pool
     */
    event LogSendILVRewards(address indexed by, uint256 value);

    /**
     * @dev Fired in default payable receive()
     *
     * @param by an address which sent ETH into the vault (this contract)
     * @param value ETH amount received
     */
    event LogEthReceived(address indexed by, uint256 value);

    /**
     * @dev Fired in setCorePools()
     *
     * @param by address who executed the setup
     * @param ilvPool deployed ILV core pool address
     * @param pairPool deployed ILV/ETH pair (LP) pool address
     * @param lockedPoolV1 deployed locked pool V1 address
     * @param lockedPoolV2 deployed locked pool V2 address
     */
    event LogSetCorePools(
        address indexed by,
        address ilvPoolV1,
        address pairPoolV1,
        address ilvPool,
        address pairPool,
        address lockedPoolV1,
        address lockedPoolV2
    );

    /**
     * @notice Creates (deploys) Vault linked to Sushi AMM Router and IlluviumERC20 token
     *
     * @param _sushiRouter an address of the IUniswapV2Router02 to use for ETH -> ILV exchange
     * @param _ilv an address of the IlluviumERC20 token to use
     */
    constructor(address _sushiRouter, address _ilv) {
        // verify the inputs are set
        require(_sushiRouter != address(0), "sushiRouter address is not set");
        require(_ilv != address(0), "ILV address is not set");

        // assign the values
        sushiRouter = IUniswapV2Router02(_sushiRouter);
        ilv = IERC20Upgradeable(_ilv);
    }

    /**
     * @dev Auxiliary function used as part of the contract setup process to setup core pools,
     *      executed by `owner()` after deployment
     *
     * @param _ilvPool deployed ILV core pool address
     * @param _pairPool deployed ILV/ETH pair (LP) pool address
     * @param _lockedPoolV1 deployed locked pool V1 address
     * @param _lockedPoolV2 deployed locked pool V2 address
     */
    function setCorePools(
        ICorePoolV1 _ilvPoolV1,
        ICorePoolV1 _pairPoolV1,
        ICorePool _ilvPool,
        ICorePool _pairPool,
        ICorePool _lockedPoolV1,
        ICorePool _lockedPoolV2
    ) external onlyOwner {
        // verify all the pools are set/supplied
        require(address(_ilvPoolV1) != address(0), "ILV pool is not set");
        require(address(_pairPoolV1) != address(0), "ILV pool is not set");
        require(address(_ilvPool) != address(0), "ILV pool is not set");
        require(address(_pairPool) != address(0), "LP pool is not set");
        require(address(_lockedPoolV1) != address(0), "locked pool v1 is not set");
        require(address(_lockedPoolV2) != address(0), "locked pool v2 is not set");

        // set up
        pools.ilvPoolV1 = _ilvPoolV1;
        pools.pairPoolV1 = _pairPoolV1;
        pools.ilvPool = _ilvPool;
        pools.pairPool = _pairPool;
        pools.lockedPoolV1 = _lockedPoolV1;
        pools.lockedPoolV2 = _lockedPoolV2;

        // emit an event
        emit LogSetCorePools(
            msg.sender,
            address(_ilvPoolV1),
            address(_pairPoolV1),
            address(_ilvPool),
            address(_pairPool),
            address(_lockedPoolV1),
            address(_lockedPoolV2)
        );
    }

    /**
     * @notice Exchanges ETH balance present on the contract into ILV via Sushiswap
     *
     * @dev Logs operation via `EthIlvSwapped` event
     *
     * @param _ilvOut expected ILV amount to be received from Sushiswap swap
     * @param _deadline maximum timestamp to wait for Sushiswap swap (inclusive)
     */
    function swapETHForILV(
        uint256 _ethIn,
        uint256 _ilvOut,
        uint256 _deadline
    ) external onlyOwner {
        _swapETHForILV(_ethIn, _ilvOut, _deadline);
    }

    /**
     * @notice Converts an entire contract's ETH balance into ILV via Sushiswap and
     *      sends the entire contract's ILV balance to the Illuvium Yield Pool
     *
     * @dev Uses `swapEthForIlv` internally to exchange ETH -> ILV
     *
     * @dev Logs operation via `RewardsDistributed` event
     *
     * @dev Set `ilvOut` or `deadline` to zero to skip `swapEthForIlv` call
     *
     * @param _ilvOut expected ILV amount to be received from Sushiswap swap
     * @param _deadline maximum timeout to wait for Sushiswap swap
     */
    function sendILVRewards(
        uint256 _ethIn,
        uint256 _ilvOut,
        uint256 _deadline
    ) external onlyOwner {
        // we treat set `ilvOut` and `deadline` as a flag to execute `swapEthForIlv`
        // in the same time we won't execute the swap if contract balance is zero
        if (_ilvOut > 0 && _deadline > 0 && address(this).balance > 0) {
            // exchange ETH on the contract's balance into ILV via Sushi - delegate to `swapEthForIlv`
            _swapETHForILV(_ethIn, _ilvOut, _deadline);
        }

        // reads core pools
        (
            ICorePoolV1 ilvPoolV1,
            ICorePoolV1 pairPoolV1,
            ICorePool ilvPool,
            ICorePool pairPool,
            ICorePool lockedPoolV1,
            ICorePool lockedPoolV2
        ) = (pools.ilvPoolV1, pools.pairPoolV1, pools.ilvPool, pools.pairPool, pools.lockedPoolV1, pools.lockedPoolV2);

        // read contract's ILV balance
        uint256 ilvBalance = ilv.balanceOf(address(this));
        // approve the entire ILV balance to be sent into the pool
        if (ilv.allowance(address(this), address(ilvPool)) < ilvBalance) {
            ilv.approve(address(ilvPool), type(uint256).max);
        }
        if (ilv.allowance(address(this), address(pairPool)) < ilvBalance) {
            ilv.approve(address(pairPool), type(uint256).max);
        }
        if (ilv.allowance(address(this), address(lockedPoolV1)) < ilvBalance) {
            ilv.approve(address(lockedPoolV1), type(uint256).max);
        }
        if (ilv.allowance(address(this), address(lockedPoolV2)) < ilvBalance) {
            ilv.approve(address(lockedPoolV2), type(uint256).max);
        }

        // gets poolToken reserves in each pool
        uint256 reserve0 = ilvPool.poolTokenReserve() + ilvPoolV1.poolTokenReserve();
        uint256 reserve1 = estimatePairPoolReserve(address(pairPool)) + estimatePairPoolReserve(address(pairPoolV1));
        uint256 reserve2 = lockedPoolV1.poolTokenReserve();
        uint256 reserve3 = lockedPoolV2.poolTokenReserve();

        // ILV in ILV core pool + ILV in ILV/ETH core pool representation + ILV in locked pool
        uint256 totalReserve = reserve0 + reserve1 + reserve2 + reserve3;

        // amount of ILV to send to ILV core pool
        uint256 amountToSend0 = _getAmountToSend(ilvBalance, reserve0, totalReserve);
        // amount of ILV to send to ILV/ETH core pool
        uint256 amountToSend1 = _getAmountToSend(ilvBalance, reserve1, totalReserve);
        // amount of ILV to send to locked ILV core pool V1
        uint256 amountToSend2 = _getAmountToSend(ilvBalance, reserve2, totalReserve);
        // amount of ILV to send to locked ILV core pool V2
        uint256 amountToSend3 = _getAmountToSend(ilvBalance, reserve3, totalReserve);

        // makes sure we are sending a valid amount
        assert(amountToSend0 + amountToSend1 + amountToSend2 + amountToSend3 <= ilvBalance);

        // sends ILV to both core pools
        ilvPool.receiveVaultRewards(amountToSend0);
        pairPool.receiveVaultRewards(amountToSend1);
        lockedPoolV1.receiveVaultRewards(amountToSend2);
        lockedPoolV2.receiveVaultRewards(amountToSend3);

        // emit an event
        emit LogSendILVRewards(msg.sender, ilvBalance);
    }

    /**
     * @dev Auxiliary function used to estimate LP core pool share among the other core pools.
     *
     * @dev Expected to estimate how much ILV is represented by the number of LP tokens staked
     *      in the pair pool in order to determine how much revenue distribution should be allocated
     *      to the Sushi LP pool.
     *
     * @param _pairPool LP core pool extracted from pools structure (gas saving optimization)
     * @return ilvAmount ILV estimate of the LP pool share among the other pools
     */
    function estimatePairPoolReserve(address _pairPool) public view returns (uint256 ilvAmount) {
        // 1. Store the amount of LP tokens staked in the ILV/ETH pool
        //    and the LP token total supply (total amount of LP tokens in circulation).
        //    With these two values we will be able to estimate how much ILV each LP token
        //    is worth.
        uint256 lpAmount = ICorePool(_pairPool).poolTokenReserve();
        uint256 lpTotal = IERC20Upgradeable(ICorePool(_pairPool).poolToken()).totalSupply();

        // 2. We check how much ILV the LP token contract holds, that way
        //    based on the total value of ILV tokens represented by the total
        //    supply of LP tokens, we are able to calculate through a simple rule
        //    of 3 how much ILV the amount of staked LP tokens represent.
        uint256 ilvTotal = ilv.balanceOf(ICorePool(_pairPool).poolToken());
        // we store the result
        ilvAmount = (ilvTotal * lpAmount) / lpTotal;
    }

    /**
     * @dev Auxiliary function to calculate amount of rewards to send to the pool
     *      based on ILV rewards available to be split between the pools,
     *      particular pool reserve and total reserve of all the pools
     *
     * @dev A particular pool receives an amount proportional to its reserves
     *
     * @param _ilvBalance available amount of rewards to split between the pools
     * @param _poolReserve particular pool reserves
     * @param _totalReserve total cumulative reserves of all the pools to split rewards between
     */
    function _getAmountToSend(
        uint256 _ilvBalance,
        uint256 _poolReserve,
        uint256 _totalReserve
    ) private pure returns (uint256) {
        return (_ilvBalance * ((_poolReserve * AMOUNT_TO_SEND_MULTIPLIER) / _totalReserve)) / AMOUNT_TO_SEND_MULTIPLIER;
    }

    function _swapETHForILV(
        uint256 _ethIn,
        uint256 _ilvOut,
        uint256 _deadline
    ) private {
        // verify the inputs
        require(_ilvOut > 0, "zero input (ilvOut)");
        require(_deadline >= block.timestamp, "deadline expired");

        // checks if there's enough balance

        require(address(this).balance > _ethIn, "zero ETH balance");

        // create and initialize path array to be used in Sushiswap
        // first element of the path determines an input token (what we send to Sushiswap),
        // last element determines output token (what we receive from uniwsap)
        address[] memory path = new address[](2);
        // we send ETH wrapped as WETH into Sushiswap
        path[0] = sushiRouter.WETH();
        // we receive ILV from Sushiswap
        path[1] = address(ilv);

        // exchange ETH -> ILV via Sushiswap
        uint256[] memory amounts = sushiRouter.swapExactETHForTokens{ value: _ethIn }(
            _ilvOut,
            path,
            address(this),
            _deadline
        );

        // emit an event logging the operation
        emit LogSwapEthForILV(msg.sender, amounts[0], amounts[1]);
    }

    /**
     * @notice Default payable function, allows to top up contract's ETH balance
     *      to be exchanged into ILV via Sushiswap
     *
     * @dev Logs operation via `LogEthReceived` event
     */
    receive() external payable {
        // emit an event
        emit LogEthReceived(msg.sender, msg.value);
    }
}
