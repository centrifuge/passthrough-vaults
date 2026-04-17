// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @notice Interface for the underlying vault that PassthroughVault wraps.
///         Covers both sync-deposit and async-deposit underlying vaults, plus async redeem.
interface IUnderlyingVault {
    function asset() external view returns (address);
    function share() external view returns (address);
    function totalAssets() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);

    // Sync deposit
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function previewDeposit(uint256 assets) external view returns (uint256 shares);
    function previewMint(uint256 shares) external view returns (uint256 assets);
    function maxDeposit(address receiver) external view returns (uint256);
    function maxMint(address receiver) external view returns (uint256);

    // Async deposit
    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId);
    function deposit(uint256 assets, address receiver, address controller) external returns (uint256 shares);
    function mint(uint256 shares, address receiver, address controller) external returns (uint256 assets);

    // Async redeem
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets);
    function maxRedeem(address controller) external view returns (uint256);
    function maxWithdraw(address controller) external view returns (uint256);
}
