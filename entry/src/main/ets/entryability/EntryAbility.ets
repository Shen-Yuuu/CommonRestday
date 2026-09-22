import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { todayEpochDay } from 'domain';
import { Db, SettingsStore } from 'data';
import { CalendarGateway, PairingShareGateway, ReminderGateway, ScheduleUseCase } from 'feature';
import { Logger } from 'commons';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    // 系统日历确认与本地提醒都要 UIAbility 上下文；两者拿不到上下文时静默降级
    CalendarGateway.init(this.context);
    ReminderGateway.init(this.context);
    // 扫码/系统分享同样要上下文；能力不具备时网关按"不可用"回话，页面无需判机型
    PairingShareGateway.init(this.context);
    // 从配对链接拉起本机（module.json5 的 crdpair 方案）：只收下请求，确认由页面完成
    this.takePairLink(want);
    // 初始化本地存储与内置数据（失败不阻塞启动，页面内各自兜底）；
    // 就绪后冷启动重算一次，保证窗口缓存与计划冲突状态有效（US6 / FR-011）
    Promise.all([
      Db.init(this.context).then(() => ScheduleUseCase.ensureSeeded()),
      SettingsStore.init(this.context)
    ]).then(() => {
      return ScheduleUseCase.recompute(todayEpochDay());
    }).catch((e: Error) => {
      Logger.error('EntryAbility', 'startup init/recompute failed: ' + e.message);
    });
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  /** 已在前台时再次被链接拉起：同样只登记请求，确认仍在页面里由用户点。 */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.takePairLink(want);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant');
  }

  /** want.uri 来自进程外：交给网关按"一次性凭据"口径识别，认不出的内容无痕丢弃。 */
  private takePairLink(want: Want): void {
    const uri: string = want.uri ?? '';
    if (uri !== '') {
      PairingShareGateway.offerIncoming(uri);
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // 日切重算（PRD L8/L12）：跨天回到前台时窗口缓存已过期，重算并广播刷新
    try {
      if (SettingsStore.getLastRecomputeDay() !== todayEpochDay()) {
        ScheduleUseCase.onScheduleChanged().catch((e: Error) => {
          Logger.error('EntryAbility', 'day-rollover recompute failed: ' + e.message);
        });
      }
    } catch (e) {
      // Settings 尚未初始化：onCreate 的初始化完成后本就会重算一次
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}