import { describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { preferences } from '@kit.ArkData';
import { PAIRED, SettingsStore } from 'data';

/** 真实 Preferences 验证。修改五个设置键，最后恢复；仍只在可丢弃测试实例运行。 */
export default function partnerNamePersistenceTest(): void {
  describe('PartnerNamePersistenceTest', () => {
    it('nickname_is_local_pair_bound_and_cancel_is_remembered', 0, async () => {
      try {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      await SettingsStore.init(ctx);
      const prefs = await preferences.getPreferences(ctx, 'crd_settings');
      const oldPair = SettingsStore.getPairId();
      const oldState = SettingsStore.getPairState();
      const oldPeer = SettingsStore.getPartnerUid();
      const oldName = prefs.getSync('cloud_partner_name', '') as string;
      const oldNamePair = prefs.getSync('cloud_partner_name_pair', '') as string;
      try {
        await SettingsStore.savePairId('name-persistence-fixture');
        await SettingsStore.setPairState(PAIRED, 'name-fixture-peer');
        await SettingsStore.saveCloudPartnerName('name-persistence-fixture', '  小鹿  ');
        expect(SettingsStore.getPartnerDisplayName()).assertEqual('小鹿');
        expect(prefs.getSync('cloud_partner_name', '')).assertEqual('小鹿');
        expect(prefs.getSync('cloud_partner_name_pair', '')).assertEqual('name-persistence-fixture');
        await SettingsStore.saveCloudPartnerName('name-persistence-fixture', '');
        expect(SettingsStore.getPartnerDisplayName()).assertEqual('TA');
        expect(SettingsStore.isCloudPartnerNamePrompted()).assertTrue();
        await SettingsStore.savePairId('name-next-fixture');
        expect(SettingsStore.getPartnerDisplayName()).assertEqual('TA');
        expect(SettingsStore.isCloudPartnerNamePrompted()).assertFalse();
      } finally {
        await SettingsStore.savePairId(oldPair);
        await SettingsStore.setPairState(oldState, oldPeer);
        await prefs.put('cloud_partner_name', oldName);
        await prefs.put('cloud_partner_name_pair', oldNamePair);
        await prefs.flush();
      }
      } catch (e) {
        throw new Error('称呼持久化验收失败：' + (e as Error).message);
      }
    });
  });
}
