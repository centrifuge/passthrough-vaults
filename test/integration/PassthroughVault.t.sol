// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "protocol/misc/ERC20.sol";
import {SyncDepositVault} from "protocol/vaults/SyncDepositVault.sol";
import {AsyncVault} from "protocol/vaults/AsyncVault.sol";

import {PassthroughVault} from "../../src/PassthroughVault.sol";
import {IntegrationBaseTest} from "./BaseTest.sol";

contract PassthroughVaultTest is IntegrationBaseTest {
    uint128 constant INITIAL_BALANCE = 5_000e6;

    // Share token has 18 decimals, USDC has 6 — scale factor between asset and share amounts.
    uint256 constant SHARE_SCALE = 1e12;

    address immutable INVESTOR = makeAddr("INVESTOR");
    address immutable INVESTOR2 = makeAddr("INVESTOR2");

    SyncDepositVault underlying;
    PassthroughVault passthroughVault;
    uint128 assetId;

    function setUp() public override {
        super.setUp();

        (underlying, assetId) = _deploySyncDepositVault();
        passthroughVault = _deployPassthroughVault(address(underlying), false);

        _mintUSDC(INVESTOR, INITIAL_BALANCE);
        _mintUSDC(INVESTOR2, INITIAL_BALANCE);

        vm.startPrank(INVESTOR);
        usdc.approve(address(passthroughVault), type(uint256).max);
        ERC20(underlying.share()).approve(address(passthroughVault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(INVESTOR2);
        usdc.approve(address(passthroughVault), type(uint256).max);
        ERC20(underlying.share()).approve(address(passthroughVault), type(uint256).max);
        vm.stopPrank();
    }

    function testFullFlow() public {
        uint256 depositAmount = 1000e6;
        uint256 expectedShares = depositAmount * SHARE_SCALE;

        vm.prank(INVESTOR);
        uint256 sharesMinted = passthroughVault.deposit(depositAmount, INVESTOR);

        assertEq(sharesMinted, expectedShares);
        assertEq(ERC20(underlying.share()).balanceOf(INVESTOR), expectedShares);

        vm.prank(INVESTOR);
        passthroughVault.requestRedeem(expectedShares, INVESTOR, INVESTOR);

        assertEq(ERC20(underlying.share()).balanceOf(INVESTOR), 0);
        assertEq(passthroughVault.pendingRedeemRequest(0, INVESTOR), expectedShares);

        _settleRedeem(passthroughVault, uint128(expectedShares));
        assertEq(underlying.maxWithdraw(address(passthroughVault)), depositAmount);

        uint256 balanceBefore = usdc.balanceOf(INVESTOR);
        vm.prank(INVESTOR);
        uint256 assetsReceived = passthroughVault.redeem(expectedShares, INVESTOR, INVESTOR);

        assertEq(assetsReceived, depositAmount);
        assertEq(usdc.balanceOf(INVESTOR) - balanceBefore, depositAmount);
        assertEq(underlying.maxWithdraw(address(passthroughVault)), 0);
    }

    // Shows the effect of a subsequent requestRedeem by the same investor after a partial settlement.
    // The orphaned and overlapping segments resolve when the settlement catches up, only affecting
    // the user who re-requested. In the end everybody should get the correct amount of assets.
    //
    // Queue after first two requests (in share units):
    //           0                    1000e18               2000e18
    //           |--------------------|---------------------|
    //           [      User A        ][      User B        ]
    //
    // Queue after first partial settlement (500e18 settled):
    //           0        500e18       1000e18              2000e18
    //           |XXXXXXXX|------------|---------------------|
    //           [Settled ][ User A   ][      User B        ]
    //
    // Queue after User A re-requests (500e18 new shares):
    //           0        500e18              1000e18            1500e18           2000e18         2500e18
    //           |XXXXXXXX|-------------------|------------------|-----------------|----------------|
    //           [Settled ][ Orphaned (500e18)][         User B                   ]
    //                                                           [Overlap (500e18) ]
    //                                                           [        User A (1000e18)          ]
    function testRequestAgainWithPartialFulfillment() public {
        // INVESTOR deposits 1500e6 so they have 500e18 shares left after the first requestRedeem (1000e18),
        // which they use for the second requestRedeem that triggers the force-claim and re-queuing.
        vm.prank(INVESTOR);
        passthroughVault.deposit(1500e6, INVESTOR);
        vm.prank(INVESTOR2);
        passthroughVault.deposit(1000e6, INVESTOR2);

        vm.prank(INVESTOR);
        passthroughVault.requestRedeem(1000e18, INVESTOR, INVESTOR);
        vm.prank(INVESTOR2);
        passthroughVault.requestRedeem(1000e18, INVESTOR2, INVESTOR2);

        _settleRedeem(passthroughVault, 500e18);

        assertEq(passthroughVault.maxRedeem(INVESTOR), 500e18);
        assertEq(passthroughVault.maxRedeem(INVESTOR2), 0);

        vm.prank(INVESTOR);
        passthroughVault.requestRedeem(500e18, INVESTOR, INVESTOR);

        // Investor A's position should be re-queued to [oldCumulative - oldPending, oldCumulative + newlyRequested]
        // = [1500e18, 2500e18]
        (uint128 rangeStart, uint128 pending) = passthroughVault.redeemPosition(INVESTOR);
        assertEq(rangeStart, 1500e18);
        assertEq(pending, 1000e18);

        assertEq(passthroughVault.pendingRedeemRequest(0, INVESTOR), 1000e18);
        assertEq(passthroughVault.cumulativeRedeemRequested(), 2500e18);
        assertEq(passthroughVault.maxRedeem(INVESTOR), 0);
        assertEq(passthroughVault.maxRedeem(INVESTOR2), 0);

        _settleRedeem(passthroughVault, 500e18);

        // Settling the orphaned segment won't make anything claimable
        assertEq(passthroughVault.maxRedeem(INVESTOR), 0);
        assertEq(passthroughVault.maxRedeem(INVESTOR2), 0);

        _settleRedeem(passthroughVault, 500e18);

        // Settling [1000e18, 1500e18] makes 500e18 shares claimable for investor B only
        assertEq(passthroughVault.maxRedeem(INVESTOR), 0);
        assertEq(passthroughVault.maxRedeem(INVESTOR2), 500e18);

        _settleRedeem(passthroughVault, 500e18);

        // Settling the overlapping segment makes the remaining 500e18 claimable for B and 1000e18 for A
        assertEq(passthroughVault.maxRedeem(INVESTOR), 500e18);
        assertEq(passthroughVault.maxRedeem(INVESTOR2), 1000e18);

        _settleRedeem(passthroughVault, 500e18);

        // Final settlement: everything fully claimable for both investors
        assertEq(passthroughVault.maxRedeem(INVESTOR), 1000e18);
        assertEq(passthroughVault.maxRedeem(INVESTOR2), 1000e18);
    }
}

contract PassthroughVaultAsyncDepositTest is IntegrationBaseTest {
    uint128 constant INITIAL_BALANCE = 5_000e6;
    uint256 constant SHARE_SCALE = 1e12;

    address immutable INVESTOR = makeAddr("INVESTOR");

    AsyncVault underlying;
    PassthroughVault passthroughVault;
    uint128 assetId;

    function setUp() public override {
        super.setUp();

        (underlying, assetId) = _deployAsyncDepositVault();
        passthroughVault = _deployPassthroughVault(address(underlying), false);

        _mintUSDC(INVESTOR, INITIAL_BALANCE);

        vm.startPrank(INVESTOR);
        usdc.approve(address(passthroughVault), type(uint256).max);
        ERC20(underlying.share()).approve(address(passthroughVault), type(uint256).max);
        vm.stopPrank();
    }

    function testFullFlow() public {
        uint256 depositAmount = 1000e6;
        uint256 expectedShares = depositAmount * SHARE_SCALE;

        vm.prank(INVESTOR);
        uint256 requestId = passthroughVault.requestDeposit(depositAmount, INVESTOR, INVESTOR);

        assertEq(requestId, 0);
        assertEq(usdc.balanceOf(INVESTOR), INITIAL_BALANCE - depositAmount);
        assertEq(passthroughVault.pendingDepositRequest(0, INVESTOR), depositAmount);
        assertEq(passthroughVault.claimableDepositRequest(0, INVESTOR), 0);

        _settleDeposit(passthroughVault, uint128(depositAmount));

        assertEq(passthroughVault.pendingDepositRequest(0, INVESTOR), 0);
        assertGe(passthroughVault.claimableDepositRequest(0, INVESTOR), depositAmount - 1); // rounding

        vm.prank(INVESTOR);
        uint256 sharesMinted = passthroughVault.deposit(depositAmount, INVESTOR, INVESTOR);

        assertEq(sharesMinted, expectedShares);
        assertEq(ERC20(underlying.share()).balanceOf(INVESTOR), expectedShares);
        assertEq(passthroughVault.claimableDepositRequest(0, INVESTOR), 0);

        vm.prank(INVESTOR);
        passthroughVault.requestRedeem(expectedShares, INVESTOR, INVESTOR);

        assertEq(ERC20(underlying.share()).balanceOf(INVESTOR), 0);
        assertEq(passthroughVault.pendingRedeemRequest(0, INVESTOR), expectedShares);

        _settleRedeem(passthroughVault, uint128(expectedShares));

        vm.prank(INVESTOR);
        uint256 assetsReceived = passthroughVault.redeem(expectedShares, INVESTOR, INVESTOR);

        assertEq(assetsReceived, depositAmount);
        assertEq(usdc.balanceOf(INVESTOR), INITIAL_BALANCE);
    }
}
