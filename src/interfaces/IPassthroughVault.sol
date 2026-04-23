// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IERC7714} from "protocol/misc/interfaces/IERC7540.sol";

/// @notice Combined deposit and redeem FIFO queue state for a single investor
struct Position {
    uint128 depositRangeStart; /// global deposit queue index (in assets) at which this investor's segment begins
    uint128 depositPending; /// assets currently in this investor's deposit queue segment
    uint128 redeemRangeStart; /// global redeem queue index (in shares) at which this investor's segment begins
    uint128 redeemPending; /// shares currently in this investor's redeem queue segment
}

/// @title  IPassthroughVault
/// @notice Sync deposit + ERC-7540 async redeem pass-through vault.
/// @dev    The passthrough vault is the sole controller/owner in the underlying Centrifuge vault.
///         Investors hold the underlying share token directly and interact only with this contract.
///         Partially compatible with IERC7575 (no previewWithdraw/previewRedeem) and IERC7540
///         (no operator delegation).
interface IPassthroughVault is IERC7714 {
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event DepositRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );

    error InvalidOwner();
    error InvalidController();
    error NotMember();
    error InsufficientClaimableShares();
    error PermissionlessClaimingNotAllowed();

    //----------------------------------------------------------------------------------------------
    // Immutables
    //----------------------------------------------------------------------------------------------

    function asset() external view returns (address);
    function share() external view returns (address);

    /// @notice Optional memberlist contract controlling which addresses may interact
    /// @dev Returns the zero address when no memberlist is configured (all addresses permitted)
    function memberlist() external view returns (IERC7714);

    /// @notice Whether anyone may call claimRedeemFor on behalf of a controller
    function allowPermissionlessClaiming() external view returns (bool);

    //----------------------------------------------------------------------------------------------
    // Sync deposit
    //----------------------------------------------------------------------------------------------

    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function maxDeposit(address receiver) external view returns (uint256);
    function maxMint(address receiver) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewMint(uint256 shares) external view returns (uint256);

    //----------------------------------------------------------------------------------------------
    // Async deposit
    //----------------------------------------------------------------------------------------------

    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId);

    /// @notice Claim settled deposit shares by specifying the corresponding asset amount
    function deposit(uint256 assets, address receiver, address controller) external returns (uint256 shares);

    /// @notice Claim settled deposit shares directly by share amount
    function mint(uint256 shares, address receiver, address controller) external returns (uint256 assets);

    /// @notice Claims all claimable deposit shares for `controller` and forwards them to `controller`.
    ///         Reverts if allowPermissionlessClaiming is false.
    function claimDepositFor(address controller) external returns (uint256 shares);

    function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256 pendingAssets);
    function claimableDepositRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 claimableAssets);

    //----------------------------------------------------------------------------------------------
    // Async redeem
    //----------------------------------------------------------------------------------------------

    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);
    function withdraw(uint256 assets, address receiver, address controller) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets);

    /// @notice Claims all claimable redeem assets for `controller` and forwards them to `controller`.
    ///         Reverts if allowPermissionlessClaiming is false.
    function claimRedeemFor(address controller) external returns (uint256 assets);

    function maxWithdraw(address controller) external view returns (uint256);
    function maxRedeem(address controller) external view returns (uint256);
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 pendingShares);
    function claimableRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 claimableShares);

    //----------------------------------------------------------------------------------------------
    // Views
    //----------------------------------------------------------------------------------------------

    function totalAssets() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);

    /// @notice Cumulative shares ever claimed from the async deposit queue
    function totalDepositClaimed() external view returns (uint128);

    /// @notice Cumulative assets ever enqueued for async deposit
    function cumulativeDepositRequested() external view returns (uint128);

    /// @notice Cumulative shares ever redeemed from the underlying vault by this passthrough vault
    function totalRedeemClaimed() external view returns (uint128);

    /// @notice Cumulative shares ever submitted for redemption by investors through this vault
    function cumulativeRedeemRequested() external view returns (uint128);

    /// @notice Returns the combined deposit and redeem queue position for a given investor
    function position(address controller)
        external
        view
        returns (
            uint128 depositRangeStart,
            uint128 depositPending,
            uint128 redeemRangeStart,
            uint128 redeemPending
        );
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
