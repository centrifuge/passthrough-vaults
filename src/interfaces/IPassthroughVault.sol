// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IERC7575} from "protocol/misc/interfaces/IERC7575.sol";
import {IERC7540Redeem, IERC7714} from "protocol/misc/interfaces/IERC7540.sol";

/// @notice Tracks an investor's position in the global FIFO redeem queue
struct RedeemPosition {
    uint128 rangeStart; /// global queue index at which this investor's segment begins
    uint128 pending; /// shares currently in this investor's queue segment
}

/// @title  IPassthroughRedeemVault
/// @notice Subset of IERC7540Redeem without the operator extension. Used by the passthrough vault
///         which does not support per-investor operator delegation.
interface IAsyncRedeemVault {
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );

    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);

    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 pendingShares);

    function claimableRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 claimableShares);
}

/// @title  IPassthroughVault
/// @notice Sync deposit + ERC-7540 async redeem pass-through vault.
/// @dev    The passthrough vault is the sole controller/owner in the underlying Centrifuge vault.
///         Investors hold the underlying share token directly and interact only with this contract.
interface IPassthroughVault is IAsyncRedeemVault, IERC7575, IERC7714 {
    error InvalidOwner();
    error InvalidController();
    error NotMember();
    error InsufficientClaimableShares();
    error PermissionlessClaimingNotAllowed();

    /// @notice Optional memberlist contract controlling which addresses may interact
    /// @dev Returns the zero address when no memberlist is configured (all addresses permitted)
    /// @return The memberlist contract, or address(0) if unrestricted
    function memberlist() external view returns (IERC7714);

    /// @notice Whether anyone may call claimRedeemFor on behalf of a controller
    function allowPermissionlessClaiming() external view returns (bool);

    /// @notice Claims all claimable redeem assets for `controller` and forwards them to `controller`.
    ///         Reverts if allowPermissionlessClaiming is false.
    function claimRedeemFor(address controller) external returns (uint256 assets);

    /// @notice Cumulative shares ever redeemed from the underlying vault by this passthrough vault
    /// @return Total shares redeemed from the underlying vault across all time
    function totalRedeemed() external view returns (uint128);

    /// @notice Cumulative shares ever submitted for redemption by investors through this vault
    /// @return Total shares ever requested for redemption
    function cumulativeRedeemRequested() external view returns (uint128);

    /// @notice Returns the FIFO redeem queue position for a given investor
    /// @param controller The investor address
    /// @return rangeStart Global queue index at which this investor's segment begins
    /// @return pending Shares currently in this investor's queue segment
    function redeemPosition(address controller) external view returns (uint128 rangeStart, uint128 pending);
}

/// @title  IPassthroughVaultFactory
/// @notice Factory for deploying passthrough vault contracts
interface IPassthroughVaultFactory {
    /// @notice Deploys a new passthrough vault wrapping `vault`
    function newVault(address vault, address memberlist, bool allowPermissionlessClaiming)
        external
        returns (IPassthroughVault);

    /// @notice Returns the deterministic address a vault would be deployed to without deploying it
    function getVaultAddress(address vault, address memberlist, bool allowPermissionlessClaiming)
        external
        view
        returns (address);
}
