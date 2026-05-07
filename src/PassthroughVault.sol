// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IUnderlyingVault} from "./interfaces/IUnderlyingVault.sol";
import {IPassthroughVault, IPassthroughVaultFactory} from "./interfaces/IPassthroughVault.sol";
import {QueuePosition, QueueLib} from "./libraries/QueueLib.sol";

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
///
///         Not fully ERC-7540 compatible: deposit() and redeem() are not supported (use mint()
///         and withdraw() instead); operator delegation is not supported (controller must
///         equal msg.sender, except when claimForAll is set).
///
///         When asyncDeposit is true, both 2-arg and 3-arg mint claims from the async
///         deposit queue. When false, they perform an immediate sync deposit into the underlying.
///         owner must equal msg.sender in requestRedeem.
contract PassthroughVault is IPassthroughVault {
    using MathLib for *;
    using QueueLib for QueuePosition;

    address public immutable asset;
    address public immutable share;
    bool public immutable claimForAll;
    bool public immutable asyncDeposit;
    IERC7714 public immutable memberlist;
    IUnderlyingVault public immutable vault;

    uint128 public totalDepositClaimed;
    uint128 public totalRedeemClaimed;
    uint128 public cumulativeDepositRequested;
    uint128 public cumulativeRedeemRequested;
    mapping(address => QueuePosition) public depositPosition;
    mapping(address => QueuePosition) public redeemPosition;

    constructor(address vault_, address memberlist_, bool asyncDeposit_, bool claimForAll_) {
        vault = IUnderlyingVault(vault_);
        asset = IUnderlyingVault(vault_).asset();
        share = IUnderlyingVault(vault_).share();
        memberlist = IERC7714(memberlist_);
        asyncDeposit = asyncDeposit_;
        claimForAll = claimForAll_;

        SafeTransferLib.safeApprove(asset, vault_, type(uint256).max);
    }

    modifier permissioned(address controller) {
        require(isPermissioned(controller), NotMember());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // ERC-7540 deposit
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPassthroughVault
    function requestDeposit(uint256 assets, address controller, address owner)
        external
        permissioned(controller)
        returns (uint256)
    {
        require(owner == msg.sender, InvalidOwner());
        require(asyncDeposit, AsyncDepositDisabled());
        require(controller == msg.sender, InvalidController());

        uint128 assets_ = assets.toUint128();
        SafeTransferLib.safeTransferFrom(asset, owner, address(this), assets_);

        // Force-claim any settled balance so the controller receives shares from previous
        // deposits before their position moves to the back of the queue.
        uint128 claimable = depositPosition[controller].claimable(_getCumulativeDepositSettled());
        if (claimable > 0) _claimDeposit(claimable, controller, controller);

        cumulativeDepositRequested = depositPosition[controller].enqueue(assets_, cumulativeDepositRequested);
        vault.requestDeposit(assets_, address(this), address(this));

        emit DepositRequest(controller, owner, 0, msg.sender, assets_);
        return 0;
    }

    /// @inheritdoc IPassthroughVault
    function mint(uint256 shares, address receiver) external permissioned(msg.sender) returns (uint256 assets) {
        assets = mint(shares, receiver, msg.sender);
    }

    /// @inheritdoc IPassthroughVault
    function mint(uint256 shares, address receiver, address controller)
        public
        permissioned(controller)
        returns (uint256 assets)
    {
        require(controller == msg.sender || claimForAll && controller == receiver, InvalidController());

        if (asyncDeposit) {
            uint128 claimable = depositPosition[controller].claimable(_getCumulativeDepositSettled());
            require(claimable > 0, InsufficientClaimableShares());

            uint256 actualAssets = shares == type(uint256).max
                ? claimable
                : MathLib.min(
                    _scale(shares, vault.maxDeposit(address(this)), vault.maxMint(address(this)), MathLib.Rounding.Up),
                    uint256(claimable)
                );

            _claimDeposit(actualAssets.toUint128(), receiver, controller);
            assets = actualAssets;
        } else {
            uint128 shares_ = shares.toUint128();
            SafeTransferLib.safeTransferFrom(asset, msg.sender, address(this), vault.previewMint(shares_));
            assets = vault.mint(shares_, address(this));
            SafeTransferLib.safeTransfer(share, receiver, shares_);

            emit Deposit(msg.sender, receiver, assets, shares_);
        }
    }

    /// @inheritdoc IPassthroughVault
    function pendingDepositRequest(uint256, address controller) external view returns (uint256) {
        if (!asyncDeposit) return 0;
        uint128 settled = _getCumulativeDepositSettled();
        return depositPosition[controller].pending - depositPosition[controller].claimable(settled);
    }

    /// @inheritdoc IPassthroughVault
    function claimableDepositRequest(uint256, address controller) external view returns (uint256) {
        if (!asyncDeposit) return 0;
        return depositPosition[controller].claimable(_getCumulativeDepositSettled());
    }

    /// @inheritdoc IPassthroughVault
    function maxMint(address controller) external view returns (uint256) {
        if (!asyncDeposit) return vault.maxMint(address(this));

        uint128 claimable = depositPosition[controller].claimable(_getCumulativeDepositSettled());
        return _scale(claimable, vault.maxMint(address(this)), vault.maxDeposit(address(this)), MathLib.Rounding.Down);
    }

    /// @inheritdoc IPassthroughVault
    function previewMint(uint256 shares) external view returns (uint256) {
        return vault.previewMint(shares);
    }

    function _claimDeposit(uint128 assets, address receiver, address controller) internal {
        depositPosition[controller].claim(assets);
        totalDepositClaimed += assets;

        // Claim to this vault first (avoids transfer-restriction check on receiver in underlying),
        // then forward shares to the actual receiver.
        uint256 sharesOut = vault.deposit(assets, address(this), address(this));
        if (sharesOut > 0) SafeTransferLib.safeTransfer(share, receiver, sharesOut);

        emit Deposit(msg.sender, receiver, assets, sharesOut);
    }

    function _getCumulativeDepositSettled() internal view returns (uint128) {
        return vault.maxDeposit(address(this)).toUint128() + totalDepositClaimed;
    }

    //----------------------------------------------------------------------------------------------
    // ERC-7540 redeem
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPassthroughVault
    /// @dev owner and controller must equal msg.sender, delegated redemption via ERC-20 allowance is not supported.
    function requestRedeem(uint256 shares, address controller, address owner)
        external
        permissioned(controller)
        returns (uint256)
    {
        require(owner == msg.sender, InvalidOwner());
        require(controller == msg.sender, InvalidController());

        uint128 shares_ = shares.toUint128();
        SafeTransferLib.safeTransferFrom(share, owner, address(this), shares_);

        // Force-claim any settled balance so the controller receives assets from previous
        // settlements before their position moves to the back of the queue.
        uint128 claimable = redeemPosition[controller].claimable(_getCumulativeRedeemSettled());
        if (claimable > 0) _redeem(claimable, controller, controller);

        cumulativeRedeemRequested = redeemPosition[controller].enqueue(shares_, cumulativeRedeemRequested);
        vault.requestRedeem(shares_, address(this), address(this));

        emit RedeemRequest(controller, owner, 0, msg.sender, shares_);
        return 0;
    }

    /// @inheritdoc IPassthroughVault
    function withdraw(uint256 assets, address receiver, address controller) external returns (uint256 shares) {
        require(controller == msg.sender || claimForAll && controller == receiver, InvalidController());

        uint128 claimable = redeemPosition[controller].claimable(_getCumulativeRedeemSettled());
        require(claimable > 0, InsufficientClaimableShares());

        shares = assets == type(uint256).max
            ? claimable
            : MathLib.min(
                _scale(assets, vault.maxRedeem(address(this)), vault.maxWithdraw(address(this)), MathLib.Rounding.Up),
                claimable
            );

        require(shares > 0, InsufficientClaimableShares());

        _redeem(shares.toUint128(), receiver, controller);
    }

    /// @inheritdoc IPassthroughVault
    function pendingRedeemRequest(uint256, address controller) external view returns (uint256) {
        uint128 settled = _getCumulativeRedeemSettled();
        return redeemPosition[controller].pending - redeemPosition[controller].claimable(settled);
    }

    /// @inheritdoc IPassthroughVault
    function claimableRedeemRequest(uint256, address controller) external view returns (uint256) {
        return redeemPosition[controller].claimable(_getCumulativeRedeemSettled());
    }

    /// @inheritdoc IPassthroughVault
    function maxWithdraw(address controller) external view returns (uint256) {
        uint128 claimable = redeemPosition[controller].claimable(_getCumulativeRedeemSettled());
        if (claimable == 0) return 0;
        return
            _scale(claimable, vault.maxWithdraw(address(this)), vault.maxRedeem(address(this)), MathLib.Rounding.Down);
    }

    /// @inheritdoc IPassthroughVault
    function maxRedeem(address controller) external view returns (uint256) {
        return redeemPosition[controller].claimable(_getCumulativeRedeemSettled());
    }

    function _redeem(uint128 shares, address receiver, address controller) internal returns (uint128 assets) {
        redeemPosition[controller].claim(shares);
        totalRedeemClaimed += shares;

        // Claim to this vault first (avoids transfer-restriction check on receiver in underlying),
        // then forward assets to the actual receiver.
        uint256 grossAssets = vault.redeem(shares, address(this), address(this));
        if (grossAssets > 0) SafeTransferLib.safeTransfer(asset, receiver, grossAssets);
        assets = grossAssets.toUint128();

        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    function _getCumulativeRedeemSettled() internal view returns (uint128) {
        return vault.maxRedeem(address(this)).toUint128() + totalRedeemClaimed;
    }
    
    //----------------------------------------------------------------------------------------------
    // ERC-4626
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

    //----------------------------------------------------------------------------------------------
    // ERC-7714
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC7714
    function isPermissioned(address controller) public view returns (bool) {
        if (address(memberlist) == address(0)) return true;
        return memberlist.isPermissioned(controller);
    }

    //----------------------------------------------------------------------------------------------
    // Internal
    //----------------------------------------------------------------------------------------------

    function _scale(uint256 amount, uint256 num, uint256 denom, MathLib.Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        if (denom == 0) return 0;
        return amount.mulDiv(num, denom, rounding);
    }
}

contract PassthroughVaultFactory is IPassthroughVaultFactory {
    /// @inheritdoc IPassthroughVaultFactory
    function newVault(address vault, address memberlist, bool asyncDeposit, bool claimForAll)
        external
        returns (IPassthroughVault)
    {
        bytes32 salt = keccak256(abi.encode(vault, memberlist, asyncDeposit, claimForAll));
        return new PassthroughVault{salt: salt}(vault, memberlist, asyncDeposit, claimForAll);
    }

    /// @inheritdoc IPassthroughVaultFactory
    function getVaultAddress(address vault, address memberlist, bool asyncDeposit, bool claimForAll)
        external
        view
        returns (address)
    {
        bytes32 salt = keccak256(abi.encode(vault, memberlist, asyncDeposit, claimForAll));
        bytes32 initcodeHash = keccak256(
            abi.encodePacked(
                type(PassthroughVault).creationCode, abi.encode(vault, memberlist, asyncDeposit, claimForAll)
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initcodeHash)))));
    }
}
