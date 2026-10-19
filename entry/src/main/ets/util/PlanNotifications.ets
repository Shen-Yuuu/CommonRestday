import { common } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { pushService } from '@kit.PushKit';
import { SettingsStore } from 'data';
import { FeatureFlags, SharedPlanViewService, createSecureSharedPlanGateway, secureSharedPlans,
  securePairingSetup, unifiedPairing } from 'feature';

export const PLAN_PUSH_ACTION: string = 'com.common.fortwo.action.PLAN';
/** No startup prompt, no Push token without explicit per-pair consent, no background polling. */
export class PlanNotifications {
  private static busy: boolean = false;
  private static foregroundBusy: boolean = false;
  private static registeredPair: string = '';
  static async enable(context: common.UIAbilityContext): Promise<string> {
    if (!FeatureFlags.sharedPlan || !FeatureFlags.cloudPairing) return 'FEATURE_DISABLED';
    if (PlanNotifications.busy) return 'BUSY';
    PlanNotifications.busy = true;
    try {
      const local = await SharedPlanViewService.read(); if (!local.linked) return 'SECURE_SESSION_REQUIRED';
      if (!await notificationManager.isNotificationEnabled()) await notificationManager.requestEnableNotification(context);
      if (!await notificationManager.isNotificationEnabled()) return 'NOTIFICATION_DENIED';
      const token = await pushService.getToken();
      const current = await SharedPlanViewService.read();
      if (!current.linked || current.pairId !== local.pairId) return 'SESSION_CHANGED';
      const code = await createSecureSharedPlanGateway().registerPush(true, token);
      if (code !== 'OK') return code;
      const after = await SharedPlanViewService.read();
      if (!after.linked || after.pairId !== local.pairId) return 'SESSION_CHANGED';
      await SettingsStore.setPlanNotificationPair(local.pairId);
      PlanNotifications.registeredPair = local.pairId;
      return 'OK';
    } catch { return 'NOTIFICATION_UNAVAILABLE'; }
    finally { PlanNotifications.busy = false; }
  }
  static async disable(): Promise<string> {
    if (PlanNotifications.busy) return 'BUSY';
    PlanNotifications.busy = true;
    try {
      const code = await createSecureSharedPlanGateway().registerPush(false, '');
      if (code !== 'OK') return code;
      await SettingsStore.setPlanNotificationPair(''); PlanNotifications.registeredPair = '';
      return 'OK';
    } catch { return 'NOTIFICATION_UNAVAILABLE'; }
    finally { PlanNotifications.busy = false; }
  }
  /** Read authoritative state once on foreground; never resend an ambiguous user decision automatically. */
  static async onForeground(): Promise<void> {
    if (PlanNotifications.foregroundBusy || !FeatureFlags.sharedPlan || !FeatureFlags.cloudPairing) return;
    PlanNotifications.foregroundBusy = true;
    try {
      await unifiedPairing().advance(false);
      const local = await SharedPlanViewService.read(); if (!local.linked) return;
      const code = await secureSharedPlans().refresh();
      if (code === 'SESSION_REVOKED' || code === 'CLEANUP_PENDING' || code === 'SECURE_SESSION_REQUIRED') {
        await securePairingSetup().refreshActive(); return;
      }
      if (code !== 'OK' && code !== 'SAVED_RECOMPUTE_PENDING') return;
      if (SettingsStore.getPlanNotificationPair() !== local.pairId || PlanNotifications.registeredPair === local.pairId) return;
      if (!await notificationManager.isNotificationEnabled()) {
        await PlanNotifications.disable(); return;
      }
      // A prior consent allows token renewal after process restart, not after a new connection.
      const token = await pushService.getToken();
      if (await createSecureSharedPlanGateway().registerPush(true, token) === 'OK') {
        PlanNotifications.registeredPair = local.pairId;
      }
    } catch { /* Existing plan state stays usable; foreground failure never makes the whole page blink. */ }
    finally { PlanNotifications.foregroundBusy = false; }
  }
}
