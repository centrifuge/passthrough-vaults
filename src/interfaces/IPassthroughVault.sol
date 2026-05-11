// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IERC7714} from "protocol/misc/interfaces/IERC7540.sol";
import {QueuePosition, QueueLib} from "../libraries/QueueLib.sol";

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
    error InsufficientClaimable();
    error AsyncDepositDisabled();

    //----------------------------------------------------------------------------------------------
    // Immutables
    //----------------------------------------------------------------------------------------------

    function asset() external view returns (address);
    function share() external view returns (address);

    /// @notice Optional memberlist contract controlling which addresses may interact
    /// @dev Returns the zero address when no memberlist is configured (all addresses permitted)
    function memberlist() external view returns (IERC7714);

    /// @notice When true, 2-arg and 3-arg deposit claim from the async deposit queue;
    ///         when false, they perform an immediate sync deposit into the underlying vault.
    function asyncDeposit() external view returns (bool);

    /// @notice When true, anyone may call deposit/redeem on behalf of a controller,
    ///         provided the receiver equals the controller.
    function claimForAll() external view returns (bool);

    //----------------------------------------------------------------------------------------------
    // Deposit (sync or async claim)
    //----------------------------------------------------------------------------------------------

    /// @notice Sync deposit (asyncDeposit=false) or claim from settled async deposit queue (asyncDeposit=true).
    ///         Pass type(uint256).max as assets to claim everything claimable.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    /// @notice 3-arg variant allowing a third party to claim when claimForAll is set (receiver must equal controller).
    function deposit(uint256 assets, address receiver, address controller) external returns (uint256 shares);

    /// @notice Max assets depositable/claimable via deposit().
    ///         When asyncDeposit=false: delegates to the underlying vault.
    ///         When asyncDeposit=true: claimable queue balance in assets, or 0 if nothing is pending.
    function maxDeposit(address controller) external view returns (uint256);

    /// @notice Preview shares out for a sync deposit. Not meaningful for async deposit — use claimableDepositRequest.
    function previewDeposit(uint256 assets) external view returns (uint256);

    //----------------------------------------------------------------------------------------------
    // Async deposit request
    //----------------------------------------------------------------------------------------------

    /// @notice Submit an async deposit request. Reverts when asyncDeposit is false — use deposit() instead.
    /// @dev    controller and owner must equal msg.sender. Force-claims any settled balance before re-queuing.
    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId);

    /// @notice Assets still queued and not yet claimable for controller
    function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256 pendingAssets);

    /// @notice Assets settled and available to claim via deposit() for controller
    function claimableDepositRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 claimableAssets);

    //----------------------------------------------------------------------------------------------
    // Async redeem
    //----------------------------------------------------------------------------------------------

    /// @notice Submit an async redeem request. controller and owner must equal msg.sender.
    /// @dev    Force-claims any settled balance before re-queuing.
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);

    /// @notice Claim settled redemption proceeds. Pass type(uint256).max to claim everything claimable.
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets);

    /// @notice Max shares claimable via redeem() for controller
    function maxRedeem(address controller) external view returns (uint256);

    /// @notice Shares still queued and not yet claimable for controller
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 pendingShares);

    /// @notice Shares settled and available to claim via redeem() for controller
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

    /// @notice Cumulative assets ever claimed from the async deposit queue
    function totalDepositClaimed() external view returns (uint128);

    /// @notice Cumulative assets ever enqueued for async deposit
    function cumulativeDepositRequested() external view returns (uint128);

    /// @notice Cumulative shares ever redeemed from the underlying vault by this passthrough vault
    function totalRedeemClaimed() external view returns (uint128);

    /// @notice Cumulative shares ever submitted for redemption by investors through this vault
    function cumulativeRedeemRequested() external view returns (uint128);

    /// @notice Deposit queue position for a given investor (in assets)
    function depositPosition(address controller) external view returns (uint128 rangeStart, uint128 pending);

    /// @notice Redeem queue position for a given investor (in shares)
    function redeemPosition(address controller) external view returns (uint128 rangeStart, uint128 pending);
}

/// @title  IPassthroughVaultFactory
/// @notice Factory for deploying passthrough vault contracts
interface IPassthroughVaultFactory {
    /// @notice Deploys a new passthrough vault wrapping `vault`
    function newVault(address vault, address memberlist, bool asyncDeposit, bool claimForAll)
        external
        returns (IPassthroughVault);

    /// @notice Returns the deterministic address a vault would be deployed to without deploying it
    function getVaultAddress(address vault, address memberlist, bool asyncDeposit, bool claimForAll)
        external
        view
        returns (address);
}
