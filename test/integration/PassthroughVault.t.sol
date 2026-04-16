// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "protocol/misc/ERC20.sol";

import {BaseTest, VaultKind} from "protocol-test/core/spoke/integration/BaseTest.sol";

import {SyncDepositVault} from "protocol/vaults/SyncDepositVault.sol";
import {PassthroughVault} from "../../src/PassthroughVault.sol";

contract PassthroughVaultTest is BaseTest {
    uint128 constant INITIAL_ASSET_BALANCE = 5_000e6;

    address immutable INVESTOR = makeAddr("INVESTOR");
    address immutable INVESTOR2 = makeAddr("INVESTOR2");

    uint64 poolId;
    uint128 assetId;
    bytes16 scId;
    SyncDepositVault underlying;
    PassthroughVault passthroughVault;

    function setUp() public override {
        super.setUp();
        address vaultAddress;
        (poolId, vaultAddress, assetId) = deployVault(
            VaultKind.SyncDepositAsyncRedeem,
            6,
            address(freelyTransferableHook),
            defaultShareClassId,
            address(erc20),
            erc20TokenId,
            OTHER_CHAIN_ID
        );
        underlying = SyncDepositVault(vaultAddress);
        scId = underlying.scId().raw();
        passthroughVault = new PassthroughVault(address(underlying), address(0), false);
        centrifugeChain.updateMember(poolId, scId, address(passthroughVault), type(uint64).max);

        erc20.mint(INVESTOR, INITIAL_ASSET_BALANCE);
        erc20.mint(INVESTOR2, INITIAL_ASSET_BALANCE);

        vm.startPrank(INVESTOR);
        erc20.approve(address(passthroughVault), type(uint256).max);
        ERC20(underlying.share()).approve(address(passthroughVault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(INVESTOR2);
        erc20.approve(address(passthroughVault), type(uint256).max);
        ERC20(underlying.share()).approve(address(passthroughVault), type(uint256).max);
        vm.stopPrank();
    }

    function testFullFlow() public {
        uint256 depositAmount = 1000e6;

        vm.prank(INVESTOR);
        uint256 sharesMinted = passthroughVault.deposit(depositAmount, INVESTOR);

        assertEq(sharesMinted, depositAmount);
        assertEq(ERC20(underlying.share()).balanceOf(INVESTOR), sharesMinted);

        vm.prank(INVESTOR);
        passthroughVault.requestRedeem(sharesMinted, INVESTOR, INVESTOR);

        assertEq(ERC20(underlying.share()).balanceOf(INVESTOR), 0);
        assertEq(passthroughVault.pendingRedeemRequest(0, INVESTOR), sharesMinted);

        centrifugeChain.isFulfilledRedeemRequest(
            poolId,
            scId,
            bytes32(bytes20(address(passthroughVault))),
            assetId,
            uint128(sharesMinted),
            uint128(sharesMinted),
            0
        );
        assertEq(underlying.maxWithdraw(address(passthroughVault)), sharesMinted);

        uint256 balanceBefore = erc20.balanceOf(INVESTOR);
        vm.prank(INVESTOR);
        uint256 assetsReceived = passthroughVault.redeem(sharesMinted, INVESTOR, INVESTOR);

        assertEq(assetsReceived, sharesMinted);
        assertEq(erc20.balanceOf(INVESTOR) - balanceBefore, sharesMinted);
        assertEq(underlying.maxWithdraw(address(passthroughVault)), 0);
    }

    // Shows the effect of a subsequent requestRedeem by the same investor after a partial settlement.
    // The orphaned and overlapping segments resolve when the settlement catches up, only affecting
    // the user who re-requested. In the end everybody should get the correct amount of assets.
    //
    // Queue after first two requests:
    //           0                    1000                  2000
    //           |--------------------|---------------------|
    //           [      User A        ][      User B        ]
    //
    // Queue after first partial settlement:
    //           0          500        1000                 2000
    //           |XXXXXXXXXX|----------|--------------------|
    //           [ Settled  ][ User A  ][      User B       ]
    //
    // Queue after User A re-requests:
    //           0          500                1000              1500             2000            2500
    //           |XXXXXXXXXX|------------------|-----------------|----------------|---------------|
    //           [ Settled  ][ Orphaned (500) ][              User B              ]
    //                                                           [ Overlap (500)  ]
    //                                                           [          User A (1000)         ]
    function testRequestAgainWithPartialFulfillment() public {
        // INVESTOR deposits 1500e6 so they have 500e6 shares left after the first requestRedeem (1000e6),
        // which they use for the second requestRedeem that triggers the force-claim and re-queuing.
        vm.prank(INVESTOR);
        passthroughVault.deposit(1500e6, INVESTOR);
        vm.prank(INVESTOR2);
        passthroughVault.deposit(1000e6, INVESTOR2);

        vm.prank(INVESTOR);
        passthroughVault.requestRedeem(1000e6, INVESTOR, INVESTOR);
        vm.prank(INVESTOR2);
        passthroughVault.requestRedeem(1000e6, INVESTOR2, INVESTOR2);

        centrifugeChain.isFulfilledRedeemRequest(
            poolId, scId, bytes32(bytes20(address(passthroughVault))), assetId, 500e6, 500e6, 0
        );

        assertEq(passthroughVault.maxRedeem(INVESTOR), 500e6);
        assertEq(passthroughVault.maxRedeem(INVESTOR2), 0);

        vm.prank(INVESTOR);
        passthroughVault.requestRedeem(500e6, INVESTOR, INVESTOR);

        // Investor A's position should be re-queued to [oldCumulative - oldPending, oldCumulative + newlyRequested]
        // = [1500, 2500]
        (uint128 rangeStart, uint128 pending) = passthroughVault.redeemPosition(INVESTOR);
        assertEq(rangeStart, 1500e6);
        assertEq(pending, 1000e6);

        assertEq(passthroughVault.pendingRedeemRequest(0, INVESTOR), 1000e6);
        assertEq(passthroughVault.cumulativeRedeemRequested(), 2500e6);
        assertEq(passthroughVault.maxRedeem(INVESTOR), 0);
        assertEq(passthroughVault.maxRedeem(INVESTOR2), 0);

        centrifugeChain.isFulfilledRedeemRequest(
            poolId, scId, bytes32(bytes20(address(passthroughVault))), assetId, 500e6, 500e6, 0
        );

        // Settling the orphaned segment won't make anything claimable
        assertEq(passthroughVault.maxRedeem(INVESTOR), 0);
        assertEq(passthroughVault.maxRedeem(INVESTOR2), 0);

        centrifugeChain.isFulfilledRedeemRequest(
            poolId, scId, bytes32(bytes20(address(passthroughVault))), assetId, 500e6, 500e6, 0
        );

        // Settling [1000, 1500] makes 500 shares claimable for investor B only
        assertEq(passthroughVault.maxRedeem(INVESTOR), 0);
        assertEq(passthroughVault.maxRedeem(INVESTOR2), 500e6);

        centrifugeChain.isFulfilledRedeemRequest(
            poolId, scId, bytes32(bytes20(address(passthroughVault))), assetId, 500e6, 500e6, 0
        );

        // Settling the overlapping segment makes the remaining 500 claimable for B and 1000 for A
        assertEq(passthroughVault.maxRedeem(INVESTOR), 500e6);
        assertEq(passthroughVault.maxRedeem(INVESTOR2), 1000e6);

        centrifugeChain.isFulfilledRedeemRequest(
            poolId, scId, bytes32(bytes20(address(passthroughVault))), assetId, 500e6, 500e6, 0
        );

        // Final settlement: everything fully claimable for both investors
        assertEq(passthroughVault.maxRedeem(INVESTOR), 1000e6);
        assertEq(passthroughVault.maxRedeem(INVESTOR2), 1000e6);
    }
}
