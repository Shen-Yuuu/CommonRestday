import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { todayEpochDay } from 'domain';
import { Db, SettingsStore } from 'data';
import { CalendarGateway, PairingShareGateway, PlanUseCase, ProfileSettingsService, ScheduleUseCase } from 'feature';
import { Logger } from 'commons';
import { pushPendingRoute, routeFromWantParams } from '../util/NavUtil';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  /**
   * 启动初始化链。Db.init 挂在 promise 上不 await，而 onForeground 紧跟 onCreate，
   * 所以冷启那一次的回前台必然跑在库就绪之前（实测早约 420ms）。回前台的清扫挂到这条链尾，
   * 冷启就等库好了再扫，温启动时链已 settle、行为与改前一致。
   */
  private initChain: Promise<void> = Promise.resolve();

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    // 系统日历（受管写入与导出）要 UIAbility 上下文；拿不到上下文时一律静默降级
    CalendarGateway.init(this.context);
    // 扫码/系统分享同样要上下文；能力不具备时网关按"不可用"回话，页面无需判机型
    PairingShareGateway.init(this.context);
    // 从配对链接或卡片点击拉起本机：只登记意图，跳转与确认都留给页面（进程外参数不可信）
    this.takeDeepLink(want);
    // 初始化本地存储与内置数据（失败不阻塞启动，页面内各自兜底）；
    // 就绪后冷启动重算一次，保证窗口缓存与计划冲突状态有效（US6 / FR-011）。
    // 必须走 onScheduleChanged 而不是裸 recompute：页面首帧的读可能落在这一路重算之前，
    // 只有广播才能让那次陈旧的读被纠正回来，否则冷启动答案要等用户手动刷新（D-24 现象一）。
    this.initChain = Promise.all([
      Db.init(this.context).then(() => ScheduleUseCase.ensureSeeded()),
      SettingsStore.init(this.context)
    ]).then(() => {
      return ScheduleUseCase.onScheduleChanged();
    }).catch((e: Error) => {
      Logger.error('EntryAbility', 'startup init/recompute failed: ' + e.message);
    });
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  /** 已在前台时再次被拉起：同样只登记意图，跳转与确认仍由壳层/页面在用户这边完成。 */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.takeDeepLink(want);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant');
  }

  /**
   * want 的 uri 与 parameters 都来自进程外：
   * uri 交给配对网关按"一次性凭据"口径识别，parameters 里的路由名过白名单后再登记，
   * 两者认不出都无痕丢弃，绝不按外部传来的名字直接跳页。
   */
  private takeDeepLink(want: Want): void {
    const uri: string = want.uri ?? '';
    if (uri !== '') {
      PairingShareGateway.offerIncoming(uri);
    }
    pushPendingRoute(routeFromWantParams(want.parameters));
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
    // 先看一眼钟（K-4③）：后台那段时间"现在"已经走了，游标要挪。
    // 与下面的日切重算分开，是因为它不代表数据变了，只是让看钟的界面重取值。
    ScheduleUseCase.notifyClockTick();
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
    // 补删系统侧残留：取消/改期时删不动的日程与提醒只留在看不见的行里，
    // 用户不会再有入口点"重试"，权限恢复后的这一次就是它唯一的机会（验收报告 B2）。
    // 挂在初始化链之后：库没就绪时这一趟除了warn 什么都不做，冷启那一次就等于白跑（D-31）。
    this.initChain.then(() => PlanUseCase.sweepPendingProjections()).catch((e: Error) => {
      Logger.warn('EntryAbility', 'projection sweep failed: ' + e.message);
    });
    // 心跳（协议 §4.6）：AGC 的闲置回收线在 6 个月外，而本机不建常驻、不起定时器
    // （§3.3/§7 的硬约束），所以"每周一跳"只能靠回前台带起、由节流窗口决定该不该发。
    // 同样排在初始化链之后：Preferences 没就绪时读到的 pairId 是假的。
    this.initChain.then(() => ProfileSettingsService.beatIfDue());
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}