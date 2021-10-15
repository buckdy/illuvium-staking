// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import { ICorePoolV1 } from "../interfaces/ICorePoolV1.sol";
import { Errors } from "../libraries/Errors.sol";
import { Stake } from "../libraries/Stake.sol";
import { CorePool } from "./CorePool.sol";

abstract contract V2Migrator is CorePool {
    using Errors for bytes4;
    using Stake for uint256;

    /// @dev stores maximum timestamp of a v1 stake accepted in v2
    uint256 public v1StakeMaxPeriod;

    /**
     * @dev logs migrateLockedStake()
     *
     * @param from user address
     * @param stakeIds array of locked stakes ids
     *
     */
    event LogMigrateLockedStake(address indexed from, uint256[] stakeIds);

    /**
     * @dev V2Migrator initializer function
     *
     * @param _corePoolV1 v1 core pool address
     *
     */
    function __V2Migrator_init(
        address _ilv,
        address _silv,
        address _poolToken,
        address _factory,
        uint64 _initTime,
        uint32 _weight,
        address _corePoolV1,
        uint256 _v1StakeMaxPeriod
    ) internal initializer {
        __CorePool_init(_ilv, _silv, _poolToken, _factory, _initTime, _weight);

        corePoolV1 = _corePoolV1;
        v1StakeMaxPeriod = _v1StakeMaxPeriod;
    }

    /**
     * @dev reads v1 core pool locked stakes data (by looping through the `_stakeIds` array),
     *      checks if it's a valid v1 stake to migrate and save the id to v2 user struct
     *
     * @notice only `msg.sender` can migrate v1 stakes to v2
     *
     * @param _stakeIds array of v1 stake ids
     */
    function migrateLockedStake(uint256[] calldata _stakeIds) external {
        User storage user = users[msg.sender];

        // uses v1 weight values for rewards calculations
        (uint256 v1WeightToAdd, uint256 subYieldRewards, uint256 subVaultRewards) = _useV1Weight(msg.sender);
        // update user state
        _processRewards(msg.sender, v1WeightToAdd, subYieldRewards, subVaultRewards);

        // we're using selector to simplify input and state validation
        bytes4 fnSelector = V2Migrator(this).migrateLockedStake.selector;

        uint256 totalV1WeightAdded;

        for (uint256 i = 0; i < _stakeIds.length; i++) {
            (, uint256 _weight, uint64 lockedFrom, , bool isYield) = ICorePoolV1(corePoolV1).getDeposit(
                msg.sender,
                _stakeIds[i]
            );
            fnSelector.verifyState(lockedFrom <= v1StakeMaxPeriod, i * 3);
            fnSelector.verifyState(lockedFrom > 0 && !isYield, i * 3 + 1);
            fnSelector.verifyState(v1StakesWeights[msg.sender][_stakeIds[i]] == 0, i * 3 + 2);

            v1StakesWeights[msg.sender][_stakeIds[i]] = _weight;
            v1StakesWeightsOriginal[msg.sender][_stakeIds[i]] = _weight;
            totalV1WeightAdded += _weight;
            user.v1IdsLength++;
            user.v1StakesIds[i] = _stakeIds[i];
        }

        // gas savings
        uint256 userTotalWeight = (user.totalWeight + v1WeightToAdd);

        // resets all rewards after migration
        user.subYieldRewards = userTotalWeight.weightToReward(yieldRewardsPerWeight);
        user.subVaultRewards = userTotalWeight.weightToReward(vaultRewardsPerWeight);

        // emit an event
        emit LogMigrateLockedStake(msg.sender, _stakeIds);
    }
}
