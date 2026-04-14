// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "protocol/misc/ERC20.sol";
import {IERC165} from "protocol/misc/interfaces/IERC165.sol";
import {IERC7575} from "protocol/misc/interfaces/IERC7575.sol";
import {IERC7540Redeem, IERC7714} from "protocol/misc/interfaces/IERC7540.sol";

import {PassthroughVault} from "../../src/PassthroughVault.sol";
import {IPassthroughVault} from "../../src/interfaces/IPassthroughVault.sol";

import "forge-std/Test.sol";

contract IsContract {}

contract PassthroughVaultTest is Test {
    uint128 constant ASSETS = 1000e6;
    uint128 constant SHARES = 1000e18;

    address immutable USER = makeAddr("USER");
    address immutable USER2 = makeAddr("USER2");
    address immutable RECEIVER = makeAddr("RECEIVER");

    ERC20 asset = new ERC20(6);
    ERC20 share = new ERC20(18);
    address underlying = address(new IsContract());
    address memberlist = address(new IsContract());

    PassthroughVault vault;

    function setUp() public virtual {
        vm.mockCall(underlying, abi.encodeWithSelector(IERC7575.asset.selector), abi.encode(address(asset)));
        vm.mockCall(underlying, abi.encodeWithSelector(IERC7575.share.selector), abi.encode(address(share)));
        vault = new PassthroughVault(underlying, memberlist, false);
        _setupMocks();
    }

    function _setupMocks() internal virtual {
        vm.mockCall(memberlist, abi.encodeWithSelector(IERC7714.isPermissioned.selector), abi.encode(true));
        vm.mockCall(underlying, abi.encodeWithSelector(IERC7575.maxRedeem.selector), abi.encode(0));
        vm.mockCall(underlying, abi.encodeWithSelector(IERC7540Redeem.pendingRedeemRequest.selector), abi.encode(0));
    }
}

contract PassthroughVaultConstructorTest is PassthroughVaultTest {
    function testImmutables() public view {
        assertEq(vault.asset(), address(asset));
        assertEq(vault.share(), address(share));
        assertEq(address(vault.vault()), underlying);
        assertEq(address(vault.memberlist()), address(memberlist));
    }

    function testAssetApprovedToUnderlying() public view {
        assertEq(asset.allowance(address(vault), underlying), type(uint256).max);
    }

    function testNoWhitelistAllowsAll() public {
        vm.mockCall(underlying, abi.encodeWithSelector(IERC7575.asset.selector), abi.encode(address(asset)));
        vm.mockCall(underlying, abi.encodeWithSelector(IERC7575.share.selector), abi.encode(address(share)));
        PassthroughVault noWhitelistVault = new PassthroughVault(underlying, address(0));

        asset.mint(USER, ASSETS);
        vm.mockCall(underlying, abi.encodeWithSignature("deposit(uint256,address)"), abi.encode(ASSETS));
        share.mint(address(noWhitelistVault), ASSETS);
        vm.startPrank(USER);
        asset.approve(address(noWhitelistVault), ASSETS);
        noWhitelistVault.deposit(ASSETS, USER);
        vm.stopPrank();
    }
}

contract PassthroughVaultDepositTest is PassthroughVaultTest {
    function testDeposit() public {
        uint256 sharesOut = ASSETS;

        asset.mint(USER, ASSETS);
        vm.prank(USER);
        asset.approve(address(vault), ASSETS);

        vm.mockCall(
            underlying,
            abi.encodeWithSignature("deposit(uint256,address)", uint256(ASSETS), address(vault)),
            abi.encode(sharesOut)
        );
        vm.expectCall(underlying, abi.encodeWithSignature("deposit(uint256,address)", uint256(ASSETS), address(vault)));
        share.mint(address(vault), sharesOut);
        vm.expectEmit(true, true, false, true);
        emit IERC7575.Deposit(USER, RECEIVER, ASSETS, sharesOut);

        vm.prank(USER);
        uint256 shares = vault.deposit(ASSETS, RECEIVER);

        assertEq(shares, sharesOut);
        assertEq(share.balanceOf(RECEIVER), sharesOut);
        assertEq(asset.balanceOf(USER), 0);
    }

    function testErrNotMember() public {
        vm.mockCall(memberlist, abi.encodeWithSelector(IERC7714.isPermissioned.selector, USER), abi.encode(false));

        asset.mint(USER, ASSETS);
        vm.startPrank(USER);
        asset.approve(address(vault), ASSETS);
        vm.expectRevert(IPassthroughVault.NotMember.selector);
        vault.deposit(ASSETS, RECEIVER);
        vm.stopPrank();
    }
}

contract PassthroughVaultMintTest is PassthroughVaultTest {
    function testMint() public {
        uint128 shares = 100e18;
        uint256 previewAssets = 1000e6;

        asset.mint(USER, previewAssets);
        vm.prank(USER);
        asset.approve(address(vault), previewAssets);

        vm.mockCall(underlying, abi.encodeWithSignature("previewMint(uint256)", shares), abi.encode(previewAssets));
        vm.mockCall(
            underlying,
            abi.encodeWithSignature("mint(uint256,address)", shares, address(vault)),
            abi.encode(previewAssets)
        );
        vm.expectCall(underlying, abi.encodeWithSignature("mint(uint256,address)", shares, address(vault)));
        share.mint(address(vault), shares);
        vm.expectEmit(true, true, false, true);
        emit IERC7575.Deposit(USER, RECEIVER, previewAssets, shares);

        vm.prank(USER);
        uint256 assets = vault.mint(shares, RECEIVER);

        assertEq(assets, previewAssets);
        assertEq(asset.balanceOf(USER), 0);
    }

    function testErrNotMember() public {
        vm.mockCall(memberlist, abi.encodeWithSelector(IERC7714.isPermissioned.selector, USER), abi.encode(false));
        vm.mockCall(underlying, abi.encodeWithSignature("previewMint(uint256)"), abi.encode(1000e6));

        vm.startPrank(USER);
        vm.expectRevert(IPassthroughVault.NotMember.selector);
        vault.mint(100e18, RECEIVER);
        vm.stopPrank();
    }
}

contract PassthroughVaultRequestRedeemTest is PassthroughVaultTest {
    function testRequestRedeem() public {
        share.mint(USER, SHARES);

        vm.prank(USER);
        share.approve(address(vault), SHARES);

        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "requestRedeem(uint256,address,address)", uint256(SHARES), address(vault), address(vault)
            ),
            abi.encode(0)
        );

        vm.expectEmit(true, true, true, true);
        emit IERC7540Redeem.RedeemRequest(USER, USER, 0, USER, SHARES);
        vm.prank(USER);
        uint256 requestId = vault.requestRedeem(SHARES, USER, USER);

        assertEq(requestId, 0);
        assertEq(share.balanceOf(USER), 0);
        assertEq(vault.pendingRedeemRequest(0, USER), SHARES);
    }

    function testRequestRedeemAccumulatesForMultipleUsers() public {
        uint128 shares2 = SHARES / 2;

        share.mint(USER, SHARES);
        share.mint(USER2, shares2);
        vm.prank(USER);
        share.approve(address(vault), SHARES);
        vm.prank(USER2);
        share.approve(address(vault), shares2);

        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "requestRedeem(uint256,address,address)", uint256(SHARES), address(vault), address(vault)
            ),
            abi.encode(0)
        );
        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "requestRedeem(uint256,address,address)", uint256(shares2), address(vault), address(vault)
            ),
            abi.encode(0)
        );

        vm.expectEmit(true, true, true, true);
        emit IERC7540Redeem.RedeemRequest(USER, USER, 0, USER, SHARES);
        vm.prank(USER);
        vault.requestRedeem(SHARES, USER, USER);
        vm.expectEmit(true, true, true, true);
        emit IERC7540Redeem.RedeemRequest(USER2, USER2, 0, USER2, shares2);
        vm.prank(USER2);
        vault.requestRedeem(shares2, USER2, USER2);

        assertEq(vault.pendingRedeemRequest(0, USER), SHARES);
        assertEq(vault.pendingRedeemRequest(0, USER2), shares2);
        assertEq(vault.cumulativeRedeemRequested(), SHARES + shares2);

        (uint128 rangeStart1,) = vault.redeemPosition(USER);
        (uint128 rangeStart2,) = vault.redeemPosition(USER2);
        assertEq(rangeStart1, 0);
        assertEq(rangeStart2, SHARES); // USER2 starts where USER ends
    }

    function testRequestRedeemTwiceBeforeSettlement() public {
        uint128 firstShares = SHARES / 2;
        uint128 secondShares = SHARES;

        share.mint(USER, firstShares + secondShares);
        vm.prank(USER);
        share.approve(address(vault), firstShares + secondShares);

        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "requestRedeem(uint256,address,address)", uint256(firstShares), address(vault), address(vault)
            ),
            abi.encode(0)
        );
        vm.expectEmit(true, true, true, true);
        emit IERC7540Redeem.RedeemRequest(USER, USER, 0, USER, firstShares);
        vm.prank(USER);
        vault.requestRedeem(firstShares, USER, USER);

        assertEq(vault.pendingRedeemRequest(0, USER), firstShares);
        assertEq(vault.cumulativeRedeemRequested(), firstShares);
        (uint128 rangeStart, uint128 pending) = vault.redeemPosition(USER);
        assertEq(rangeStart, 0);
        assertEq(pending, firstShares);

        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "requestRedeem(uint256,address,address)", uint256(secondShares), address(vault), address(vault)
            ),
            abi.encode(0)
        );
        vm.expectEmit(true, true, true, true);
        emit IERC7540Redeem.RedeemRequest(USER, USER, 0, USER, secondShares);
        vm.prank(USER);
        vault.requestRedeem(secondShares, USER, USER);

        assertEq(vault.pendingRedeemRequest(0, USER), firstShares + secondShares);
        assertEq(vault.cumulativeRedeemRequested(), firstShares + secondShares);
        (rangeStart, pending) = vault.redeemPosition(USER);
        assertEq(rangeStart, 0);
        assertEq(pending, firstShares + secondShares);
    }

    function testErrInvalidOwner() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IPassthroughVault.InvalidOwner.selector);
        vault.requestRedeem(SHARES, USER, USER);
    }

    function testErrInsufficientShares() public {
        vm.prank(USER);
        vm.expectRevert();
        vault.requestRedeem(SHARES, USER, USER);
    }

    function testErrNotMember() public {
        vm.mockCall(memberlist, abi.encodeWithSelector(IERC7714.isPermissioned.selector, USER), abi.encode(false));
        share.mint(USER, SHARES);
        vm.startPrank(USER);
        share.approve(address(vault), SHARES);
        vm.expectRevert(IPassthroughVault.NotMember.selector);
        vault.requestRedeem(SHARES, USER, USER);
        vm.stopPrank();
    }
}

contract PassthroughVaultRedeemClaimTest is PassthroughVaultTest {
    function setUp() public override {
        super.setUp();

        share.mint(USER, SHARES);
        vm.prank(USER);
        share.approve(address(vault), SHARES);

        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "requestRedeem(uint256,address,address)", uint256(SHARES), address(vault), address(vault)
            ),
            abi.encode(0)
        );

        vm.prank(USER);
        vault.requestRedeem(SHARES, USER, USER);

        vm.mockCall(underlying, abi.encodeWithSelector(IERC7575.maxRedeem.selector, address(vault)), abi.encode(SHARES));
        vm.mockCall(
            underlying, abi.encodeWithSelector(IERC7575.maxWithdraw.selector, address(vault)), abi.encode(ASSETS)
        );
    }

    function testRedeem() public {
        asset.mint(address(vault), ASSETS);
        vm.mockCall(
            underlying,
            abi.encodeWithSignature("redeem(uint256,address,address)", uint256(SHARES), address(vault), address(vault)),
            abi.encode(ASSETS)
        );
        vm.expectEmit(true, true, true, true);
        emit IERC7575.Withdraw(USER, RECEIVER, USER, ASSETS, SHARES);

        vm.prank(USER);
        uint256 assets = vault.redeem(SHARES, RECEIVER, USER);

        assertEq(assets, ASSETS);
        assertEq(asset.balanceOf(RECEIVER), ASSETS);
        assertEq(vault.pendingRedeemRequest(0, USER), 0);
    }

    function testRedeemMax() public {
        asset.mint(address(vault), ASSETS);
        vm.mockCall(underlying, abi.encodeWithSignature("redeem(uint256,address,address)"), abi.encode(ASSETS));
        vm.expectEmit(true, true, true, true);
        emit IERC7575.Withdraw(USER, RECEIVER, USER, ASSETS, SHARES);

        vm.prank(USER);
        uint256 assets = vault.redeem(type(uint256).max, RECEIVER, USER);

        assertEq(assets, ASSETS);
        assertEq(asset.balanceOf(RECEIVER), ASSETS);
    }

    function testNewJoinerExcludedFromPastSettlement() public {
        share.mint(USER2, SHARES);
        vm.prank(USER2);
        share.approve(address(vault), SHARES);
        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "requestRedeem(uint256,address,address)", uint256(SHARES), address(vault), address(vault)
            ),
            abi.encode(0)
        );
        vm.prank(USER2);
        vault.requestRedeem(SHARES, USER2, USER2);

        // USER2's range starts at the back; past settlement doesn't cover it
        assertEq(vault.claimableRedeemRequest(0, USER), SHARES);
        assertEq(vault.claimableRedeemRequest(0, USER2), 0);
    }

    function testRedeemPartial() public {
        uint128 partialShares = SHARES / 2;
        uint128 partialAssets = ASSETS / 2;

        asset.mint(address(vault), partialAssets);
        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "redeem(uint256,address,address)", uint256(partialShares), address(vault), address(vault)
            ),
            abi.encode(partialAssets)
        );
        vm.expectEmit(true, true, true, true);
        emit IERC7575.Withdraw(USER, RECEIVER, USER, partialAssets, partialShares);

        vm.prank(USER);
        uint256 assets = vault.redeem(partialShares, RECEIVER, USER);

        assertEq(assets, partialAssets);
        assertEq(asset.balanceOf(RECEIVER), partialAssets);
        assertEq(vault.pendingRedeemRequest(0, USER), 0); // remainder is still claimable, not pending
        assertEq(vault.claimableRedeemRequest(0, USER), SHARES - partialShares);
    }

    function testRedeemCappedAtClaimable() public {
        asset.mint(address(vault), ASSETS);
        vm.mockCall(
            underlying,
            abi.encodeWithSignature("redeem(uint256,address,address)", uint256(SHARES), address(vault), address(vault)),
            abi.encode(ASSETS)
        );
        vm.expectEmit(true, true, true, true);
        emit IERC7575.Withdraw(USER, RECEIVER, USER, ASSETS, SHARES);

        vm.prank(USER);
        uint256 assets = vault.redeem(uint256(SHARES) * 2, RECEIVER, USER);

        assertEq(assets, ASSETS);
        assertEq(asset.balanceOf(RECEIVER), ASSETS);
        assertEq(vault.claimableRedeemRequest(0, USER), 0);
    }

    function testErrInsufficientClaimableShares() public {
        vm.mockCall(underlying, abi.encodeWithSelector(IERC7575.maxRedeem.selector, address(vault)), abi.encode(0));

        vm.prank(USER);
        vm.expectRevert(IPassthroughVault.InsufficientClaimableShares.selector);
        vault.redeem(SHARES, RECEIVER, USER);
    }

    function testWithdraw() public {
        asset.mint(address(vault), ASSETS);
        vm.mockCall(
            underlying,
            abi.encodeWithSignature("redeem(uint256,address,address)", uint256(SHARES), address(vault), address(vault)),
            abi.encode(ASSETS)
        );
        vm.expectEmit(true, true, true, true);
        emit IERC7575.Withdraw(USER, RECEIVER, USER, ASSETS, SHARES);

        vm.prank(USER);
        uint256 shares = vault.withdraw(type(uint256).max, RECEIVER, USER);

        assertEq(shares, SHARES);
        assertEq(asset.balanceOf(RECEIVER), ASSETS);
    }

    function testErrWithdrawInvalidController() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IPassthroughVault.InvalidController.selector);
        vault.withdraw(ASSETS, RECEIVER, USER);
    }

    function testErrWithdrawInsufficientClaimableShares() public {
        vm.mockCall(underlying, abi.encodeWithSelector(IERC7575.maxRedeem.selector, address(vault)), abi.encode(0));

        vm.prank(USER);
        vm.expectRevert(IPassthroughVault.InsufficientClaimableShares.selector);
        vault.withdraw(ASSETS, RECEIVER, USER);
    }
}

contract PassthroughVaultViewTest is PassthroughVaultTest {
    function testMaxDeposit() public {
        uint256 capacity = 1_000_000e6;
        vm.mockCall(
            underlying, abi.encodeWithSelector(IERC7575.maxDeposit.selector, address(vault)), abi.encode(capacity)
        );
        assertEq(vault.maxDeposit(USER), capacity);
    }

    function testMaxMint() public {
        uint256 capacity = 1_000_000e18;
        vm.mockCall(underlying, abi.encodeWithSelector(IERC7575.maxMint.selector, address(vault)), abi.encode(capacity));
        assertEq(vault.maxMint(USER), capacity);
    }

    function testPreviewDeposit() public {
        uint256 shares = 1000e18;
        vm.mockCall(underlying, abi.encodeWithSignature("previewDeposit(uint256)", uint256(ASSETS)), abi.encode(shares));
        assertEq(vault.previewDeposit(ASSETS), shares);
    }

    function testPreviewMint() public {
        uint128 shares = 100e18;
        uint256 assets = 1000e6;
        vm.mockCall(underlying, abi.encodeWithSignature("previewMint(uint256)", shares), abi.encode(assets));
        assertEq(vault.previewMint(shares), assets);
    }

    function testSupportsInterface() public view {
        assertTrue(vault.supportsInterface(type(IERC7540Redeem).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC7714).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC7575).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC165).interfaceId));
    }
}
