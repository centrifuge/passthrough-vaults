// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CentrifugeIntegrationTestWithUtils} from "protocol-test/integration/Integration.t.sol";
import {IntegrationConstants} from "protocol-test/integration/utils/IntegrationConstants.sol";

import {D18, d18} from "protocol/misc/types/D18.sol";
import {MAX_MESSAGE_COST as GAS} from "protocol/core/messaging/interfaces/IGasService.sol";
import {CastLib} from "protocol/misc/libraries/CastLib.sol";
import {AccountId} from "protocol/core/types/AccountId.sol";
import {VaultUpdateKind} from "protocol/core/messaging/libraries/MessageLib.sol";
import {IHubRequestManager} from "protocol/core/hub/interfaces/IHubRequestManager.sol";
import {ISyncManager} from "protocol/vaults/interfaces/IVaultManagers.sol";
import {UpdateRestrictionMessageLib} from "protocol/hooks/libraries/UpdateRestrictionMessageLib.sol";
import {SyncDepositVault} from "protocol/vaults/SyncDepositVault.sol";
import {AsyncVault} from "protocol/vaults/AsyncVault.sol";
import {BatchRequestManager} from "protocol/vaults/BatchRequestManager.sol";

import {PassthroughVault} from "../../src/PassthroughVault.sol";

contract IntegrationBaseTest is CentrifugeIntegrationTestWithUtils {
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;

    uint128 constant HOOK_GAS = IntegrationConstants.HOOK_GAS;
    uint128 constant EXTRA_GAS = IntegrationConstants.EXTRA_GAS;

    AccountId constant ASSET_ACCOUNT = IntegrationConstants.ASSET_ACCOUNT;
    AccountId constant EQUITY_ACCOUNT = IntegrationConstants.EQUITY_ACCOUNT;

    function setUp() public virtual override {
        super.setUp();
        vm.deal(FM, 10 ether);
    }

    function _deployCommonPoolSetup() internal returns (uint128 assetId) {
        _createPool();

        vm.startPrank(FM);

        hub.createAccount(POOL_A, ASSET_ACCOUNT, true);
        hub.createAccount(POOL_A, EQUITY_ACCOUNT, false);

        hub.notifyPool{value: GAS}(POOL_A, LOCAL_CENTRIFUGE_ID, FM);
        hub.notifyShareClass{value: GAS}(
            POOL_A, SC_1, LOCAL_CENTRIFUGE_ID, address(freelyTransferableHook).toBytes32(), FM
        );
        vm.stopPrank();

        _registerUSDC();
        assetId = usdcId.raw();

        vm.startPrank(FM);

        hub.initializeHolding(
            POOL_A, SC_1, usdcId, identityValuation, ASSET_ACCOUNT, EQUITY_ACCOUNT, EQUITY_ACCOUNT, EQUITY_ACCOUNT
        );
        hub.setRequestManager{value: GAS}(
            POOL_A,
            LOCAL_CENTRIFUGE_ID,
            IHubRequestManager(address(batchRequestManager)),
            address(asyncRequestManager).toBytes32(),
            FM
        );
        hub.updateBalanceSheetManager{value: GAS}(
            POOL_A, LOCAL_CENTRIFUGE_ID, address(asyncRequestManager).toBytes32(), true, FM
        );

        hub.updateSharePrice(POOL_A, SC_1, d18(1e18), uint64(block.timestamp));
        hub.notifySharePrice{value: GAS}(POOL_A, SC_1, LOCAL_CENTRIFUGE_ID, FM);
        hub.notifyAssetPrice{value: GAS}(POOL_A, SC_1, usdcId, FM);

        vm.stopPrank();
    }

    function _deploySyncDepositVault() internal returns (SyncDepositVault vault, uint128 assetId) {
        assetId = _deployCommonPoolSetup();

        vm.startPrank(FM);

        hub.updateBalanceSheetManager{value: GAS}(
            POOL_A, LOCAL_CENTRIFUGE_ID, address(syncManager).toBytes32(), true, FM
        );

        hub.updateVault{value: GAS}(
            POOL_A,
            SC_1,
            usdcId,
            address(syncDepositVaultFactory).toBytes32(),
            VaultUpdateKind.DeployAndLink,
            EXTRA_GAS,
            FM
        );

        hub.updateContract{value: GAS}(
            POOL_A,
            SC_1,
            LOCAL_CENTRIFUGE_ID,
            address(syncManager).toBytes32(),
            _updateContractSyncDepositMaxReserveMsg(usdcId, type(uint128).max),
            0,
            FM
        );
        vm.stopPrank();

        vault = SyncDepositVault(address(vaultRegistry.vault(POOL_A, SC_1, usdcId, asyncRequestManager)));
    }

    function _deployAsyncDepositVault() internal returns (AsyncVault vault, uint128 assetId) {
        assetId = _deployCommonPoolSetup();

        vm.startPrank(FM);

        hub.updateVault{value: GAS}(
            POOL_A,
            SC_1,
            usdcId,
            address(asyncVaultFactory).toBytes32(),
            VaultUpdateKind.DeployAndLink,
            EXTRA_GAS,
            FM
        );
        vm.stopPrank();

        vault = AsyncVault(address(vaultRegistry.vault(POOL_A, SC_1, usdcId, asyncRequestManager)));
    }

    function _deployPassthroughVault(address underlying, bool allowPermissionlessClaiming)
        internal
        returns (PassthroughVault pv)
    {
        pv = new PassthroughVault(underlying, address(0), allowPermissionlessClaiming);

        vm.prank(FM);
        hub.updateRestriction{value: GAS}(
            POOL_A,
            SC_1,
            LOCAL_CENTRIFUGE_ID,
            UpdateRestrictionMessageLib.UpdateRestrictionMember({
                    user: address(pv).toBytes32(), validUntil: type(uint64).max
                }).serialize(),
            EXTRA_GAS,
            FM
        );
    }

    function _settleDeposit(PassthroughVault pv, uint128 assets) internal {
        vm.startPrank(FM);

        uint32 depositEpochId = batchRequestManager.nowDepositEpoch(POOL_A, SC_1, usdcId);
        D18 pricePoolPerAsset_ = hub.pricePoolPerAsset(POOL_A, SC_1, usdcId);
        batchRequestManager.approveDeposits{value: GAS}(POOL_A, SC_1, usdcId, depositEpochId, assets, pricePoolPerAsset_, FM);

        uint32 issueEpochId = batchRequestManager.nowIssueEpoch(POOL_A, SC_1, usdcId);
        (D18 sharePrice,) = shareClassManager.pricePoolPerShare(POOL_A, SC_1);
        batchRequestManager.issueShares{value: GAS}(POOL_A, SC_1, usdcId, issueEpochId, sharePrice, HOOK_GAS, FM);

        bytes32 investor = address(pv).toBytes32();
        batchRequestManager.notifyDeposit{value: GAS}(
            POOL_A, SC_1, usdcId, investor, batchRequestManager.maxDepositClaims(POOL_A, SC_1, investor, usdcId), FM
        );

        vm.stopPrank();
    }

    function _settleRedeem(PassthroughVault pv, uint128 shares) internal {
        vm.startPrank(FM);

        uint32 redeemEpochId = batchRequestManager.nowRedeemEpoch(POOL_A, SC_1, usdcId);
        D18 pricePoolPerAsset_ = hub.pricePoolPerAsset(POOL_A, SC_1, usdcId);
        batchRequestManager.approveRedeems(POOL_A, SC_1, usdcId, redeemEpochId, shares, pricePoolPerAsset_);

        uint32 revokeEpochId = batchRequestManager.nowRevokeEpoch(POOL_A, SC_1, usdcId);
        (D18 sharePrice,) = shareClassManager.pricePoolPerShare(POOL_A, SC_1);
        batchRequestManager.revokeShares{value: GAS}(POOL_A, SC_1, usdcId, revokeEpochId, sharePrice, HOOK_GAS, FM);

        bytes32 investor = address(pv).toBytes32();
        batchRequestManager.notifyRedeem{value: GAS}(
            POOL_A, SC_1, usdcId, investor, batchRequestManager.maxRedeemClaims(POOL_A, SC_1, investor, usdcId), FM
        );

        vm.stopPrank();
    }
}
