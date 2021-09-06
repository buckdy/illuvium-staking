// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import { FactoryControlled } from "./FactoryControlled.sol";

abstract contract VaultRecipient is FactoryControlled {
    /// @dev Link to deployed IlluviumVault instance
    address public vault;

    /// @dev Used to calculate vault rewards
    /// @dev This value is different from "reward per token" used in locked pool
    /// @dev Note: stakes are different in duration and "weight" reflects that
    uint256 public vaultRewardsPerWeight;

    /**
     * @dev Fired in setVault()
     *
     * @param by an address which executed the function, always a factory owner
     * @param previousVault previous vault contract address
     * @param newVault new vault address
     */
    event LogSetVault(address indexed by, address previousVault, address newVault);

    modifier onlyVault() {
        require(msg.sender == vault, "Unauthorized");
        _;
    }

    /**
     * @dev Executed only by the factory owner to Set the vault
     *
     * @param _vault an address of deployed IlluviumVault instance
     */
    function setVault(address _vault) external {
        // verify function is executed by the factory owner
        require(factory.owner() == msg.sender, "access denied");

        // verify input is set
        require(_vault != address(0), "zero input");

        // saves current vault to memory
        address previousVault = vault;

        // update vault address
        vault = _vault;

        // emit an event
        emit LogSetVault(msg.sender, previousVault, _vault);
    }
}