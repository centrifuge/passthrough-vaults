// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "protocol/misc/ERC20.sol";
import {IERC7714} from "protocol/misc/interfaces/IERC7540.sol";
import {MathLib} from "protocol/misc/libraries/MathLib.sol";

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
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.asset.selector), abi.encode(address(asset)));
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.share.selector), abi.encode(address(share)));
        vault = new PassthroughVault(underlying, memberlist, false);
        _setupMocks();
    }

    function _setupMocks() internal virtual {
        vm.mockCall(memberlist, abi.encodeWithSelector(IERC7714.isPermissioned.selector), abi.encode(true));
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.maxRedeem.selector), abi.encode(0));
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.pendingRedeemRequest.selector), abi.encode(0));
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.maxDeposit.selector), abi.encode(0));
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
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.asset.selector), abi.encode(address(asset)));
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.share.selector), abi.encode(address(share)));
        PassthroughVault noWhitelistVault = new PassthroughVault(underlying, address(0), false);

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
        emit IPassthroughVault.Deposit(USER, RECEIVER, ASSETS, sharesOut);

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
        emit IPassthroughVault.Deposit(USER, RECEIVER, previewAssets, shares);

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

contract PassthroughVaultRequestDepositTest is PassthroughVaultTest {
    function testRequestDeposit() public {
        asset.mint(USER, ASSETS);
        vm.prank(USER);
        asset.approve(address(vault), ASSETS);

        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "requestDeposit(uint256,address,address)", uint256(ASSETS), address(vault), address(vault)
            ),
            abi.encode(0)
        );

        vm.expectEmit(true, true, true, true);
        emit IPassthroughVault.DepositRequest(USER, USER, 0, USER, ASSETS);
        vm.prank(USER);
        uint256 requestId = vault.requestDeposit(ASSETS, USER, USER);

        assertEq(requestId, 0);
        assertEq(asset.balanceOf(USER), 0);
        assertEq(vault.pendingDepositRequest(0, USER), ASSETS);
        assertEq(vault.cumulativeDepositRequested(), ASSETS);
    }

    function testRequestDepositAccumulatesForMultipleUsers() public {
        uint128 assets2 = ASSETS / 2;

        asset.mint(USER, ASSETS);
        asset.mint(USER2, assets2);
        vm.prank(USER);
        asset.approve(address(vault), ASSETS);
        vm.prank(USER2);
        asset.approve(address(vault), assets2);

        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "requestDeposit(uint256,address,address)", uint256(ASSETS), address(vault), address(vault)
            ),
            abi.encode(0)
        );
        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "requestDeposit(uint256,address,address)", uint256(assets2), address(vault), address(vault)
            ),
            abi.encode(0)
        );

        vm.expectEmit(true, true, true, true);
        emit IPassthroughVault.DepositRequest(USER, USER, 0, USER, ASSETS);
        vm.prank(USER);
        vault.requestDeposit(ASSETS, USER, USER);
        vm.expectEmit(true, true, true, true);
        emit IPassthroughVault.DepositRequest(USER2, USER2, 0, USER2, assets2);
        vm.prank(USER2);
        vault.requestDeposit(assets2, USER2, USER2);

        assertEq(vault.pendingDepositRequest(0, USER), ASSETS);
        assertEq(vault.pendingDepositRequest(0, USER2), assets2);
        assertEq(vault.cumulativeDepositRequested(), ASSETS + assets2);

        (uint128 rangeStart1,) = vault.depositPosition(USER);
        (uint128 rangeStart2,) = vault.depositPosition(USER2);
        assertEq(rangeStart1, 0);
        assertEq(rangeStart2, ASSETS); // USER2 starts where USER ends
    }

    function testRequestDepositTwiceBeforeSettlement() public {
        uint128 firstAssets = ASSETS / 2;

        asset.mint(USER, firstAssets + ASSETS);
        vm.prank(USER);
        asset.approve(address(vault), firstAssets + ASSETS);

        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "requestDeposit(uint256,address,address)", uint256(firstAssets), address(vault), address(vault)
            ),
            abi.encode(0)
        );
        vm.expectEmit(true, true, true, true);
        emit IPassthroughVault.DepositRequest(USER, USER, 0, USER, firstAssets);
        vm.prank(USER);
        vault.requestDeposit(firstAssets, USER, USER);

        assertEq(vault.pendingDepositRequest(0, USER), firstAssets);
        assertEq(vault.cumulativeDepositRequested(), firstAssets);
        (uint128 rangeStart, uint128 pending) = vault.depositPosition(USER);
        assertEq(rangeStart, 0);
        assertEq(pending, firstAssets);

        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "requestDeposit(uint256,address,address)", uint256(ASSETS), address(vault), address(vault)
            ),
            abi.encode(0)
        );
        vm.expectEmit(true, true, true, true);
        emit IPassthroughVault.DepositRequest(USER, USER, 0, USER, ASSETS);
        vm.prank(USER);
        vault.requestDeposit(ASSETS, USER, USER);

        assertEq(vault.pendingDepositRequest(0, USER), firstAssets + ASSETS);
        assertEq(vault.cumulativeDepositRequested(), firstAssets + ASSETS);
        (rangeStart, pending) = vault.depositPosition(USER);
        assertEq(rangeStart, 0);
        assertEq(pending, firstAssets + ASSETS);
    }

    function testErrInvalidOwner() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IPassthroughVault.InvalidOwner.selector);
        vault.requestDeposit(ASSETS, USER, USER);
    }

    function testErrInsufficientAssets() public {
        vm.prank(USER);
        vm.expectRevert();
        vault.requestDeposit(ASSETS, USER, USER);
    }

    function testErrNotMember() public {
        vm.mockCall(memberlist, abi.encodeWithSelector(IERC7714.isPermissioned.selector, USER), abi.encode(false));
        asset.mint(USER, ASSETS);
        vm.startPrank(USER);
        asset.approve(address(vault), ASSETS);
        vm.expectRevert(IPassthroughVault.NotMember.selector);
        vault.requestDeposit(ASSETS, USER, USER);
        vm.stopPrank();
    }
}

contract PassthroughVaultDepositClaimTest is PassthroughVaultTest {
    function setUp() public override {
        super.setUp();

        asset.mint(USER, ASSETS);
        vm.prank(USER);
        asset.approve(address(vault), ASSETS);

        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "requestDeposit(uint256,address,address)", uint256(ASSETS), address(vault), address(vault)
            ),
            abi.encode(0)
        );

        vm.prank(USER);
        vault.requestDeposit(ASSETS, USER, USER);

        // Simulate settlement
        vm.mockCall(
            underlying, abi.encodeWithSelector(IPassthroughVault.maxDeposit.selector, address(vault)), abi.encode(ASSETS)
        );
    }

    function testDepositClaim() public {
        share.mint(address(vault), SHARES);
        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "deposit(uint256,address,address)", uint256(ASSETS), address(vault), address(vault)
            ),
            abi.encode(SHARES)
        );
        vm.expectEmit(true, true, false, true);
        emit IPassthroughVault.Deposit(USER, RECEIVER, ASSETS, SHARES);

        vm.prank(USER);
        uint256 sharesOut = vault.deposit(ASSETS, RECEIVER, USER);

        assertEq(sharesOut, SHARES);
        assertEq(share.balanceOf(RECEIVER), SHARES);
        assertEq(vault.claimableDepositRequest(0, USER), 0);
    }

    function testDepositClaimMax() public {
        share.mint(address(vault), SHARES);
        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "deposit(uint256,address,address)", uint256(ASSETS), address(vault), address(vault)
            ),
            abi.encode(SHARES)
        );
        vm.expectEmit(true, true, false, true);
        emit IPassthroughVault.Deposit(USER, RECEIVER, ASSETS, SHARES);

        vm.prank(USER);
        uint256 sharesOut = vault.deposit(type(uint256).max, RECEIVER, USER);

        assertEq(sharesOut, SHARES);
        assertEq(share.balanceOf(RECEIVER), SHARES);
    }

    function testMintClaim() public {
        share.mint(address(vault), SHARES);
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.maxMint.selector, address(vault)), abi.encode(SHARES));
        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "deposit(uint256,address,address)", uint256(ASSETS), address(vault), address(vault)
            ),
            abi.encode(SHARES)
        );
        vm.expectEmit(true, true, false, true);
        emit IPassthroughVault.Deposit(USER, RECEIVER, ASSETS, SHARES);

        vm.prank(USER);
        uint256 assetsOut = vault.mint(SHARES, RECEIVER, USER);

        assertEq(assetsOut, ASSETS);
        assertEq(share.balanceOf(RECEIVER), SHARES);
        assertEq(vault.claimableDepositRequest(0, USER), 0);
    }

    function testMintClaimMax() public {
        share.mint(address(vault), SHARES);
        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "deposit(uint256,address,address)", uint256(ASSETS), address(vault), address(vault)
            ),
            abi.encode(SHARES)
        );

        vm.prank(USER);
        uint256 assetsOut = vault.mint(type(uint256).max, RECEIVER, USER);

        assertEq(assetsOut, ASSETS);
        assertEq(share.balanceOf(RECEIVER), SHARES);
    }

    function testMintClaimCappedAtClaimable() public {
        share.mint(address(vault), SHARES);
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.maxMint.selector, address(vault)), abi.encode(SHARES));
        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "deposit(uint256,address,address)", uint256(ASSETS), address(vault), address(vault)
            ),
            abi.encode(SHARES)
        );

        vm.prank(USER);
        uint256 assetsOut = vault.mint(uint256(SHARES) * 2, RECEIVER, USER);

        assertEq(assetsOut, ASSETS);
        assertEq(share.balanceOf(RECEIVER), SHARES);
        assertEq(vault.claimableDepositRequest(0, USER), 0);
    }

    function testNewJoinerExcludedFromEarlierDeposit() public {
        asset.mint(USER2, ASSETS);
        vm.prank(USER2);
        asset.approve(address(vault), ASSETS);

        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "requestDeposit(uint256,address,address)", uint256(ASSETS), address(vault), address(vault)
            ),
            abi.encode(0)
        );
        vm.prank(USER2);
        vault.requestDeposit(ASSETS, USER2, USER2);

        // USER's position [0, ASSETS) is within the settled window (maxDeposit = ASSETS).
        // USER2's position [ASSETS, 2*ASSETS) starts exactly at the settlement boundary — not yet settled.
        assertEq(vault.claimableDepositRequest(0, USER), ASSETS);
        assertEq(vault.claimableDepositRequest(0, USER2), 0);
    }

    function testErrDepositClaimInvalidController() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IPassthroughVault.InvalidController.selector);
        vault.deposit(ASSETS, RECEIVER, USER);
    }

    function testErrMintClaimInvalidController() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IPassthroughVault.InvalidController.selector);
        vault.mint(SHARES, RECEIVER, USER);
    }

    function testErrDepositClaimInsufficientClaimable() public {
        // No prior requestDeposit for USER2
        vm.prank(USER2);
        vm.expectRevert(IPassthroughVault.InsufficientClaimableShares.selector);
        vault.deposit(ASSETS, RECEIVER, USER2);
    }
}

contract PassthroughVaultClaimDepositForTest is PassthroughVaultTest {
    function setUp() public override {
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.asset.selector), abi.encode(address(asset)));
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.share.selector), abi.encode(address(share)));
        vault = new PassthroughVault(underlying, memberlist, true);
        _setupMocks();

        asset.mint(USER, ASSETS);
        vm.prank(USER);
        asset.approve(address(vault), ASSETS);

        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "requestDeposit(uint256,address,address)", uint256(ASSETS), address(vault), address(vault)
            ),
            abi.encode(0)
        );

        vm.prank(USER);
        vault.requestDeposit(ASSETS, USER, USER);

        // Simulate settlement
        vm.mockCall(
            underlying, abi.encodeWithSelector(IPassthroughVault.maxDeposit.selector, address(vault)), abi.encode(ASSETS)
        );
    }

    function testClaimDepositFor() public {
        share.mint(address(vault), SHARES);
        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "deposit(uint256,address,address)", uint256(ASSETS), address(vault), address(vault)
            ),
            abi.encode(SHARES)
        );
        vm.expectEmit(true, true, false, true);
        emit IPassthroughVault.Deposit(RECEIVER, USER, ASSETS, SHARES);

        vm.prank(RECEIVER);
        uint256 sharesOut = vault.claimDepositFor(USER);

        assertEq(sharesOut, SHARES);
        assertEq(share.balanceOf(USER), SHARES);
        assertEq(vault.claimableDepositRequest(0, USER), 0);
    }

    function testErrClaimDepositForPermissionlessClaimingNotAllowed() public {
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.asset.selector), abi.encode(address(asset)));
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.share.selector), abi.encode(address(share)));
        PassthroughVault restrictedVault = new PassthroughVault(underlying, memberlist, false);

        vm.expectRevert(IPassthroughVault.PermissionlessClaimingNotAllowed.selector);
        restrictedVault.claimDepositFor(USER);
    }

    function testErrClaimDepositForInsufficientClaimable() public {
        vm.expectRevert(IPassthroughVault.InsufficientClaimableShares.selector);
        vault.claimDepositFor(USER2);
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
        emit IPassthroughVault.RedeemRequest(USER, USER, 0, USER, SHARES);
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
        emit IPassthroughVault.RedeemRequest(USER, USER, 0, USER, SHARES);
        vm.prank(USER);
        vault.requestRedeem(SHARES, USER, USER);
        vm.expectEmit(true, true, true, true);
        emit IPassthroughVault.RedeemRequest(USER2, USER2, 0, USER2, shares2);
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
        emit IPassthroughVault.RedeemRequest(USER, USER, 0, USER, firstShares);
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
        emit IPassthroughVault.RedeemRequest(USER, USER, 0, USER, secondShares);
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

        vm.mockCall(
            underlying, abi.encodeWithSelector(IPassthroughVault.maxRedeem.selector, address(vault)), abi.encode(SHARES)
        );
        vm.mockCall(
            underlying,
            abi.encodeWithSelector(IPassthroughVault.maxWithdraw.selector, address(vault)),
            abi.encode(ASSETS)
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
        emit IPassthroughVault.Withdraw(USER, RECEIVER, USER, ASSETS, SHARES);

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
        emit IPassthroughVault.Withdraw(USER, RECEIVER, USER, ASSETS, SHARES);

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
        emit IPassthroughVault.Withdraw(USER, RECEIVER, USER, partialAssets, partialShares);

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
        emit IPassthroughVault.Withdraw(USER, RECEIVER, USER, ASSETS, SHARES);

        vm.prank(USER);
        uint256 assets = vault.redeem(uint256(SHARES) * 2, RECEIVER, USER);

        assertEq(assets, ASSETS);
        assertEq(asset.balanceOf(RECEIVER), ASSETS);
        assertEq(vault.claimableRedeemRequest(0, USER), 0);
    }

    function testErrInsufficientClaimableShares() public {
        vm.mockCall(
            underlying, abi.encodeWithSelector(IPassthroughVault.maxRedeem.selector, address(vault)), abi.encode(0)
        );

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
        emit IPassthroughVault.Withdraw(USER, RECEIVER, USER, ASSETS, SHARES);

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
        vm.mockCall(
            underlying, abi.encodeWithSelector(IPassthroughVault.maxRedeem.selector, address(vault)), abi.encode(0)
        );

        vm.prank(USER);
        vm.expectRevert(IPassthroughVault.InsufficientClaimableShares.selector);
        vault.withdraw(ASSETS, RECEIVER, USER);
    }
}

contract PassthroughVaultClaimRedeemForTest is PassthroughVaultTest {
    function setUp() public override {
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.asset.selector), abi.encode(address(asset)));
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.share.selector), abi.encode(address(share)));
        vault = new PassthroughVault(underlying, memberlist, true);
        _setupMocks();

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

        vm.mockCall(
            underlying, abi.encodeWithSelector(IPassthroughVault.maxRedeem.selector, address(vault)), abi.encode(SHARES)
        );
        vm.mockCall(
            underlying,
            abi.encodeWithSelector(IPassthroughVault.maxWithdraw.selector, address(vault)),
            abi.encode(ASSETS)
        );
    }

    function testClaimRedeemFor() public {
        asset.mint(address(vault), ASSETS);
        vm.mockCall(
            underlying,
            abi.encodeWithSignature("redeem(uint256,address,address)", uint256(SHARES), address(vault), address(vault)),
            abi.encode(ASSETS)
        );
        vm.expectEmit(true, true, true, true);
        emit IPassthroughVault.Withdraw(RECEIVER, USER, USER, ASSETS, SHARES);

        vm.prank(RECEIVER);
        uint256 assets = vault.claimRedeemFor(USER);

        assertEq(assets, ASSETS);
        assertEq(asset.balanceOf(USER), ASSETS);
        assertEq(vault.claimableRedeemRequest(0, USER), 0);
    }

    function testErrPermissionlessClaimingNotAllowed() public {
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.asset.selector), abi.encode(address(asset)));
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.share.selector), abi.encode(address(share)));
        PassthroughVault restrictedVault = new PassthroughVault(underlying, memberlist, false);

        vm.expectRevert(IPassthroughVault.PermissionlessClaimingNotAllowed.selector);
        restrictedVault.claimRedeemFor(USER);
    }

    function testErrClaimRedeemForInsufficientClaimableShares() public {
        vm.mockCall(
            underlying, abi.encodeWithSelector(IPassthroughVault.maxRedeem.selector, address(vault)), abi.encode(0)
        );

        vm.expectRevert(IPassthroughVault.InsufficientClaimableShares.selector);
        vault.claimRedeemFor(USER);
    }
}

/// @notice Fuzz the deposit pricing invariant: mint(shares) gives the receiver ≥ shares−1 shares.
///
///         The vault converts the requested shares to assets using Up rounding
///         (_depositSharesToAssets), then calls the underlying's deposit(assets) which uses
///         floor division. The Up rounding compensates so the receiver never gets less than
///         requested (within 1 wei).
contract PassthroughVaultDepositPricingFuzzTest is PassthroughVaultTest {
    function setUp() public override {
        super.setUp();

        asset.mint(USER, ASSETS);
        vm.prank(USER);
        asset.approve(address(vault), ASSETS);

        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "requestDeposit(uint256,address,address)", uint256(ASSETS), address(vault), address(vault)
            ),
            abi.encode(0)
        );

        vm.prank(USER);
        vault.requestDeposit(ASSETS, USER, USER);

        // Fully settle USER's position.
        vm.mockCall(
            underlying, abi.encodeWithSelector(IPassthroughVault.maxDeposit.selector, address(vault)), abi.encode(ASSETS)
        );
    }

    /// @dev Invariant: receiver gets exactly ≥ requestedShares shares.
    ///
    ///      Up rounding in _depositSharesToAssets ensures that the assets spent always cover
    ///      the requested shares. The invariant only applies when the request does not exceed
    ///      the available claimable amount (requestedShares ≤ settledShares).
    function testFuzz_mint_receiverGetsRequestedShares(uint64 settledShares, uint64 requestedShares) public {
        settledShares = uint64(bound(settledShares, 1, type(uint64).max));
        // Bound requestedShares ≤ settledShares so actualAssets stays within claimable (no cap).
        requestedShares = uint64(bound(requestedShares, 1, settledShares));

        vm.mockCall(
            underlying, abi.encodeWithSelector(IPassthroughVault.maxMint.selector, address(vault)), abi.encode(settledShares)
        );

        // Mirror the vault's _depositSharesToAssets(requestedShares, Up) logic:
        // actualAssets = ceil(requestedShares * ASSETS / settledShares) ≤ ASSETS (no cap since requestedShares ≤ settledShares)
        uint256 actualAssets = MathLib.mulDiv(requestedShares, uint256(ASSETS), settledShares, MathLib.Rounding.Up);

        // Mirror what the underlying's deposit(3-arg) returns (floor division at settlement price).
        uint256 sharesOut = MathLib.mulDiv(actualAssets, settledShares, uint256(ASSETS), MathLib.Rounding.Down);

        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "deposit(uint256,address,address)", actualAssets, address(vault), address(vault)
            ),
            abi.encode(sharesOut)
        );
        share.mint(address(vault), sharesOut);

        vm.prank(USER);
        uint256 assetsSpent = vault.mint(requestedShares, RECEIVER, USER);

        assertEq(assetsSpent, actualAssets);
        // Up rounding guarantees: floor(ceil(q * n/d) * d/n) ≥ q exactly.
        assertGe(share.balanceOf(RECEIVER), requestedShares);
    }
}

/// @notice Fuzz the redeem pricing invariant: withdraw(assets) gives the receiver ≥ assets−1 assets.
///
///         The vault converts the requested assets to shares using Up rounding
///         (_redeemAssetsToShares), then calls the underlying's redeem(shares) which uses
///         floor division. The Up rounding compensates so the receiver never gets less than
///         requested (within 1 wei).
contract PassthroughVaultRedeemPricingFuzzTest is PassthroughVaultTest {
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

        // Fully settle USER's position.
        vm.mockCall(
            underlying, abi.encodeWithSelector(IPassthroughVault.maxRedeem.selector, address(vault)), abi.encode(SHARES)
        );
    }

    /// @dev Invariant: receiver gets exactly ≥ requestedAssets assets.
    ///
    ///      Up rounding in _redeemAssetsToShares ensures that the shares redeemed always cover
    ///      the requested assets. The invariant only applies when the request does not exceed
    ///      the available claimable amount (requestedAssets ≤ settledAssets).
    function testFuzz_withdraw_receiverGetsRequestedAssets(uint64 settledAssets, uint64 requestedAssets) public {
        settledAssets = uint64(bound(settledAssets, 1, type(uint64).max));
        // Bound requestedAssets ≤ settledAssets so actualShares stays within claimable (no cap).
        requestedAssets = uint64(bound(requestedAssets, 1, settledAssets));

        vm.mockCall(
            underlying,
            abi.encodeWithSelector(IPassthroughVault.maxWithdraw.selector, address(vault)),
            abi.encode(settledAssets)
        );

        // Mirror the vault's _redeemAssetsToShares(requestedAssets, Up) logic:
        // actualShares = ceil(requestedAssets * SHARES / settledAssets) ≤ SHARES (no cap since requestedAssets ≤ settledAssets)
        uint256 actualShares = MathLib.mulDiv(requestedAssets, uint256(SHARES), settledAssets, MathLib.Rounding.Up);

        // Mirror what the underlying's redeem(3-arg) returns (floor division at settlement price).
        uint256 assetsOut = MathLib.mulDiv(actualShares, settledAssets, uint256(SHARES), MathLib.Rounding.Down);

        asset.mint(address(vault), assetsOut);
        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "redeem(uint256,address,address)", actualShares, address(vault), address(vault)
            ),
            abi.encode(assetsOut)
        );

        vm.prank(USER);
        uint256 sharesRedeemed = vault.withdraw(requestedAssets, RECEIVER, USER);

        assertEq(sharesRedeemed, actualShares);
        // Up rounding guarantees: floor(ceil(q * n/d) * d/n) ≥ q exactly.
        assertGe(asset.balanceOf(RECEIVER), requestedAssets);
    }
}
