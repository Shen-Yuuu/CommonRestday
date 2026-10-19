import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { todayEpochDay } from 'domain';
import { Db, SettingsStore, PAIRED } from 'data';
import { CalendarGateway, FeatureFlags, PlanUseCase, ProfileSettingsService, ScheduleUseCase, SecureLifecycle, secureCloudCleanup,
  securePairingSetup } from 'feature';
import { Logger } from 'commons';
import { AnonymousIdentity } from 'cloud';
import { pushPendingRoute, routeFromWantParams, navToCoTime } from '../util/NavUtil';
import { PLAN_PUSH_ACTION, PlanNotifications } from '../util/PlanNotifications';
import { NavRoutes } from '../navigation/NavRoutes';
import { publishColorMode } from '../theme/ThemeModeSignal';
import { publishForeground } from '../util/ForegroundSignal';
import { BottomSafeArea } from '../util/BottomSafeArea';

export default class EntryAbility extends UIAbility {
  /**
   * 只表示 DB、种子与偏好就绪，不包含网络等待或重算。
   * 冷启先用缓存计算；共同计划与快照同步在存储就绪后独立开始，互不阻塞。
   * 保留存储失败的拒绝态，防止依赖链使用未初始化的偏好或数据库。
   */
  private initChain: Promise<void> = Promise.resolve();
  private firstForeground: boolean = true;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    publishForeground(false);
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      Logger.error('EntryAbility', 'set colorMode failed: ' + JSON.stringify(err));
    }
    publishColorMode(this.context.config.colorMode);
    // 系统日历（受管写入与导出）要 UIAbility 上下文；拿不到上下文时一律静默降级
    CalendarGateway.init(this.context);
    AnonymousIdentity.attach(this.context);
    SecureLifecycle.installCleanup(() => secureCloudCleanup().clearLocalKeys());
    SecureLifecycle.installDisconnect(async (): Promise<string> => {
      const local = await securePairingSetup().local();
      if (local.phase === 'EMPTY' || local.phase === 'REVOKED') return 'OK';
      return (await securePairingSetup().disconnect()).code;
    });
    // 卡片点击拉起本机：路由名仍过白名单。
    this.takeRouteIntent(want);
    // 初始化本地存储与内置数据（失败不阻塞启动，页面内各自兜底）；
    // 就绪后先用本机与伴侣缓存冷启动重算，云端更新由首次 onForeground 独立拉取。
    // 必须走 onScheduleChanged 而不是裸 recompute：页面首帧的读可能落在这一路重算之前，
    // 只有广播才能让那次陈旧的读被纠正回来，否则冷启动答案要等用户手动刷新（D-24 现象一）。
    this.initChain = Promise.all([
      Db.init(this.context).then(() => ScheduleUseCase.ensureSeeded()),
      SettingsStore.init(this.context)
    ]).then((): void => {});
    this.initChain.then(() => ScheduleUseCase.onScheduleChanged(true)).catch((e: Error) => {
      Logger.error('EntryAbility', 'startup init/recompute failed: ' + e.message);
    });
  }

  onDestroy(): void {
    publishForeground(false);
    BottomSafeArea.detach();
  }

  /** ChipV2 的 ColorMetrics 是建组件时的颜色快照；系统换档后通知现有页面重取资源。 */
  onConfigurationUpdate(newConfig: Configuration): void {
    publishColorMode(newConfig.colorMode);
  }

  /** 已在前台时再次被拉起：仍只登记白名单路由意图。 */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.takeRouteIntent(want);
  }

  /**
   * want 的 parameters 来自进程外：路由名过白名单后再登记。
   */
  private takeRouteIntent(want: Want): void {
    if (want.action === PLAN_PUSH_ACTION) {
      navToCoTime('plans'); pushPendingRoute(NavRoutes.COMMON_TIME); return;
    }
    pushPendingRoute(routeFromWantParams(want.parameters));
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    try { BottomSafeArea.attach(windowStage.getMainWindowSync()); } catch { /* Footer has a bounded fallback. */ }

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        Logger.error('EntryAbility', 'loadContent failed: ' + JSON.stringify(err));
      }
    });
  }

  onWindowStageDestroy(): void {
    BottomSafeArea.detach();
  }

  onForeground(): void {
    publishForeground(true);
    BottomSafeArea.refresh();
    // 先看一眼钟（K-4③）：后台那段时间"现在"已经走了，游标要挪。
    // 与下面的日切重算分开，是因为它不代表数据变了，只是让看钟的界面重取值。
    ScheduleUseCase.notifyClockTick();
    const coldStart = this.firstForeground;
    this.firstForeground = false;
    this.initChain.then(async (): Promise<void> => {
      if (coldStart) {
        // 与共同计划同步并行；复用下拉刷新的单次飞行，不重复请求也不重新推送快照。
        if (FeatureFlags.cloudPairing && SettingsStore.getPairState() === PAIRED)
          await ScheduleUseCase.pullToRefresh();
        return;
      }
      // 日切检查必须等偏好就绪；首次冷启已有缓存重算，不再多排一次日切重算。
      if (SettingsStore.getLastRecomputeDay() !== todayEpochDay()) await ScheduleUseCase.onScheduleChanged();
    }).catch((e: Error) => {
      Logger.error('EntryAbility', 'foreground snapshot/recompute failed: ' + e.message);
    });
    // 补删系统侧残留：取消/改期时删不动的日程与提醒只留在看不见的行里，
    // 用户不会再有入口点"重试"，权限恢复后的这一次就是它唯一的机会（验收报告 B2）。
    // 挂在初始化链之后：库没就绪时这一趟除了warn 什么都不做，冷启那一次就等于白跑（D-31）。
    this.initChain.then(() => PlanUseCase.sweepPendingProjections()).catch((e: Error) => {
      Logger.warn('EntryAbility', 'projection sweep failed: ' + e.message);
    });
    // 心跳（协议 §4.6）：AGC 的闲置回收线在 6 个月外，而本机不建常驻、不起定时器
    // （§3.3/§7 的硬约束），所以"每周一跳"只能靠回前台带起、由节流窗口决定该不该发。
    // 同样排在初始化链之后：Preferences 没就绪时读到的 pairId 是假的。
    this.initChain.then(() => ProfileSettingsService.beatIfDue()).catch(() => {
      Logger.warn('EntryAbility', 'cloud heartbeat deferred');
    });
    // 补删「清空全部数据」那一次没删掉的云上快照（协议 §4.5 批次 U·U5）：配对标记与 pairId
    // 都随那次清空推平了，偏好里剩的两个字段就是它最后的凭据，而用户不会再有入口点"重试"。
    this.initChain.then(() => ProfileSettingsService.retryPendingCloudUnpair()).catch(() => {
      Logger.warn('EntryAbility', 'pending cloud unpair deferred');
    });
    this.initChain.then(() => secureCloudCleanup().clearLocalKeys().catch(() => {
      Logger.warn('EntryAbility', 'secure local key cleanup deferred');
    })).then(() => secureCloudCleanup().retry()).catch(() => {
      Logger.warn('EntryAbility', 'secure cloud cleanup deferred');
    });
    this.initChain.then(() => PlanNotifications.onForeground()).catch(() => {
      Logger.warn('EntryAbility', 'shared plan foreground refresh deferred');
    });
  }

  onBackground(): void {
    publishForeground(false);
  }
}
