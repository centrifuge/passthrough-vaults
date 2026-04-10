// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SyncDepositVault} from "protocol/vaults/SyncDepositVault.sol";
import {ISyncDepositPassthroughVault, IPassthroughVaultFactory, IPassthroughRedeemVault, RedeemPosition} from "./interfaces/IPassthroughVault.sol";

import {MathLib} from "protocol/misc/libraries/MathLib.sol";
import {IERC165} from "protocol/misc/interfaces/IERC165.sol";
import {IERC7575} from "protocol/misc/interfaces/IERC7575.sol";
import {SafeTransferLib} from "protocol/misc/libraries/SafeTransferLib.sol";
import {IERC7540Redeem, IERC7714} from "protocol/misc/interfaces/IERC7540.sol";

/// @title  SyncDepositPassthroughVault
/// @notice Sync deposit + ERC-7540 async redeem pass-through vault.
///
/// @dev    This contract acts as the single participant in the underlying vault. Investors
///         hold the underlying share token directly.
///
///         Async redeem uses a FIFO waterfall. Each requestRedeem assigns the investor a
///         contiguous range [rangeStart, rangeStart + pending) in a global share queue.
///
///         Because rangeStart[i] is set to the end of the queue at request time, a late
///         joiner can only claim once the waterfall has advanced past all earlier requests.
///         A new request (re-queue) force-claims any settled balance first, then moves the
///         remaining + new shares to the back of the queue.
///
///         Contract is fully immutable: no admin, no upgrades, no escape hatch.
contract SyncDepositPassthroughVault is ISyncDepositPassthroughVault {
    using MathLib for *;

    uint256 internal constant REQUEST_ID = 0;

    SyncDepositVault public immutable vault;

    /// @inheritdoc IERC7575
    address public immutable asset;
    /// @inheritdoc IERC7575
    address public immutable share;

    IERC7714 public immutable memberlist;

    /// @notice Total shares ever claimed from the underlying vault.
    uint128 public totalRedeemed;
    /// @notice Total shares ever requested for redemption through this vault.
    uint128 public cumulativeRedeemRequested;

    mapping(address => RedeemPosition) public redeemPosition;

    //----------------------------------------------------------------------------------------------
    // Constructor
    //----------------------------------------------------------------------------------------------

    constructor(address vault_, address memberlist_) {
        vault = SyncDepositVault(vault_);
        asset = SyncDepositVault(vault_).asset();
        share = SyncDepositVault(vault_).share();
        memberlist = IERC7714(memberlist_);

        SafeTransferLib.safeApprove(asset, vault_, type(uint256).max);
    }

    //----------------------------------------------------------------------------------------------
    // Sync deposit
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC7575
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(isPermissioned(msg.sender), NotMember());

        uint128 assets_ = assets.toUint128();
        require(assets_ != 0, ZeroAmountNotAllowed());

        // Deposit to underlying vault, claiming to this vault first (avoids transfer-restriction
        // membership check on receiver), then forward shares to the actual receiver.
        SafeTransferLib.safeTransferFrom(asset, msg.sender, address(this), assets_);
        shares = vault.deposit(assets_, address(this));
        SafeTransferLib.safeTransfer(share, receiver, shares);

        emit Deposit(msg.sender, receiver, assets_, shares);
    }

    /// @inheritdoc IERC7575
    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        require(isPermissioned(msg.sender), NotMember());

        uint128 shares_ = shares.toUint128();
        require(shares_ != 0, ZeroAmountNotAllowed());

        assets = vault.previewMint(shares_);
        SafeTransferLib.safeTransferFrom(asset, msg.sender, address(this), assets);

        // Mint to underlying vault, claiming to this vault first, then forward shares to the actual receiver.
        assets = vault.mint(shares_, address(this));
        SafeTransferLib.safeTransfer(share, receiver, shares_);

        emit Deposit(msg.sender, receiver, assets, shares_);
    }

    //----------------------------------------------------------------------------------------------
    // Async redeem
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPassthroughRedeemVault
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256) {
        require(owner == msg.sender, InvalidOwner());
        require(isPermissioned(controller), NotMember());

        uint128 shares_ = shares.toUint128();
        require(shares_ != 0, ZeroAmountNotAllowed());

        SafeTransferLib.safeTransferFrom(share, owner, address(this), shares_);

        // Force-claim any settled balance so the controller receives assets from previous
        // settlements before their position moves to the back of the queue.
        uint128 claimable = _claimableRedeemShares(controller);
        if (claimable > 0) {
            _redeem(claimable, controller, controller);
        }

        // Place the combined position (any unsettled remainder + new shares) at the back of the global queue.
        // cumulativeRedeemRequested advances by the new shares only; the unsettled remainder is carried forward
        // without re-expanding the queue. The previously unsettled portion leads to a segment of orphaned shares
        // and a segment of overlapping shares in the queue, equal in size. The orphaned shares will eventually be
        // claimable by this controller once the settlement advances past the overlapping segment, resulting only in
        // a delay for this controller and no disadvantage to others in the queue.
        RedeemPosition storage pos = redeemPosition[controller];
        pos.rangeStart = uint128(cumulativeRedeemRequested) - pos.pending;
        pos.pending += shares_;
        cumulativeRedeemRequested += shares_;

        // This vault is both controller and owner in the underlying vault.
        vault.requestRedeem(shares_, address(this), address(this));

        emit RedeemRequest(controller, owner, REQUEST_ID, msg.sender, shares_);
        return REQUEST_ID;
    }

    /// @inheritdoc IERC7575
    function withdraw(uint256 assets, address receiver, address controller) external returns (uint256 shares) {
        require(controller == msg.sender, InvalidController());

        uint256 claimable = _claimableRedeemShares(controller);
        require(claimable > 0, InsufficientClaimableShares());

        // For type(uint256).max, claim all claimable shares directly.
        shares = assets == type(uint256).max
            ? claimable
            : MathLib.min(_assetsToShares(assets, MathLib.Rounding.Up), claimable);
        require(shares > 0, InsufficientClaimableShares());

        uint256 netAssets = _redeem(shares.toUint128(), receiver, controller);
        emit Withdraw(msg.sender, receiver, controller, netAssets, shares);
    }

    /// @inheritdoc IERC7575
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets) {
        require(controller == msg.sender, InvalidController());

        uint256 claimable = _claimableRedeemShares(controller);
        require(claimable > 0, InsufficientClaimableShares());

        uint256 actualShares = shares == type(uint256).max ? claimable : MathLib.min(shares, claimable);
        assets = _redeem(actualShares.toUint128(), receiver, controller);
        emit Withdraw(msg.sender, receiver, controller, assets, actualShares);
    }

    //----------------------------------------------------------------------------------------------
    // ERC-4626 / ERC-7575 deposit views
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC7575
    function maxDeposit(address) external view returns (uint256) {
        return vault.maxDeposit(address(this));
    }

    /// @inheritdoc IERC7575
    function maxMint(address) external view returns (uint256) {
        return vault.maxMint(address(this));
    }

    /// @inheritdoc IERC7575
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return vault.previewDeposit(assets);
    }

    /// @inheritdoc IERC7575
    function previewMint(uint256 shares) external view returns (uint256) {
        return vault.previewMint(shares);
    }

    //----------------------------------------------------------------------------------------------
    // ERC-7540 redeem views
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPassthroughRedeemVault
    function pendingRedeemRequest(uint256, address controller) external view returns (uint256) {
        return redeemPosition[controller].pending - _claimableRedeemShares(controller);
    }

    /// @inheritdoc IPassthroughRedeemVault
    function claimableRedeemRequest(uint256, address controller) external view returns (uint256) {
        return _claimableRedeemShares(controller);
    }

    //----------------------------------------------------------------------------------------------
    // ERC-4626 / ERC-7575 redeem views
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC7575
    function totalAssets() external pure returns (uint256) {
        return 0;
    }

    /// @inheritdoc IERC7575
    function convertToShares(uint256 assets) external view returns (uint256) {
        return vault.convertToShares(assets);
    }

    /// @inheritdoc IERC7575
    function convertToAssets(uint256 shares_) external view returns (uint256) {
        return vault.convertToAssets(shares_);
    }

    /// @inheritdoc IERC7575
    function maxWithdraw(address controller) external view returns (uint256) {
        uint256 claimable = _claimableRedeemShares(controller);
        if (claimable == 0) return 0;
        return _sharesToAssets(claimable, MathLib.Rounding.Down);
    }

    /// @inheritdoc IERC7575
    function maxRedeem(address controller) external view returns (uint256) {
        return _claimableRedeemShares(controller);
    }

    /// @inheritdoc IERC7575
    /// @dev ERC-7540: async redeem preview always reverts
    function previewWithdraw(uint256) external pure returns (uint256) {
        revert();
    }

    /// @inheritdoc IERC7575
    /// @dev ERC-7540: async redeem preview always reverts
    function previewRedeem(uint256) external pure returns (uint256) {
        revert();
    }

    //----------------------------------------------------------------------------------------------
    // ERC-165
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == type(IERC7540Redeem).interfaceId || interfaceId == type(IERC7714).interfaceId
            || interfaceId == type(IERC7575).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //----------------------------------------------------------------------------------------------
    // ERC-7714
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC7714
    function isPermissioned(address controller) public view returns (bool) {
        if (address(memberlist) == address(0)) return true;
        return memberlist.isPermissioned(controller);
    }

    //----------------------------------------------------------------------------------------------
    // Internal helpers
    //----------------------------------------------------------------------------------------------

    function _getCumulativeSettled() internal view returns (uint128) {
        return vault.maxRedeem(address(this)).toUint128() + totalRedeemed;
    }

    function _claimableRedeemShares(address controller) internal view returns (uint128) {
        RedeemPosition storage pos = redeemPosition[controller];
        if (pos.pending == 0) return 0;
        uint128 settled = _getCumulativeSettled();
        if (settled <= pos.rangeStart) return 0;
        uint128 claimable = settled - pos.rangeStart;
        return pos.pending > claimable ? claimable : pos.pending;
    }

    function _redeem(uint128 shares, address receiver, address controller) private returns (uint128 assets) {
        RedeemPosition storage pos = redeemPosition[controller];
        pos.rangeStart += shares;
        pos.pending -= shares;
        totalRedeemed += shares;

        // Claim to this vault first (avoids transfer-restriction check on receiver in underlying),
        // then forward assets to the actual receiver.
        uint256 grossAssets = vault.redeem(shares, address(this), address(this));
        if (grossAssets > 0) SafeTransferLib.safeTransfer(asset, receiver, grossAssets);
        assets = grossAssets.toUint128();
    }

    function _sharesToAssets(uint256 shares, MathLib.Rounding rounding) internal view returns (uint256) {
        uint256 settledShares = vault.maxRedeem(address(this));
        if (settledShares == 0) return 0;
        return shares.mulDiv(vault.maxWithdraw(address(this)), settledShares, rounding);
    }

    function _assetsToShares(uint256 assets, MathLib.Rounding rounding) internal view returns (uint256) {
        uint256 settledAssets = vault.maxWithdraw(address(this));
        if (settledAssets == 0) return 0;
        return assets.mulDiv(vault.maxRedeem(address(this)), settledAssets, rounding);
    }
}

contract SyncDepositPassthroughVaultFactory is IPassthroughVaultFactory {
    /// @inheritdoc IPassthroughVaultFactory
    function newVault(address vault, address memberlist) external returns (ISyncDepositPassthroughVault) {
        bytes32 salt = keccak256(abi.encode(vault, memberlist));
        return new SyncDepositPassthroughVault{salt: salt}(vault, memberlist);
    }

    /// @inheritdoc IPassthroughVaultFactory
    function getVaultAddress(address vault, address memberlist) external view returns (address) {
        bytes32 salt = keccak256(abi.encode(vault, memberlist));
        bytes32 initcodeHash = keccak256(
            abi.encodePacked(type(SyncDepositPassthroughVault).creationCode, abi.encode(vault, memberlist))
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initcodeHash)))));
    }
}
