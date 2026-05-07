// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "protocol/misc/ERC20.sol";
import {IERC7714} from "protocol/misc/interfaces/IERC7540.sol";
import {MathLib} from "protocol/misc/libraries/MathLib.sol";

import {PassthroughVault} from "../../src/PassthroughVault.sol";
import {IPassthroughVault} from "../../src/interfaces/IPassthroughVault.sol";
import {IUnderlyingVault} from "../../src/interfaces/IUnderlyingVault.sol";

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
        vault = new PassthroughVault(underlying, memberlist, true, false);
        _setupMocks();
    }

    function _setupMocks() internal virtual {
        vm.mockCall(memberlist, abi.encodeWithSelector(IERC7714.isPermissioned.selector), abi.encode(true));
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.maxRedeem.selector), abi.encode(0));
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.pendingRedeemRequest.selector), abi.encode(0));
        vm.mockCall(underlying, abi.encodeWithSelector(IUnderlyingVault.maxDeposit.selector), abi.encode(0));
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
        PassthroughVault noWhitelistVault = new PassthroughVault(underlying, address(0), false, false);

        asset.mint(USER, ASSETS);
        vm.mockCall(underlying, abi.encodeWithSignature("deposit(uint256,address)", uint256(ASSETS), address(noWhitelistVault)), abi.encode(SHARES));
        share.mint(address(noWhitelistVault), SHARES);
        vm.startPrank(USER);
        asset.approve(address(noWhitelistVault), ASSETS);
        noWhitelistVault.deposit(ASSETS, USER);
        vm.stopPrank();
    }
}

contract PassthroughVaultSyncDepositTest is PassthroughVaultTest {
    function setUp() public override {
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.asset.selector), abi.encode(address(asset)));
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.share.selector), abi.encode(address(share)));
        vault = new PassthroughVault(underlying, memberlist, false, false);
        _setupMocks();
    }

    function testDeposit() public {
        uint256 depositAssets = 1000e6;
        uint128 expectedShares = 100e18;

        asset.mint(USER, depositAssets);
        vm.prank(USER);
        asset.approve(address(vault), depositAssets);

        vm.mockCall(
            underlying,
            abi.encodeWithSignature("deposit(uint256,address)", depositAssets, address(vault)),
            abi.encode(expectedShares)
        );
        vm.expectCall(underlying, abi.encodeWithSignature("deposit(uint256,address)", depositAssets, address(vault)));
        share.mint(address(vault), expectedShares);
        vm.expectEmit(true, true, false, true);
        emit IPassthroughVault.Deposit(USER, RECEIVER, depositAssets, expectedShares);

        vm.prank(USER);
        uint256 sharesOut = vault.deposit(depositAssets, RECEIVER);

        assertEq(sharesOut, expectedShares);
        assertEq(asset.balanceOf(USER), 0);
    }

    function testErrNotMember() public {
        vm.mockCall(memberlist, abi.encodeWithSelector(IERC7714.isPermissioned.selector, USER), abi.encode(false));

        vm.startPrank(USER);
        vm.expectRevert(IPassthroughVault.NotMember.selector);
        vault.deposit(1000e6, RECEIVER);
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

    function testErrAsyncDepositDisabled() public {
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.asset.selector), abi.encode(address(asset)));
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.share.selector), abi.encode(address(share)));
        PassthroughVault syncVault = new PassthroughVault(underlying, memberlist, false, false);

        vm.prank(USER);
        vm.expectRevert(IPassthroughVault.AsyncDepositDisabled.selector);
        syncVault.requestDeposit(ASSETS, USER, USER);

        (uint128 rangeStart, uint128 pending) = syncVault.depositPosition(USER);
        assertEq(rangeStart, 0);
        assertEq(pending, 0);

        assertEq(syncVault.pendingDepositRequest(0, USER), 0);
    }

    function testErrInvalidController() public {
        vm.prank(USER);
        vm.expectRevert(IPassthroughVault.InvalidController.selector);
        vault.requestDeposit(ASSETS, USER2, USER);
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
            underlying,
            abi.encodeWithSelector(IUnderlyingVault.maxDeposit.selector, address(vault)),
            abi.encode(ASSETS)
        );
    }

    function testDepositClaimCappedAtClaimable() public {
        share.mint(address(vault), SHARES);
        vm.mockCall(
            underlying,
            abi.encodeWithSignature(
                "deposit(uint256,address,address)", uint256(ASSETS), address(vault), address(vault)
            ),
            abi.encode(SHARES)
        );

        vm.prank(USER);
        uint256 sharesOut = vault.deposit(uint256(ASSETS) * 2, RECEIVER, USER);

        assertEq(sharesOut, SHARES);
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

    function testErrDepositClaimInvalidController() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IPassthroughVault.InvalidController.selector);
        vault.deposit(ASSETS, RECEIVER, USER);
    }

    function testErrDepositClaimInsufficientClaimable() public {
        // No prior requestDeposit for USER2
        vm.prank(USER2);
        vm.expectRevert(IPassthroughVault.InsufficientClaimableShares.selector);
        vault.deposit(ASSETS, RECEIVER, USER2);
    }
}

contract PassthroughVaultPermissionlessDepositClaimTest is PassthroughVaultTest {
    function setUp() public override {
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.asset.selector), abi.encode(address(asset)));
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.share.selector), abi.encode(address(share)));
        vault = new PassthroughVault(underlying, memberlist, true, true);
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
            underlying,
            abi.encodeWithSelector(IUnderlyingVault.maxDeposit.selector, address(vault)),
            abi.encode(ASSETS)
        );
    }

    function testPermissionlessDepositClaim() public {
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
        uint256 sharesOut = vault.deposit(type(uint256).max, USER, USER);

        assertEq(sharesOut, SHARES);
        assertEq(share.balanceOf(USER), SHARES);
        assertEq(vault.claimableDepositRequest(0, USER), 0);
    }

    function testErrPermissionlessDepositClaimNotAllowed() public {
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.asset.selector), abi.encode(address(asset)));
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.share.selector), abi.encode(address(share)));
        PassthroughVault restrictedVault = new PassthroughVault(underlying, memberlist, true, false);

        vm.prank(RECEIVER);
        vm.expectRevert(IPassthroughVault.InvalidController.selector);
        restrictedVault.deposit(ASSETS, USER, USER);
    }

    function testErrPermissionlessDepositClaimInsufficientClaimable() public {
        vm.prank(RECEIVER);
        vm.expectRevert(IPassthroughVault.InsufficientClaimableShares.selector);
        vault.deposit(ASSETS, USER2, USER2);
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

    function testErrInvalidController() public {
        vm.prank(USER);
        vm.expectRevert(IPassthroughVault.InvalidController.selector);
        vault.requestRedeem(SHARES, USER2, USER);
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
        assertEq(vault.pendingRedeemRequest(0, USER), 0);
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

    function testErrRedeemInvalidController() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IPassthroughVault.InvalidController.selector);
        vault.redeem(SHARES, RECEIVER, USER);
    }

    function testErrRedeemInsufficientClaimableShares() public {
        vm.mockCall(
            underlying, abi.encodeWithSelector(IPassthroughVault.maxRedeem.selector, address(vault)), abi.encode(0)
        );

        vm.prank(USER);
        vm.expectRevert(IPassthroughVault.InsufficientClaimableShares.selector);
        vault.redeem(SHARES, RECEIVER, USER);
    }
}

contract PassthroughVaultPermissionlessRedeemClaimTest is PassthroughVaultTest {
    function setUp() public override {
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.asset.selector), abi.encode(address(asset)));
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.share.selector), abi.encode(address(share)));
        vault = new PassthroughVault(underlying, memberlist, true, true);
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
    }

    function testPermissionlessRedeemClaim() public {
        asset.mint(address(vault), ASSETS);
        vm.mockCall(
            underlying,
            abi.encodeWithSignature("redeem(uint256,address,address)", uint256(SHARES), address(vault), address(vault)),
            abi.encode(ASSETS)
        );
        vm.expectEmit(true, true, true, true);
        emit IPassthroughVault.Withdraw(RECEIVER, USER, USER, ASSETS, SHARES);

        vm.prank(RECEIVER);
        uint256 assets = vault.redeem(type(uint256).max, USER, USER);

        assertEq(assets, ASSETS);
        assertEq(asset.balanceOf(USER), ASSETS);
        assertEq(vault.claimableRedeemRequest(0, USER), 0);
    }

    function testErrPermissionlessRedeemClaimNotAllowed() public {
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.asset.selector), abi.encode(address(asset)));
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.share.selector), abi.encode(address(share)));
        PassthroughVault restrictedVault = new PassthroughVault(underlying, memberlist, true, false);

        vm.prank(USER2);
        vm.expectRevert(IPassthroughVault.InvalidController.selector);
        restrictedVault.redeem(SHARES, USER, USER);
    }

    function testErrPermissionlessRedeemClaimInsufficientClaimableShares() public {
        vm.mockCall(
            underlying, abi.encodeWithSelector(IPassthroughVault.maxRedeem.selector, address(vault)), abi.encode(0)
        );

        vm.prank(USER2);
        vm.expectRevert(IPassthroughVault.InsufficientClaimableShares.selector);
        vault.redeem(SHARES, USER, USER);
    }
}

contract PassthroughVaultViewTest is PassthroughVaultTest {
    function testDepositAndRedeemViews() public view {
        assertEq(vault.maxDeposit(USER), 0);
        assertEq(vault.maxRedeem(USER), 0);
    }

    function testTotalAssets() public {
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.totalAssets.selector), abi.encode(ASSETS));
        assertEq(vault.totalAssets(), ASSETS);
    }

    function testConvertToShares() public {
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.convertToShares.selector), abi.encode(SHARES));
        assertEq(vault.convertToShares(ASSETS), SHARES);
    }

    function testConvertToAssets() public {
        vm.mockCall(underlying, abi.encodeWithSelector(IPassthroughVault.convertToAssets.selector), abi.encode(ASSETS));
        assertEq(vault.convertToAssets(SHARES), ASSETS);
    }
}

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

        vm.mockCall(
            underlying,
            abi.encodeWithSelector(IUnderlyingVault.maxDeposit.selector, address(vault)),
            abi.encode(ASSETS)
        );
    }

    function testFuzzDepositClampsToPendingClaimable(uint64 settledAssets, uint64 requestedAssets) public {
        settledAssets = uint64(bound(settledAssets, 1, ASSETS)); // can't settle more than what was requested
        requestedAssets = uint64(bound(requestedAssets, 1, uint64(ASSETS) * 2)); // test both under and over-requesting

        vm.mockCall(
            underlying,
            abi.encodeWithSelector(IUnderlyingVault.maxDeposit.selector, address(vault)),
            abi.encode(settledAssets)
        );

        // claimable = min(pending=ASSETS, settled=settledAssets) = settledAssets
        uint128 actualAssets = uint128(MathLib.min(requestedAssets, settledAssets));
        uint256 sharesOut = actualAssets; // 1:1 mock
        share.mint(address(vault), sharesOut);
        vm.mockCall(
            underlying,
            abi.encodeWithSignature("deposit(uint256,address,address)", uint256(actualAssets), address(vault), address(vault)),
            abi.encode(sharesOut)
        );

        vm.prank(USER);
        uint256 shares = vault.deposit(requestedAssets, RECEIVER, USER);

        assertEq(shares, sharesOut);
        assertEq(share.balanceOf(RECEIVER), sharesOut);
    }
}

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

        vm.mockCall(
            underlying, abi.encodeWithSelector(IPassthroughVault.maxRedeem.selector, address(vault)), abi.encode(SHARES)
        );
    }

    function testFuzzRedeemClampsToPendingClaimable(uint64 settledShares, uint64 requestedShares) public {
        settledShares = uint64(bound(settledShares, 1, SHARES)); // can't settle more than what was requested
        requestedShares = uint64(bound(requestedShares, 1, uint64(SHARES) * 2)); // test both under and over-requesting

        vm.mockCall(
            underlying,
            abi.encodeWithSelector(IPassthroughVault.maxRedeem.selector, address(vault)),
            abi.encode(settledShares)
        );

        // claimable = min(pending=SHARES, settled=settledShares) = settledShares
        uint128 actualShares = uint128(MathLib.min(requestedShares, settledShares));
        uint256 assetsOut = actualShares; // 1:1 mock
        asset.mint(address(vault), assetsOut);
        vm.mockCall(
            underlying,
            abi.encodeWithSignature("redeem(uint256,address,address)", uint256(actualShares), address(vault), address(vault)),
            abi.encode(assetsOut)
        );

        vm.prank(USER);
        uint256 assets = vault.redeem(requestedShares, RECEIVER, USER);

        assertEq(assets, assetsOut);
        assertEq(asset.balanceOf(RECEIVER), assetsOut);
    }
}
