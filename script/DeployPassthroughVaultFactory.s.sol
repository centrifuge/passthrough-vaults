// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

import {PassthroughVaultFactory} from "../src/PassthroughVault.sol";

/// @notice Deploys PassthroughVaultFactory deterministically via CREATE2 (broadcast through the canonical
///         0x4e59...b4956c deployer), so the factory lands at the same address on every chain. The address
///         depends only on the salt and init code, not on the deploying account, so build every chain from the
///         same commit and compiler settings (foundry.toml) to keep the addresses aligned.
contract DeployPassthroughVaultFactory is Script {
    /// @dev keccak256("centrifuge-passthrough-vaults")
    bytes32 internal constant SALT = 0xff246eb3a4bad57747cfaa3204079e568f51475cf617a2a33c14c7f0906b5a65;

    function run() external returns (PassthroughVaultFactory factory) {
        vm.startBroadcast();
        factory = new PassthroughVaultFactory{salt: SALT}();
        vm.stopBroadcast();
    }
}
