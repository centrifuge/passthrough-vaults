// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IUnderlyingVault} from "./interfaces/IUnderlyingVault.sol";
import {IPassthroughVault, IPassthroughVaultFactory, Position} from "./interfaces/IPassthroughVault.sol";

import {MathLib} from "protocol/misc/libraries/MathLib.sol";
import {SafeTransferLib} from "protocol/misc/libraries/SafeTransferLib.sol";
import {IERC7714} from "protocol/misc/interfaces/IERC7540.sol";

/// @title  PassthroughVault
/// @notice Sync deposit + ERC-7540 async deposit/redeem pass-through vault.
///
/// @dev    This contract acts as the single participant in the underlying vault. Investors
///         hold the underlying share token directly.
///
///         Both async deposit and async redeem use independent FIFO waterfalls. Each request
///         assigns the investor a contiguous range in the global queue for that direction.
///
///         Contract is fully immutable: no admin, no upgrades, no escape hatch.
contract PassthroughVault is IPassthroughVault {
    using MathLib for *;

    address public immutable asset;
    address public immutable share;
    IERC7714 public immutable memberlist;
    IUnderlyingVault public immutable vault;
    bool public immutable allowPermissionlessClaiming;

    uint128 public totalDepositClaimed;
    uint128 public totalRedeemClaimed;
    uint128 public cumulativeDepositRequested;
    uint128 public cumulativeRedeemRequested;
    mapping(address => Position) public position;

    //----------------------------------------------------------------------------------------------
    // Constructor
    //----------------------------------------------------------------------------------------------

    constructor(address vault_, address memberlist_, bool allowPermissionlessClaiming_) {
        vault = IUnderlyingVault(vault_);
        asset = IUnderlyingVault(vault_).asset();
        share = IUnderlyingVault(vault_).share();
        memberlist = IERC7714(memberlist_);
        allowPermissionlessClaiming = allowPermissionlessClaiming_;

        SafeTransferLib.safeApprove(asset, vault_, type(uint256).max);
    }

    //----------------------------------------------------------------------------------------------
    // Sync deposit
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPassthroughVault
    function deposit(uint256 assets, address receiver) external permissioned(msg.sender) returns (uint256 shares) {
        uint128 assets_ = assets.toUint128();

        // Deposit to underlying vault, claiming to this vault first (avoids transfer-restriction
        // membership check on receiver), then forward shares to the actual receiver.
        SafeTransferLib.safeTransferFrom(asset, msg.sender, address(this), assets_);
        shares = vault.deposit(assets_, address(this));
        SafeTransferLib.safeTransfer(share, receiver, shares);

        emit Deposit(msg.sender, receiver, assets_, shares);
    }

    /// @inheritdoc IPassthroughVault
    function mint(uint256 shares, address receiver) external permissioned(msg.sender) returns (uint256 assets) {
        uint128 shares_ = shares.toUint128();

        assets = vault.previewMint(shares_);
        SafeTransferLib.safeTransferFrom(asset, msg.sender, address(this), assets);

        // Mint to underlying vault, claiming to this vault first, then forward shares to the actual receiver.
        assets = vault.mint(shares_, address(this));
        SafeTransferLib.safeTransfer(share, receiver, shares_);

        emit Deposit(msg.sender, receiver, assets, shares_);
    }

    //----------------------------------------------------------------------------------------------
    // Async deposit
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPassthroughVault
    function requestDeposit(uint256 assets, address controller, address owner)
        external
        permissioned(controller)
        returns (uint256)
    {
        require(owner == msg.sender, InvalidOwner());

        uint128 assets_ = assets.toUint128();

        SafeTransferLib.safeTransferFrom(asset, owner, address(this), assets_);

        // Force-claim any settled balance so the controller receives shares from previous
        // deposits before their position moves to the back of the queue.
        uint128 claimable = _claimableDepositAssets(controller);
        if (claimable > 0) _claimDeposit(claimable, controller, controller);

        vault.requestDeposit(assets_, address(this), address(this));

        _enqueueDeposit(controller, assets_);

        emit DepositRequest(controller, owner, 0, msg.sender, assets_);
        return 0;
    }

    /// @inheritdoc IPassthroughVault
    function deposit(uint256 assets, address receiver, address controller) external returns (uint256 shares) {
        require(controller == msg.sender, InvalidController());

        uint128 claimable = _claimableDepositAssets(controller);
        require(claimable > 0, InsufficientClaimableShares());

        uint128 actualAssets =
            assets == type(uint256).max ? claimable : MathLib.min(assets, uint256(claimable)).toUint128();
        require(actualAssets > 0, InsufficientClaimableShares());

        shares = _claimDeposit(actualAssets, receiver, controller);
    }

    /// @inheritdoc IPassthroughVault
    function mint(uint256 shares, address receiver, address controller) external returns (uint256 assets) {
        require(controller == msg.sender, InvalidController());

        uint128 claimable = _claimableDepositAssets(controller);
        require(claimable > 0, InsufficientClaimableShares());

        uint256 actualAssets = shares == type(uint256).max
            ? claimable
            // deposit shares → assets
            : MathLib.min(_scale(shares, vault.maxDeposit(address(this)), vault.maxMint(address(this)), MathLib.Rounding.Up), uint256(claimable));

        _claimDeposit(actualAssets.toUint128(), receiver, controller);
        assets = actualAssets;
    }

    /// @inheritdoc IPassthroughVault
    function claimDepositFor(address controller) external returns (uint256 shares) {
        require(allowPermissionlessClaiming, PermissionlessClaimingNotAllowed());
        uint128 claimable = _claimableDepositAssets(controller);
        require(claimable > 0, InsufficientClaimableShares());
        shares = _claimDeposit(claimable, controller, controller);
    }

    //----------------------------------------------------------------------------------------------
    // ERC-7540 deposit views
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPassthroughVault
    function pendingDepositRequest(uint256, address controller) external view returns (uint256) {
        return position[controller].depositPending - _claimableDepositAssets(controller);
    }

    /// @inheritdoc IPassthroughVault
    function claimableDepositRequest(uint256, address controller) external view returns (uint256) {
        return _claimableDepositAssets(controller);
    }

    //----------------------------------------------------------------------------------------------
    // Async redeem
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPassthroughVault
    function requestRedeem(uint256 shares, address controller, address owner)
        external
        permissioned(controller)
        returns (uint256)
    {
        require(owner == msg.sender, InvalidOwner());

        uint128 shares_ = shares.toUint128();

        SafeTransferLib.safeTransferFrom(share, owner, address(this), shares_);

        // Force-claim any settled balance so the controller receives assets from previous
        // settlements before their position moves to the back of the queue.
        uint128 claimable = _claimableRedeemShares(controller);
        if (claimable > 0) _redeem(claimable, controller, controller);

        _enqueueRedeem(controller, shares_);

        uint256 requestId = vault.requestRedeem(shares_, address(this), address(this));

        emit RedeemRequest(controller, owner, requestId, msg.sender, shares_);
        return requestId;
    }

    /// @inheritdoc IPassthroughVault
    function withdraw(uint256 assets, address receiver, address controller) external returns (uint256 shares) {
        require(controller == msg.sender, InvalidController());

        uint256 claimable = _claimableRedeemShares(controller);
        require(claimable > 0, InsufficientClaimableShares());

        // For type(uint256).max, claim all claimable shares directly.
        shares = assets == type(uint256).max
            ? claimable
            // redeem assets → shares
            : MathLib.min(_scale(assets, vault.maxRedeem(address(this)), vault.maxWithdraw(address(this)), MathLib.Rounding.Up), claimable);
        require(shares > 0, InsufficientClaimableShares());

        _redeem(shares.toUint128(), receiver, controller);
    }

    /// @inheritdoc IPassthroughVault
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets) {
        require(controller == msg.sender, InvalidController());

        uint256 claimable = _claimableRedeemShares(controller);
        require(claimable > 0, InsufficientClaimableShares());

        uint256 actualShares = shares == type(uint256).max ? claimable : MathLib.min(shares, claimable);
        assets = _redeem(actualShares.toUint128(), receiver, controller);
    }

    /// @inheritdoc IPassthroughVault
    function claimRedeemFor(address controller) external returns (uint256 assets) {
        require(allowPermissionlessClaiming, PermissionlessClaimingNotAllowed());
        uint128 claimable = _claimableRedeemShares(controller);
        require(claimable > 0, InsufficientClaimableShares());
        assets = _redeem(claimable, controller, controller);
    }

    //----------------------------------------------------------------------------------------------
    // ERC-4626 / ERC-7575 deposit views
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPassthroughVault
    function maxDeposit(address controller) external view returns (uint256) {
        return _claimableDepositAssets(controller);
    }

    /// @inheritdoc IPassthroughVault
    function maxMint(address controller) external view returns (uint256) {
        // deposit assets → shares
        return _scale(_claimableDepositAssets(controller), vault.maxMint(address(this)), vault.maxDeposit(address(this)), MathLib.Rounding.Down);
    }

    /// @inheritdoc IPassthroughVault
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return vault.previewDeposit(assets);
    }

    /// @inheritdoc IPassthroughVault
    function previewMint(uint256 shares) external view returns (uint256) {
        return vault.previewMint(shares);
    }

    //----------------------------------------------------------------------------------------------
    // ERC-7540 redeem views
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPassthroughVault
    function pendingRedeemRequest(uint256, address controller) external view returns (uint256) {
        return position[controller].redeemPending - _claimableRedeemShares(controller);
    }

    /// @inheritdoc IPassthroughVault
    function claimableRedeemRequest(uint256, address controller) external view returns (uint256) {
        return _claimableRedeemShares(controller);
    }

    //----------------------------------------------------------------------------------------------
    // ERC-4626 / ERC-7575 redeem views
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPassthroughVault
    function totalAssets() external view returns (uint256) {
        return vault.totalAssets();
    }

    /// @inheritdoc IPassthroughVault
    function convertToShares(uint256 assets) external view returns (uint256) {
        return vault.convertToShares(assets);
    }

    /// @inheritdoc IPassthroughVault
    function convertToAssets(uint256 shares_) external view returns (uint256) {
        return vault.convertToAssets(shares_);
    }

    /// @inheritdoc IPassthroughVault
    function maxWithdraw(address controller) external view returns (uint256) {
        uint256 claimable = _claimableRedeemShares(controller);
        if (claimable == 0) return 0;
        // redeem shares → assets
        return _scale(claimable, vault.maxWithdraw(address(this)), vault.maxRedeem(address(this)), MathLib.Rounding.Down);
    }

    /// @inheritdoc IPassthroughVault
    function maxRedeem(address controller) external view returns (uint256) {
        return _claimableRedeemShares(controller);
    }

    //----------------------------------------------------------------------------------------------
    // ERC-7714
    //----------------------------------------------------------------------------------------------

    modifier permissioned(address controller) {
        require(isPermissioned(controller), NotMember());
        _;
    }

    /// @inheritdoc IERC7714
    function isPermissioned(address controller) public view returns (bool) {
        if (address(memberlist) == address(0)) return true;
        return memberlist.isPermissioned(controller);
    }

    //----------------------------------------------------------------------------------------------
    // Internal helpers
    //----------------------------------------------------------------------------------------------

    function _getCumulativeDepositSettled() internal view returns (uint128) {
        return vault.maxDeposit(address(this)).toUint128() + totalDepositClaimed;
    }

    function _claimableDepositAssets(address controller) internal view returns (uint128) {
        Position storage pos = position[controller];
        if (pos.depositPending == 0) return 0;
        uint128 settled = _getCumulativeDepositSettled();
        if (settled <= pos.depositRangeStart) return 0;
        uint128 claimable = settled - pos.depositRangeStart;
        return pos.depositPending < claimable ? pos.depositPending : claimable;
    }

    /// @dev Place the combined position (any unsettled remainder + new assets) at the back of the
    ///      global queue. cumulativeDepositRequested advances by the new assets only; the unsettled
    ///      remainder is carried forward without re-expanding the queue. Any previously unsettled
    ///      portion leads to a segment of orphaned assets and a segment of overlapping assets in the
    ///      queue, equal in size. The orphaned assets will eventually be claimable by this controller,
    ///      once the settlement advances past the overlapping segment, resulting only in a delay for
    ///      this controller and no disadvantage to others in the queue.
    function _enqueueDeposit(address controller, uint128 assets) internal {
        Position storage pos = position[controller];
        pos.depositRangeStart = cumulativeDepositRequested - pos.depositPending;
        pos.depositPending += assets;
        cumulativeDepositRequested += assets;
    }

    function _claimDeposit(uint128 assets, address receiver, address controller) internal returns (uint128 shares) {
        Position storage pos = position[controller];
        pos.depositRangeStart += assets;
        pos.depositPending -= assets;
        totalDepositClaimed += assets;

        // Claim to this vault first (avoids transfer-restriction check on receiver in underlying),
        // then forward shares to the actual receiver.
        uint256 sharesOut = vault.deposit(assets, address(this), address(this));
        if (sharesOut > 0) SafeTransferLib.safeTransfer(share, receiver, sharesOut);
        shares = sharesOut.toUint128();
        emit Deposit(msg.sender, receiver, assets, sharesOut);
    }

    function _getCumulativeSettled() internal view returns (uint128) {
        return vault.maxRedeem(address(this)).toUint128() + totalRedeemClaimed;
    }

    function _claimableRedeemShares(address controller) internal view returns (uint128) {
        Position storage pos = position[controller];
        if (pos.redeemPending == 0) return 0;
        uint128 settled = _getCumulativeSettled();
        if (settled <= pos.redeemRangeStart) return 0;
        uint128 claimable = settled - pos.redeemRangeStart;
        return pos.redeemPending < claimable ? pos.redeemPending : claimable;
    }

    /// @dev Place the combined position (any unsettled remainder + new shares) at the back of the
    ///      global queue. cumulativeRedeemRequested advances by the new shares only; the unsettled
    ///      remainder is carried forward without re-expanding the queue. Any previously unsettled
    ///      portion leads to a segment of orphaned shares and a segment of overlapping shares in the
    ///      queue, equal in size. The orphaned shares will eventually be claimable by this controller,
    ///      once the settlement advances past the overlapping segment, resulting only in a delay for
    ///      this controller and no disadvantage to others in the queue.
    function _enqueueRedeem(address controller, uint128 shares) internal {
        Position storage pos = position[controller];
        pos.redeemRangeStart = cumulativeRedeemRequested - pos.redeemPending;
        pos.redeemPending += shares;
        cumulativeRedeemRequested += shares;
    }

    function _redeem(uint128 shares, address receiver, address controller) internal returns (uint128 assets) {
        Position storage pos = position[controller];
        pos.redeemRangeStart += shares;
        pos.redeemPending -= shares;
        totalRedeemClaimed += shares;

        // Claim to this vault first (avoids transfer-restriction check on receiver in underlying),
        // then forward assets to the actual receiver.
        uint256 grossAssets = vault.redeem(shares, address(this), address(this));
        if (grossAssets > 0) SafeTransferLib.safeTransfer(asset, receiver, grossAssets);
        assets = grossAssets.toUint128();
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    function _scale(uint256 amount, uint256 num, uint256 denom, MathLib.Rounding rounding) private pure returns (uint256) {
        if (denom == 0) return 0;
        return amount.mulDiv(num, denom, rounding);
    }
}

contract PassthroughVaultFactory is IPassthroughVaultFactory {
    /// @inheritdoc IPassthroughVaultFactory
    function newVault(address vault, address memberlist, bool allowPermissionlessClaiming)
        external
        returns (IPassthroughVault)
    {
        bytes32 salt = keccak256(abi.encode(vault, memberlist, allowPermissionlessClaiming));
        return new PassthroughVault{salt: salt}(vault, memberlist, allowPermissionlessClaiming);
    }

    /// @inheritdoc IPassthroughVaultFactory
    function getVaultAddress(address vault, address memberlist, bool allowPermissionlessClaiming)
        external
        view
        returns (address)
    {
        bytes32 salt = keccak256(abi.encode(vault, memberlist, allowPermissionlessClaiming));
        bytes32 initcodeHash = keccak256(
            abi.encodePacked(
                type(PassthroughVault).creationCode, abi.encode(vault, memberlist, allowPermissionlessClaiming)
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initcodeHash)))));
    }
}
