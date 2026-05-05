// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IERC7714} from "protocol/misc/interfaces/IERC7540.sol";
import {QueuePosition, QueueLib} from "../libraries/QueueLib.sol";

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

    //----------------------------------------------------------------------------------------------
    // Immutables
    //----------------------------------------------------------------------------------------------

    function asset() external view returns (address);
    function share() external view returns (address);

    /// @notice Optional memberlist contract controlling which addresses may interact
    /// @dev Returns the zero address when no memberlist is configured (all addresses permitted)
    function memberlist() external view returns (IERC7714);

    /// @notice When true, 2-arg and 3-arg mint claim from the async deposit queue;
    ///         when false, they perform an immediate sync deposit into the underlying vault.
    function asyncDeposit() external view returns (bool);

    /// @notice When true, anyone may call mint/withdraw on behalf of a controller,
    ///         provided the receiver equals the controller.
    function claimForAll() external view returns (bool);

    //----------------------------------------------------------------------------------------------
    // Deposit (sync mint or async claim)
    //----------------------------------------------------------------------------------------------

    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function mint(uint256 shares, address receiver, address controller) external returns (uint256 assets);
    function maxMint(address receiver) external view returns (uint256);
    function previewMint(uint256 shares) external view returns (uint256);

    //----------------------------------------------------------------------------------------------
    // Async deposit request
    //----------------------------------------------------------------------------------------------

    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId);
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
