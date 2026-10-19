import { hhmmToMin, HORIZON_DEFAULT_DAYS, minToHHmm, OWNER_ME } from 'domain';
import { PAIRED, PAIR_NONE, PAIR_PENDING, PAIR_WAITING, SettingsStore } from 'data';
import {
  canManuallyRetry, FeatureFlags, HORIZON_MAX, HORIZON_MIN, InviteResult, isCrossMidnight, MyRhythm,
  unifiedPairing, UnifiedPairingResult,
  secureCloudCleanup, secureCleanupSummary,
  PairCodeClipboard, PartnerInput, ProfileSettingsService,
  ScheduleUseCase, SettingsResult, SHARE_LEVEL_UNKNOWN, SYNC_STATE_BLOCKED, SYNC_STATE_OK, SyncState,
  syncStateNoteOf, syncStateTitleOf, syncTroubleOf
} from 'feature';
import { PrivacyPolicySheet } from '../component/PrivacyPolicySheet';
import { DesignTokens } from '../theme/DesignTokens';
import { NavRoutes } from '../navigation/NavRoutes';
import { ownerParam } from '../model/RouteParams';
import { EditorialCard } from '../component/EditorialCard';
import { NoticeBar, NoticeTone } from '../component/NoticeBar';
import { SyncFeedbackButton } from '../component/SyncFeedbackButton';
import { UnifiedPairingStatus } from '../component/UnifiedPairingStatus';
import { Breakpoint, Breakpoints } from '../responsive/Breakpoints';
import { ResponsiveContainer } from '../responsive/ResponsiveContainer';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';
import { appToast } from '../util/AppToast';
import { askConfirm } from '../util/AppConfirm';
import { syncOnPull } from '../util/PullRefresh';
import { LatestLanding } from '../util/LatestLanding';
import { FadingScrollViewport, ScrollHeaderState, StickyPageHeader } from '../component/FadingHeader';

/** 最短共同时段的常用档：碎片小于 1 小时几乎安排不了事，大于 4 小时又太难得。 */
const MIN_SLOT_STEPS: number[] = [60, 120, 240];

/** 卡内小标题的入参：`action` 由父页状态算出来（编辑态要收起"编辑"这颗），必须跟着换（D-46 第二形）。 */
interface CardHeadArg {
  title: string;
  action: string;
  onAction: () => void;
}

/** 我的页只展示摘要，完整设置在详情面板中。 */
@Component
export struct MeView {
  @Prop @Watch('onActiveChanged') active: boolean = true;
  private mounted: boolean = false;
  private landing: LatestLanding = new LatestLanding();
  /** 打开路由（班表页并指定录哪一侧），由 AppNavigator 注入：路由种类只有壳层知道。 */
  onOpenRoute: (name: string, params?: Object) => void = (name: string, params?: Object) => {
  };
  @State private shareLevel: number = SHARE_LEVEL_UNKNOWN;
  @State private pairState: string = PAIR_NONE;
  /** 云同步三态（协议 §3.4 末行）：默认「已同步」= 提示条不出。 */
  @State private syncState: SyncState = { outcome: SYNC_STATE_OK, day: 0, code: '' };
  /** 云上还剩几份加密快照是这台手机**删不掉**的（云端已给终局判定，批次 AO·AO3）。 */
  @State private undeletableCloud: number = 0;
  @State private secureCleanupNote: string = '';
  @State private secureCleanupBusy: boolean = false;
  private cleanupRead: number = 0;
  // 伴侣档案
  @State private partnerExists: boolean = false;
  @State private partnerEditing: boolean = false;
  @State private pNick: string = '';
  @State private pWake: string = '07:00';
  @State private pBed: string = '22:30';
  @State private pWind: string = '20';
  // 云端配对
  @State private pairingBusy: boolean = false;
  @State private syncRetryBusy: boolean = false;
  @State private syncFeedback: string = '';
  @State private syncOrigin: string = '';
  private feedbackPairId: string = '';
  @State private showJoinInput: boolean = false;
  @State private myCode: string = '';
  @State private joinCode: string = '';
  /** 确认凭据只在邀请方本机密封保存；页面只需要知道这一侧能否确认。 */
  @State private isInviter: boolean = false;
  // 我的作息参数
  @State private myEditing: boolean = false;
  @State private mySaving: boolean = false;
  @State private myWake: string = '07:00';
  @State private myBed: string = '22:30';
  @State private myWind: string = '20';
  @State private myHorizon: string = '' + HORIZON_DEFAULT_DAYS;
  @State private myMinSlot: number = 120;
  private rhythmTimeRequest: number = 0;
  @State private clearing: boolean = false;
  /** 下拉刷新的转圈：重算（含向云上要一次对方快照）落地后才收。 */
  @State private refreshing: boolean = false;
  /** 离线隐私全文与托管版链接。 */
  @State private policyOpen: boolean = false;
  @State private detailsOpen: boolean = false;
  @State private unifiedPhase: string = 'CONNECTING';
  @State private detailKind: string = 'partner';
  @State private cloudName: string = 'TA';
  @State private nameDraft: string = '';
  @State private nameSaving: boolean = false;
  @State private nameError: string = '';
  private namePairId: string = '';
  /** 本页容器宽度档位：expanded 把卡片区并成两列，其余档位与改造前一致。 */
  @State private bp: Breakpoint = Breakpoint.COMPACT;
  private pageScroller: Scroller = new Scroller();
  @State private headerVisual: ScrollHeaderState = new ScrollHeaderState();
  // 装饰器实参必须是字面量，取值与 SENIOR_MODE_KEY 保持一致。
  @StorageProp('crd_senior_mode') senior: boolean = false;
  // 保存动作 → 重算广播：伴侣侧数据或参数变了，摘要文案要跟着走
  @StorageProp('recomputeCount') @Watch('onRecomputeChanged') recomputeCount: number = 0;
  aboutToAppear(): void {
    this.mounted = true;
    this.reload();
  }
  aboutToDisappear(): void { this.mounted = false; this.cleanupRead++; this.landing.invalidate(); }
  onActiveChanged(): void {
    if (!this.active) { this.cleanupRead++; this.landing.invalidate(); return; }
    if (this.mounted) this.reload();
  }

  onRecomputeChanged(): void {
    this.reload();
  }

  /** 下拉刷新：重算一遍视界（已配对时顺带拉对方最新快照），本页摘要跟着重读广播走。 */
  private async onRefresh(): Promise<void> {
    await syncOnPull();
    this.refreshing = false;
  }

  // ---------- 六位短码 / 邀请方本机确认 ----------

  copyPairCode(): void {
    if (this.myCode === '') {
      appToast('还没有配对码，先点「生成配对码」');
      return;
    }
    PairCodeClipboard.copy(this.myCode).then((message: string) => {
      appToast(message);
    });
  }

  /** 输码只提交申请；邀请方看到云端待确认状态后在本机点头。 */
  confirmPair(): void {
    askConfirm(this.getUIContext(), {
      title: '确认配对请求',
      message: 'TA 已输入你分享的 6 位配对码。确认后会连接班表同步与共同计划；每个计划仍需对方同意，通知另行开启。',
      cancelText: '忽略',
      confirmText: '确认配对',
      onConfirm: () => this.acceptPendingJoin()
    });
  }

  acceptPendingJoin(): void {
    if (this.pairingBusy) {
      return;
    }
    this.pairingBusy = true;
    ProfileSettingsService.confirmPendingJoin().then((res: SettingsResult) => {
      this.pairingBusy = false;
      this.pairState = ProfileSettingsService.getPairState();
      this.isInviter = ProfileSettingsService.hasLocalInviteProof();
      appToast(res.message);
      this.reload();
    });
  }

  reload(): void {
    if (!this.active || !this.mounted) return;
    this.shareLevel = ProfileSettingsService.getShareLevel();
    this.pairState = ProfileSettingsService.getPairState();
    this.syncState = ProfileSettingsService.getCloudSyncState();
    // 配对变化或故障恢复后，不保留上一轮的重试反馈。
    if (!this.syncRetryBusy && (this.feedbackPairId !== SettingsStore.getPairId()
      || (this.syncTrouble() && this.syncFeedback !== '' && this.syncFeedback !== '同步未成功')
      || (!this.syncTrouble() && this.syncFeedback === '同步未成功'))) {
      this.syncOrigin = '';
      this.syncFeedback = '';
    }
    this.undeletableCloud = ProfileSettingsService.undeletableCloudSnapshots();
    const cleanupRead = ++this.cleanupRead;
    const token = this.landing.begin();
    unifiedPairing().local().then((state: UnifiedPairingResult) => {
      if (this.landing.isCurrent(token)) this.unifiedPhase = state.phase;
    }).catch(() => {
      if (this.landing.isCurrent(token)) this.unifiedPhase = 'FAILED';
    });
    secureCleanupSummary().then((note: string) => {
      if (cleanupRead === this.cleanupRead && this.landing.isCurrent(token)) this.secureCleanupNote = note;
    }).catch(() => {
      if (cleanupRead === this.cleanupRead && this.landing.isCurrent(token)) this.secureCleanupNote = '暂时无法读取安全连接的云端清理状态';
    });
    this.isInviter = ProfileSettingsService.hasLocalInviteProof();
    this.reloadPartner();
    this.reloadMyParams();
    this.cloudName = SettingsStore.getCloudPartnerName() || 'TA';
    if (FeatureFlags.cloudPairing && this.pairState === PAIRED && this.unifiedPhase === 'READY' && !SettingsStore.isCloudPartnerNamePrompted()
      && this.detailKind !== 'name') {
      this.editCloudName();
    }
  }

  private openDetails(kind: string): void {
    if (kind === 'rhythm') {
      this.startEditMyParams();
    }
    this.detailKind = kind;
    this.detailsOpen = true;
  }

  private partnerSheetHeight(): string {
    if (this.detailKind === 'name') {
      return '44%';
    }
    return this.partnerEditing || this.showJoinInput || this.pairState === PAIR_WAITING
      || this.pairState === PAIR_PENDING ? '85%' : '70%';
  }

  private editCloudName(): void {
    this.namePairId = SettingsStore.getPairId();
    this.nameDraft = SettingsStore.getCloudPartnerName();
    this.nameError = '';
    this.openDetails('name');
  }

  private async finishCloudName(cancel: boolean): Promise<void> {
    if (this.nameSaving) {
      return;
    }
    this.nameSaving = true;
    const name = cancel ? SettingsStore.getCloudPartnerName() : this.nameDraft.trim();
    try {
      await SettingsStore.saveCloudPartnerName(this.namePairId, name);
      this.cloudName = name || 'TA';
      this.detailKind = 'partner';
      this.detailsOpen = false;
      const tick = Number(AppStorage.get<number>('recomputeCount') || 0);
      AppStorage.setOrCreate('recomputeCount', tick + 1);
    } catch (e) {
      this.nameError = (e as Error).message;
      appToast(this.nameError);
      if (SettingsStore.getPairId() === this.namePairId && this.pairState === PAIRED) {
        this.detailsOpen = true;
      }
    } finally {
      this.nameSaving = false;
    }
  }

  private closeDetails(): void {
    if (this.detailKind === 'name') {
      if (SettingsStore.getPairId() !== this.namePairId || this.pairState !== PAIRED) {
        this.detailKind = 'partner';
        this.detailsOpen = false;
        return;
      }
      this.finishCloudName(true);
      return;
    }
    this.detailsOpen = false;
    this.partnerEditing = false;
    this.myEditing = false;
    this.reloadPartner();
    this.reloadMyParams();
  }

  reloadPartner(): void {
    const profile: PartnerInput | null = ProfileSettingsService.loadPartner();
    this.partnerExists = profile != null;
    if (profile != null && !this.partnerEditing) {
      this.pNick = profile.nick;
      this.pWake = profile.wakeText;
      this.pBed = profile.bedText;
      this.pWind = profile.windText;
    }
  }

  // ---------- 伴侣档案：添加 / 编辑 / 删除 ----------

  startAddPartner(): void {
    this.pNick = '';
    this.pWake = '07:00';
    this.pBed = '22:30';
    this.pWind = '20';
    this.partnerEditing = true;
  }

  startEditPartner(): void {
    this.reloadPartner();
    this.partnerEditing = true;
  }

  cancelPartnerEdit(): void {
    this.partnerEditing = false;
    this.reloadPartner();
  }

  savePartner(): void {
    const input: PartnerInput = {
      nick: this.pNick, wakeText: this.pWake, bedText: this.pBed, windText: this.pWind
    };
    ProfileSettingsService.savePartner(input).then((res: SettingsResult) => {
      appToast(res.message);
      if (res.ok) {
        this.partnerEditing = false;
        this.reloadPartner();
      }
    });
  }

  confirmDeletePartner(): void {
    askConfirm(this.getUIContext(), {
      title: '删除伴侣档案',
      message: 'TA 的班表和课表会一起删掉，之后回到单人模式。',
      confirmText: '删除',
      danger: true,
      onConfirm: () => this.doDeletePartner()
    });
  }

  doDeletePartner(): void {
    ProfileSettingsService.deletePartner().then((res: SettingsResult) => {
      appToast(res.message);
      if (res.ok) {
        this.partnerEditing = false;
        this.reloadPartner();
      }
    });
  }

  /** 跨零点作息要说成人话，否则"就寝 01:00"看着像漏填。 */
  private bedNote(wakeStr: string, bedStr: string): string {
    return isCrossMidnight(wakeStr, bedStr) ? '就寝已过零点，算作第二天' : '';
  }

  // ---------- 云端配对（US9 / FR-015：AGC 未就绪时全程降级提示，不影响本机代录） ----------

  pairStateText(): string {
    if (this.pairState === PAIRED) {
      return FeatureFlags.cloudPairing ? (this.unifiedPhase === 'READY' ? '已配对' : '连接待完成') : '已标记配对';
    }
    if (this.pairState === PAIR_WAITING) {
      return '等待 TA 输码';
    }
    if (this.pairState === PAIR_PENDING) {
      return this.isInviter ? '待你确认' : '等待 TA 确认';
    }
    return '未配对';
  }

  /** 「已配对」不许说成"正在同步"：云端开关关着时它只是本机状态（验收清单 §9.5 的偏离口径）。 */
  pairedNote(): string {
    if (FeatureFlags.cloudPairing) {
      return this.unifiedPhase === 'READY' ? '班表加密同步，共同计划需双方确认。'
        : '正在完成共同计划连接。';
    }
    return '云同步暂不可用，可先使用本机代录。';
  }

  /** 云同步现在是不是坏消息（待重试 / 已停止）。「已同步」与从未试过都不算。 */
  syncTrouble(): boolean {
    return FeatureFlags.cloudPairing && syncTroubleOf(this.syncState);
  }

  /** 云故障唯一的用户重试入口；结果读真实的推、拉两段，不靠清提示伪造成功。 */
  retrySync(origin: string): void {
    if (this.syncRetryBusy || this.pairState !== PAIRED || !canManuallyRetry(this.syncState)) {
      return;
    }
    this.syncOrigin = origin;
    this.feedbackPairId = SettingsStore.getPairId();
    this.syncFeedback = '';
    this.syncRetryBusy = true;
    ScheduleUseCase.retryCloudSync().then((ok: boolean) => {
      this.syncRetryBusy = false;
      this.reload();
      this.syncFeedback = ok ? '' : '同步未成功';
      appToast(ok ? '已同步最新班表' : '同步仍未成功，请查看下方原因后再试');
    }).catch((e: Error) => {
      this.syncRetryBusy = false;
      this.reload();
      this.syncFeedback = this.syncTrouble() ? '同步未成功' : '云端已恢复，请刷新共同时间';
      appToast(this.syncTrouble()
        ? '同步仍未成功，本机数据已保留'
        : '云同步已恢复，但共同时间暂未刷新；请下拉重新计算');
    });
  }

  /** 只靠六码传递邀请；加入方不再把任何凭据交回邀请方。 */
  waitingNote(): string {
    if (this.pairState === PAIR_PENDING) {
      return this.isInviter
        ? 'TA 已输码，请检查并确认配对。'
        : '申请已送达，等待 TA 确认。';
    }
    return this.myCode === '' ? '配对码已生成；忘记可取消后重新生成。' : '把配对码告诉 TA，加入后由你确认。';
  }

  /** 配对码的朗读文案：逐位分开报，避免 "384106" 被读成一个数值。 */
  codeRead(): string {
    let s = '配对码 ';
    for (let i = 0; i < this.myCode.length; i++) {
      s += this.myCode.charAt(i);
      if (i < this.myCode.length - 1) {
        s += ' ';
      }
    }
    return s + '，逐位念给 TA 输入';
  }

  /** 生成邀请码（创建方）：云函数调用与配对标记读写都在 feature，这里只管按钮态与展示。 */
  createInvite(): void {
    if (this.pairingBusy) {
      return;
    }
    this.pairingBusy = true;
    ProfileSettingsService.createInvite().then((res: InviteResult) => {
      this.pairingBusy = false;
      appToast(res.message);
      if (res.ok) {
        this.myCode = res.code;
        this.joinCode = '';
        this.showJoinInput = false;
        this.pairState = PAIR_WAITING;
        this.isInviter = true;
      }
    });
  }

  /** 输码加入（加入方）：配对码合法性与云端结果统一由服务层判定，页面只 toast。 */
  joinByCode(): void {
    if (this.pairingBusy) {
      return;
    }
    this.pairingBusy = true;
    ProfileSettingsService.joinByCode(this.joinCode).then((res: SettingsResult) => {
      this.pairingBusy = false;
      appToast(res.message);
      if (res.ok) {
        // 输码只提交加入申请；邀请方确认并且云端 ACTIVE 后才显示已配对。
        this.pairState = PAIR_PENDING;
        this.isInviter = false;
        this.showJoinInput = false;
        this.joinCode = '';
      }
    });
  }

  /** 对一次云端的账（协议 §4.4）：本机配对态跟着云端走，不自己造"已配对"。 */
  reconcilePair(): void {
    if (this.pairingBusy) {
      return;
    }
    this.pairingBusy = true;
    ProfileSettingsService.reconcilePair().then((res: SettingsResult) => {
      this.pairingBusy = false;
      this.pairState = ProfileSettingsService.getPairState();
      this.isInviter = ProfileSettingsService.hasLocalInviteProof();
      if (res.approvalRequired === true) {
        this.confirmPair();
      } else {
        appToast(res.message);
      }
      this.reload();
    });
  }

  /** 取消等待中的配对（只清配对标记，不动本机代录数据）。 */
  cancelWaiting(): void {
    ProfileSettingsService.cancelWaiting().then(() => {
      this.pairState = PAIR_NONE;
      this.myCode = '';
      this.isInviter = false;
    });
  }

  /** 动手之前那句「云上会怎么样」（批次 AP·Task 3）。 */
  cloudWipeClause(keepsLocalOnFail: boolean): string {
    const atRisk = ProfileSettingsService.cloudSnapshotsAtRisk();
    const dead = ProfileSettingsService.undeletableCloudSnapshots();
    const parts: string[] = [];
    if (atRisk > 0) {
      const which = atRisk === 1 ? '云上那份加密快照' : '云上那 ' + atRisk + ' 份加密快照';
      parts.push(FeatureFlags.cloudPairing
        ? which + (keepsLocalOnFail
          ? '会一起删掉（要联网），删不动时本机配对先留着不清'
          : '会一起删掉（要联网），删不成本机也照清，下次打开应用会自动再试')
        : which + '这次一份都不会碰（云端功能目前没开通），本机照常清掉，开通后打开应用会自动再试');
    }
    if (dead > 0) {
      parts.push('另有 ' + dead + ' 份这台手机删不掉（云端不认那个删除凭据），做完这一步它们还在云上');
    }
    return parts.length === 0 ? '' : parts.join('；') + '。';
  }

  /** 解除配对（二次确认）：云端删成功才清本机标记（协议 §4.5 批次 U·U5）。 */
  askUnpair(): void {
    askConfirm(this.getUIContext(), {
      message: '解除后不再同步 TA 的数据，本机代录的内容会留着。' + this.cloudWipeClause(true),
      confirmText: '解除配对',
      danger: true,
      onConfirm: () => this.doUnpair()
    });
  }

  doUnpair(): void {
    ProfileSettingsService.unpair().then((res: SettingsResult) => {
      appToast(res.message);
      if (res.ok) {
        this.pairState = PAIR_NONE;
        this.myCode = '';
      }
      this.undeletableCloud = ProfileSettingsService.undeletableCloudSnapshots();
    });
  }

  // ---------- 数据管理 ----------

  /** 清空我的全部数据（二次确认）：先清系统侧投影（受管日程 +「同休日」日历），再删 8 张 RDB 表与全部设置； */
  askClearAll(): void {
    if (this.clearing) {
      return;
    }
    const cloud = this.cloudWipeClause(false);
    askConfirm(this.getUIContext(), {
      title: '清空全部数据',
      message: (cloud === '' ? '' : cloud + '\n')
        + '班表、课表、计划、伴侣档案和设置全部删掉，「同休日」日历里的日程也一起删，删了就找不回来。'
        + '只有导出到系统日历的那条删不动，要你自己去系统日历里删。',
      confirmText: '清空',
      danger: true,
      onConfirm: () => this.doClearAll()
    });
  }

  doClearAll(): void {
    this.clearing = true;
    ProfileSettingsService.clearAllData().then((res: SettingsResult) => {
      this.clearing = false;
      appToast(res.message);
      if (res.ok) {
        this.pairState = PAIR_NONE;
        this.myCode = '';
        this.reload();
      }
    });
  }

  // ---------- 我的作息与计算参数 ----------

  reloadMyParams(): void {
    if (this.myEditing) {
      return;
    }
    const r: MyRhythm = ProfileSettingsService.loadMyRhythm();
    this.myWake = r.wakeText;
    this.myBed = r.bedText;
    this.myWind = r.windText;
    this.myHorizon = r.horizonText;
    this.myMinSlot = r.minSlotMin;
  }

  startEditMyParams(): void {
    this.reloadMyParams();
    this.rhythmTimeRequest++;
    this.myEditing = true;
  }

  cancelMyEdit(): void {
    this.myEditing = false;
    this.reloadMyParams();
  }

  /** 解析、校验与重算都在 ProfileSettingsService：就寝早于起床按次日凌晨计入。 */
  saveMyParams(): void {
    if (this.mySaving) {
      return;
    }
    this.mySaving = true;
    const input: MyRhythm = {
      wakeText: this.myWake, bedText: this.myBed, windText: this.myWind,
      horizonText: this.myHorizon, minSlotMin: this.myMinSlot
    };
    ProfileSettingsService.saveMyRhythm(input).then((res: SettingsResult) => {
      this.mySaving = false;
      appToast(res.message);
      if (!res.ok) {
        return;
      }
      this.myEditing = false;
      this.detailsOpen = false;
      this.reloadMyParams();
    }).catch((e: Error) => {
      this.mySaving = false;
      appToast('保存未成功，请再试一次');
    });
  }

  private pickRhythmTime(bed: boolean): void {
    if (!this.detailsOpen || this.detailKind !== 'rhythm' || !this.myEditing || this.mySaving) {
      return;
    }
    const minutes = hhmmToMin(bed ? this.myBed : this.myWake);
    if (minutes < 0) {
      appToast('时间没读出来，请关闭作息设置后再试');
      return;
    }
    const selected = new Date();
    selected.setHours(Math.floor(minutes / 60), minutes % 60, 0, 0);
    const token = ++this.rhythmTimeRequest;
    try {
      this.getUIContext().showTimePickerDialog({
        selected: selected,
        useMilitaryTime: true,
        dateTimeOptions: { hour: '2-digit', minute: '2-digit' },
        selectedTextStyle: { color: DesignTokens.textAccent },
        acceptButtonStyle: { fontColor: DesignTokens.textAccent },
        onAccept: (result: TimePickerResult) => {
          if (!this.detailsOpen || this.detailKind !== 'rhythm' || !this.myEditing || this.mySaving
            || token !== this.rhythmTimeRequest) {
            return;
          }
          if (!Number.isInteger(result.hour) || !Number.isInteger(result.minute)
            || result.hour < 0 || result.hour > 23 || result.minute < 0 || result.minute > 59) {
            return;
          }
          const text = minToHHmm(result.hour * 60 + result.minute);
          if (bed) {
            this.myBed = text;
          } else {
            this.myWake = text;
          }
        }
      });
    } catch (e) {
      appToast('时间选择暂时打不开，请再试一次');
    }
  }

  private pickMinSlot(v: number): void {
    if (this.mySaving || this.myMinSlot === v) {
      return;
    }
    this.myMinSlot = v;
  }

  private minSlotLabel(v: number): string {
    return v % 60 === 0 ? '' + (v / 60) + '小时' : v + '分钟';
  }

  // ---------- 身份卡文案 ----------

  private identityTitle(): string {
    if (this.pairState === PAIRED) {
      return '我 & ' + this.cloudName;
    }
    if (this.partnerExists) {
      return '我 & ' + this.pNick;
    }
    return '单人模式';
  }

  // ---------- 隐私共享等级（L1/L2/L3 切换 + 持久化） ----------

  /** 各等级 TA 能看到多少。 */
  levelDesc(level: number): string {
    if (level === 1) {
      return 'TA 看得到你有空还是在忙';
    }
    if (level === 2) {
      return 'TA 看得到你在做什么';
    }
    return 'TA 看得到你完整的忙碌时段';
  }

  /** 等级的名字。旧写法是"不是 1 也不是 2 就叫 L3"，于是任何脏值（NaN、0、9）都会被念成 */
  levelTitle(level: number): string {
    if (level === 1) {
      return '忙闲状态';
    }
    if (level === 2) {
      return '班次类型';
    }
    if (level === 3) {
      return '完整时间';
    }
    return '共享等级暂不可确认';
  }

  /** 切换等级：持久化 + 触发重算（等级参与快照生成）。 */
  pickLevel(level: number): void {
    if (this.shareLevel === level) {
      return;
    }
    this.shareLevel = level;
    ProfileSettingsService.setShareLevel(level).then((res: SettingsResult) => {
      appToast(res.ok ? '已切换到' + this.levelTitle(level) + '，重启后仍保持' : res.message);
      if (!res.ok) {
        this.shareLevel = ProfileSettingsService.getShareLevel();
      }
    });
  }

  // ---------- 构建 ----------

  build() {
    ResponsiveContainer({ breakpoint: this.bp }) {
      Column() {
        StickyPageHeader({
          title: '我的', subtitle: '日程、作息与两人的设置',
          visual: this.headerVisual, horizontalPadding: Breakpoints.hPadding(this.bp),
          maxContentWidth: Breakpoints.contentMaxWidth(this.bp)
        })
        .hitTestBehavior(HitTestMode.Transparent)
        Column() {
          FadingScrollViewport({ fadeHeight: 16, visual: this.headerVisual }) {
            Refresh({ refreshing: $$this.refreshing, offset: 64, friction: 10 }) {
              Scroll(this.pageScroller) {
                if (Breakpoints.isExpanded(this.bp)) {
                  // 宽屏两列：伴侣/日程一列，作息/数据一列，读屏顺序仍是先左后右自上而下
                  Row({ space: DesignTokens.space4 }) {
                    Column({ space: DesignTokens.space3 }) {
                      this.identityCard()
                      this.partnerSummaryCard()
                      this.scheduleCard()
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)

                    Column({ space: DesignTokens.space3 }) {
                      this.rhythmSummaryCard()
                      this.dataCard()
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                  }
                  .width('100%')
                  .constraintSize({ maxWidth: Breakpoints.contentMaxWidth(this.bp) })
                  .alignItems(VerticalAlign.Top)
                  .padding(this.contentPadding())
                } else {
                  Column({ space: DesignTokens.space3 }) {
                    this.identityCard()
                    this.partnerSummaryCard()
                    this.scheduleCard()
                    this.rhythmSummaryCard()
                    this.dataCard()
                  }
                  .width('100%')
                  .constraintSize({ maxWidth: Breakpoints.contentMaxWidth(this.bp) })
                  .padding(this.contentPadding())
                }
              }
              .width('100%')
              .height('100%')
              .align(Alignment.Top)
              .scrollBar(BarState.Off)
              .onAppear(() => { this.headerVisual.update(this.pageScroller.currentOffset().yOffset); })
              .onDidScroll(() => {
                this.headerVisual.update(this.pageScroller.currentOffset().yOffset);
              })
              .bindSheet($$this.detailsOpen, this.detailsSheet(), {
                height: this.detailKind === 'rhythm' ? '46%' : this.partnerSheetHeight(),
                preferType: SheetType.BOTTOM,
                dragBar: false, showClose: false,
                backgroundColor: Color.Transparent, blurStyle: BlurStyle.NONE,
                maskColor: DesignTokens.scrim,
                onDisappear: () => this.closeDetails(),
                onWillDismiss: (action: DismissSheetAction) => {
                  if (!this.mySaving && !this.nameSaving) {
                    action.dismiss();
                  }
                }
              })
            }
            .onRefreshing(() => {
              this.onRefresh();
            })
            .width('100%')
            .height('100%')
            .bindSheet($$this.policyOpen, this.policySheet(), {
              detents: [SheetSize.LARGE], dragBar: false, showClose: false,
              backgroundColor: Color.Transparent, blurStyle: BlurStyle.NONE,
              maskColor: DesignTokens.scrim
            })
          }
        }
        .width('100%').layoutWeight(1)
      }
      .width('100%').height('100%')
      .linearGradient(DesignTokens.pageGradient())
    }
  }

  /** 留白在滚动内容上而不是 Scroll 上：底部留白要跟着内容一起滚，不占死视口。 */
  private contentPadding(): Padding {
    const h: number = Breakpoints.hPadding(this.bp);
    return { left: h, right: h, top: 8, bottom: DesignTokens.dockClearance };
  }

  @Builder
  partnerSummaryCard() {
    Column({ space: 8 }) {
      EditorialCard({ hero: false, cutTopLeft: true, tappable: true,
        onTapCard: () => this.openDetails('partner') }) {
        Column({ space: DesignTokens.space2 }) {
          this.cardHead({ title: '伴侣与同步', action: '', onAction: () => {} })
          Text((this.pairState === PAIRED ? this.cloudName : (this.partnerExists ? this.pNick : 'TA'))
            + ' · ' + (this.partnerExists && this.pairState === PAIR_NONE ? '本机代录' : this.pairStateText()))
            .fontSize(DesignTokens.fontBody).fontColor(DesignTokens.textPrimary)
        }.width('100%').alignItems(HorizontalAlign.Start)
      }
      // 重试是卡片的兄弟节点，不落在可点卡内，避免重试顺便打开详情。
      if (this.syncTrouble()) {
        NoticeBar({
          tone: this.syncState.outcome === SYNC_STATE_BLOCKED ? NoticeTone.ERROR : NoticeTone.WARN,
          title: syncStateTitleOf(this.syncState), body: syncStateNoteOf(this.syncState)
        })
      }
      this.syncButton('summary')
    }.width('100%')
  }

  @Builder
  syncButton(origin: string) {
    if (this.pairState === PAIRED && FeatureFlags.cloudPairing
      && (canManuallyRetry(this.syncState) || (this.syncRetryBusy && this.syncOrigin === origin))) {
      SyncFeedbackButton({
        busy: this.syncOrigin === origin && this.syncRetryBusy,
        result: this.syncOrigin === origin ? this.syncFeedback : '',
        disabled: this.syncRetryBusy || !canManuallyRetry(this.syncState),
        onRetry: () => this.retrySync(origin)
      })
    }
  }

  @Builder
  rhythmSummaryCard() {
    EditorialCard({ hero: false, cutTopLeft: true, tappable: true,
      onTapCard: () => this.openDetails('rhythm') }) {
      Column({ space: DesignTokens.space2 }) {
        this.cardHead({ title: '作息', action: '', onAction: () => {} })
        Text('起床 ' + this.myWake + ' · 就寝 ' + this.myBed)
          .fontSize(DesignTokens.fontBody).fontColor(DesignTokens.textPrimary)
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  detailsSheet() {
    if (this.detailKind === 'rhythm') {
      this.rhythmSheet()
    } else {
      Column({ space: DesignTokens.space3 }) {
        Row() {
          Text(this.detailKind === 'name' ? '为 TA 取一个名字吧！' : '伴侣与同步')
            .fontSize(DesignTokens.fontTitle)
            .fontColor(DesignTokens.textPrimary).layoutWeight(1)
          Button(this.detailKind === 'name' ? '暂不取名' : '关闭')
            .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .backgroundColor(DesignTokens.fillWeak).fontColor(DesignTokens.textSecondary)
            .enabled(!this.nameSaving && !this.mySaving).onClick(() => this.closeDetails())
        }.width('100%')
        Scroll() {
          Column({ space: DesignTokens.space3 }) {
            if (this.detailKind === 'name') {
              Text('仅本机可见，可随时修改。')
                .fontSize(DesignTokens.fontBody).fontColor(DesignTokens.textSecondary)
              TextInput({ text: this.nameDraft, placeholder: '不填写时显示 TA' })
                .fontSize(DesignTokens.fontBody).maxLength(20)
                .accessibilityText('伴侣称呼，最多 20 个字符')
                .onChange((value: string) => { this.nameDraft = value; })
              if (this.nameError !== '') {
                Text(this.nameError).fontSize(DesignTokens.fontCaption).fontColor(DesignTokens.danger)
              }
              Button(this.nameSaving ? '保存中…' : '保存称呼')
                .width('100%').constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
                .backgroundColor(DesignTokens.primary).fontColor(DesignTokens.heroText)
                .enabled(!this.nameSaving).onClick(() => { this.finishCloudName(false); })
            } else if (this.detailKind === 'partner') {
              if (this.pairState === PAIRED) {
                this.navRow($r('sys.symbol.square_and_pencil'), '对 TA 的称呼', this.cloudName, false,
                  () => this.editCloudName())
              }
              this.partnerSyncCard()
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
      }
      .width('100%').height('100%').padding(20)
      .backgroundColor(DesignTokens.card)
      .borderRadius({ topLeft: DesignTokens.radiusSheet, topRight: DesignTokens.radiusSheet })
      .clip(true)
    }
  }

  @Builder
  rhythmSheet() {
    Column({ space: 10 }) {
      Text('作息设置').fontSize(DesignTokens.fontTitle).fontWeight(FontWeight.Bold)
        .fontFamily(DesignTokens.fontRound).fontColor(DesignTokens.textPrimary).width('100%')
      Scroll() {
        this.rhythmForm()
      }.width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Off)
      Row({ space: 10 }) {
        Button('取消').layoutWeight(1).fontSize(DesignTokens.fontBody)
          .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
          .backgroundColor(DesignTokens.fillWeak).fontColor(DesignTokens.textSecondary)
          .enabled(!this.mySaving).onClick(() => this.closeDetails())
        Button(this.mySaving ? '保存中…' : '保存').layoutWeight(1).fontSize(DesignTokens.fontBody)
          .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
          .backgroundColor(DesignTokens.primary).fontColor(DesignTokens.heroText)
          .enabled(!this.mySaving).onClick(() => this.saveMyParams())
      }.width('100%')
    }
    .width('100%').height('100%').padding({ left: 20, right: 20, top: 20, bottom: 24 })
    .backgroundColor(DesignTokens.card)
    .borderRadius({ topLeft: DesignTokens.radiusSheet, topRight: DesignTokens.radiusSheet })
    .clip(true)
  }

  /** 卡内小标题：衬线标题 + 可选的右侧操作文字（编辑/收起等）。 */
  @Builder
  cardHead(row: CardHeadArg) {
    Row() {
      Text(row.title)
        .fontSize(DesignTokens.fontBody)
        .fontFamily(DesignTokens.fontRound)
        .fontWeight(FontWeight.Medium)
        .fontColor(DesignTokens.textPrimary)
      Blank()
      if (row.action !== '') {
        Text(row.action)
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textAccent)
          .textAlign(TextAlign.End)
          .padding({ left: DesignTokens.space2, top: DesignTokens.space1, bottom: DesignTokens.space1 })
          .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
          // 卡片标题右侧的"编辑/收起"是纯文字按钮：焦点与朗读名都要自己给
          .focusable(true)
          .accessibilityText(row.action + '：' + row.title)
          .onClick(row.onAction)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 入口行：图标 + 主副文案 + 箭头，整行 44vp 以上热区。 */
  @Builder
  navRow(glyph: Resource, title: string, desc: string, danger: boolean, onTap: () => void) {
    Row({ space: DesignTokens.space3 }) {
      SymbolGlyph(glyph)
        .fontSize(20)
        .fontColor([danger ? DesignTokens.danger : DesignTokens.primary])
        // 行内已有主副文案，图标只是重复提示
        .accessibilityLevel('no')
      Column({ space: 2 }) {
        Text(title)
          .fontSize(DesignTokens.fontBody)
          .fontWeight(FontWeight.Medium)
          .fontColor(danger ? DesignTokens.danger : DesignTokens.textPrimary)
        Text(desc)
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textTertiary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16).fontColor([DesignTokens.textDisabled])
        .accessibilityLevel('no')
    }
    .width('100%')
    .padding(DesignTokens.space2)
    .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
    .alignItems(VerticalAlign.Center)
    .focusable(true)
    .accessibilityGroup(true)
    .accessibilityText(title + '。' + desc)
    .onClick(onTap)
  }

  @Builder
  divider() {
    Divider().color(DesignTokens.divider).width('100%')
  }

  @Builder
  identityCard() {
    EditorialCard({ hero: true, cutTopLeft: true, tappable: false }) {
      Row({ space: DesignTokens.space3 }) {
        Column() {
          Text('我')
            .fontSize(DesignTokens.fontBody)
            .fontFamily(DesignTokens.fontRound)
            .fontWeight(FontWeight.Medium)
            .fontColor(DesignTokens.heroText)
            .accessibilityLevel('no')
        }
        .width(44)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .borderRadius(DesignTokens.radiusPill)
        .backgroundColor(DesignTokens.heroGlow)

        Column({ space: 2 }) {
          Text(this.identityTitle())
            .fontSize(DesignTokens.fontTitle)
            .fontFamily(DesignTokens.fontRound)
            .fontWeight(FontWeight.Bolder)
            .fontColor(DesignTokens.heroText)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('共同时间')
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.heroText)
          .padding({
            left: DesignTokens.space3,
            right: DesignTokens.space3,
            top: DesignTokens.space1,
            bottom: DesignTokens.space1
          })
          .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
          .borderRadius(DesignTokens.radiusPill)
          .backgroundColor(DesignTokens.heroGlow)
          .focusable(true)
          .accessibilityText('去共同时间页')
          .clickEffect(DesignTokens.tapChip())
          .onClick(() => this.onOpenRoute(NavRoutes.COMMON_TIME))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
  }

  /** 伴侣与同步：本机代录（离线，无需第二个账号）与云端配对（两台手机）并列， */
  @Builder
  partnerSyncCard() {
    EditorialCard({ hero: false, cutTopLeft: true, tappable: false }) {
      Column({ space: DesignTokens.space4 }) {
        Row() {
          Text('伴侣与同步')
            .fontSize(DesignTokens.fontBody)
            .fontFamily(DesignTokens.fontRound)
            .fontWeight(FontWeight.Medium)
            .fontColor(DesignTokens.textPrimary)
          Blank()
          Text(this.pairStateText())
            .fontSize(DesignTokens.fontCaption)
            .fontColor(this.pairState === PAIRED ? DesignTokens.textAccent : DesignTokens.textTertiary)
            .padding({ left: DesignTokens.space2, right: DesignTokens.space2 })
            .constraintSize({ minHeight: DesignTokens.hitMin })
            .borderRadius(DesignTokens.radiusPill)
            .backgroundColor(this.pairState === PAIRED ? DesignTokens.primaryBg : DesignTokens.fillWeakest)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        this.partnerBlock()

        this.divider()

        this.pairingBlock()

        // 共享等级只在云端链路开着时才有可见效果（它参与快照生成），关闭态连控件一起收走。
        // 值本身照旧保存在本机：档位关的是能力，不是用户已经设过的数据。
        if (FeatureFlags.cloudPairing) {
          this.divider()

          this.levelBlock()
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  partnerBlock() {
    Column({ space: DesignTokens.space3 }) {
      Text('本机代录')
        .fontSize(DesignTokens.fontCaption)
        .fontColor(DesignTokens.textTertiary)

      if (this.partnerEditing) {
        Column({ space: DesignTokens.space2 }) {
          Row({ space: DesignTokens.space2 }) {
            Text('昵称').fontSize(DesignTokens.fontCaption)
            TextInput({ text: this.pNick, placeholder: 'TA 的昵称（如：阿明）' })
              .layoutWeight(1).constraintSize({ minHeight: DesignTokens.hitMin })
              .fontSize(DesignTokens.fontCaption)
              .borderRadius(DesignTokens.radiusInput)
              .border({ width: 1.5, color: DesignTokens.primaryBorder })
              .backgroundColor(DesignTokens.card)
              .accessibilityText('TA 的昵称')
              .onChange((v: string) => this.pNick = v)
          }.width('100%')

          // 三对"标签+输入框"各自成组再换行：钉死宽度的单行在 2 倍字号下会横向溢出
          Flex({ wrap: FlexWrap.Wrap }) {
            Row({ space: DesignTokens.space2 }) {
              Text('起床').fontSize(DesignTokens.fontCaption)
              TextInput({ text: this.pWake })
                .constraintSize({ minWidth: 64, minHeight: DesignTokens.hitMin })
                .fontSize(DesignTokens.fontCaption)
                .borderRadius(DesignTokens.radiusInput)
                .border({ width: 1.5, color: DesignTokens.primaryBorder })
                .backgroundColor(DesignTokens.card)
                .accessibilityText('TA 的起床时间，格式 HH:MM')
                .onChange((v: string) => this.pWake = v)
            }
            .margin({ right: DesignTokens.space2, bottom: DesignTokens.space2 })
            .accessibilityGroup(true)

            Row({ space: DesignTokens.space2 }) {
              Text('就寝').fontSize(DesignTokens.fontCaption)
              TextInput({ text: this.pBed })
                .constraintSize({ minWidth: 64, minHeight: DesignTokens.hitMin })
                .fontSize(DesignTokens.fontCaption)
                .borderRadius(DesignTokens.radiusInput)
                .border({ width: 1.5, color: DesignTokens.primaryBorder })
                .backgroundColor(DesignTokens.card)
                .accessibilityText('TA 的就寝时间，格式 HH:MM')
                .onChange((v: string) => this.pBed = v)
            }
            .margin({ right: DesignTokens.space2, bottom: DesignTokens.space2 })
            .accessibilityGroup(true)

            Row({ space: DesignTokens.space2 }) {
              Text('睡前准备(分)').fontSize(DesignTokens.fontCaption)
              TextInput({ text: this.pWind })
                .constraintSize({ minWidth: 56, minHeight: DesignTokens.hitMin })
                .type(InputType.Number)
                .fontSize(DesignTokens.fontCaption)
                .borderRadius(DesignTokens.radiusInput)
                .border({ width: 1.5, color: DesignTokens.primaryBorder })
                .backgroundColor(DesignTokens.card)
                .accessibilityText('TA 的收整缓冲分钟数')
                .onChange((v: string) => this.pWind = v)
            }
            .margin({ right: DesignTokens.space2, bottom: DesignTokens.space2 })
            .accessibilityGroup(true)
          }
          .width('100%')

          Text('时间格式 07:00；凌晨就寝按次日计算。')
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.textHint)
          Row({ space: DesignTokens.space3 }) {
            Button('保存').layoutWeight(1)
              .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
              .backgroundColor(DesignTokens.primary)
              .fontWeight(FontWeight.Bold)
              .shadow(DesignTokens.jelly(DesignTokens.primaryDeep, DesignTokens.jellyDepth))
              .onClick(() => this.savePartner())
            Button('取消').layoutWeight(1)
              .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
              .backgroundColor(DesignTokens.fillWeak)
              .fontColor(DesignTokens.textSecondary)
              .onClick(() => this.cancelPartnerEdit())
          }.width('100%')
        }
        .width('100%')
      } else if (!this.partnerExists) {
        Button('添加伴侣（本机代录）')
          .width('100%')
          .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
          .backgroundColor(DesignTokens.primary)
          .fontWeight(FontWeight.Bold)
          .shadow(DesignTokens.jelly(DesignTokens.primaryDeep, DesignTokens.jellyDepth))
          .onClick(() => this.startAddPartner())
      } else {
        Row() {
          Column({ space: 2 }) {
            Text(this.pNick)
              .fontSize(DesignTokens.fontBody)
              .fontWeight(FontWeight.Medium)
              .fontColor(DesignTokens.textPrimary)
            Text('起床 ' + this.pWake + ' · 就寝 ' + this.pBed + ' · 睡前准备 ' + this.pWind + ' 分钟')
              .fontSize(DesignTokens.fontCaption)
              .fontColor(DesignTokens.textTertiary)
            if (this.bedNote(this.pWake, this.pBed) !== '') {
              Text(this.bedNote(this.pWake, this.pBed))
                .fontSize(DesignTokens.fontCaption)
                .fontColor(DesignTokens.textSecondary)
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text('编辑')
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.textAccent)
            .padding(DesignTokens.space2)
            .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .focusable(true)
            .accessibilityText('编辑 TA 的作息')
            .onClick(() => this.startEditPartner())
          Text('删除')
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.danger)
            .padding(DesignTokens.space2)
            .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .focusable(true)
            .accessibilityText('删除伴侣档案')
            .onClick(() => this.confirmDeletePartner())
        }.width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  pairingBlock() {
    Column({ space: DesignTokens.space3 }) {
      Text('云配对')
        .fontSize(DesignTokens.fontCaption)
        .fontColor(DesignTokens.textTertiary)

      if (!FeatureFlags.cloudPairing) {
        // 关闭态一格云入口都不摆；真正的拒绝仍在 service 层。
        Text(FeatureFlags.cloudClosedMessage)
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textSecondary)
        Text('想现在就算，请用上方「伴侣（本机代录）」。')
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textHint)
        if (this.pairState === PAIRED) {
          Button('解除配对')
            .width('100%')
            .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .backgroundColor(DesignTokens.fillWeak)
            .fontWeight(FontWeight.Bold)
            .shadow(DesignTokens.jelly(DesignTokens.borderWeak, DesignTokens.jellyDepth))
            .fontColor(DesignTokens.danger)
            .onClick(() => this.askUnpair())
        } else if (this.pairState === PAIR_WAITING || this.pairState === PAIR_PENDING) {
          Button('取消配对')
            .width('100%')
            .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .backgroundColor(DesignTokens.fillWeak)
            .fontWeight(FontWeight.Bold)
            .shadow(DesignTokens.jelly(DesignTokens.borderWeak, DesignTokens.jellyDepth))
            .fontColor(DesignTokens.textSecondary)
            .onClick(() => this.cancelWaiting())
        }
      } else if (this.pairState === PAIRED) {
        Text(this.pairedNote())
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textSecondary)
        if (this.syncTrouble() && this.syncState.outcome === SYNC_STATE_BLOCKED) {
          NoticeBar({
            tone: NoticeTone.ERROR,
            title: syncStateTitleOf(this.syncState),
            body: syncStateNoteOf(this.syncState)
          })
        } else if (this.syncTrouble()) {
          NoticeBar({
            tone: NoticeTone.WARN,
            title: syncStateTitleOf(this.syncState),
            body: syncStateNoteOf(this.syncState)
          })
        }
        this.syncButton('sheet')
        Button('解除配对')
          .width('100%')
          .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
          .backgroundColor(DesignTokens.fillWeak)
          .fontWeight(FontWeight.Bold)
          .shadow(DesignTokens.jelly(DesignTokens.borderWeak, DesignTokens.jellyDepth))
          .fontColor(DesignTokens.danger)
          .onClick(() => this.askUnpair())
      } else if (this.pairState === PAIR_WAITING || this.pairState === PAIR_PENDING) {
        if (this.myCode !== '') {
          Text(this.myCode)
            .fontSize(34)
            .fontWeight(FontWeight.Bold)
            .fontColor(DesignTokens.textAccent)
            .letterSpacing(6)
            .width('100%')
            .textAlign(TextAlign.Center)
            // 视觉上是"384106"，朗读必须逐位报数，否则会被读成"三十八万四千一百零六"
            .accessibilityText(this.codeRead())
          Button('复制配对码')
            .width('100%')
            .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .backgroundColor(DesignTokens.fillWeak)
            .fontWeight(FontWeight.Bold)
            .shadow(DesignTokens.jelly(DesignTokens.borderWeak, DesignTokens.jellyDepth))
            .fontColor(DesignTokens.textSecondary)
            .onClick(() => this.copyPairCode())
        }
        Row({ space: DesignTokens.space3 }) {
          Button(this.pairingBusy ? '检查中…' : (this.isInviter ? '检查并确认配对' : '检查配对状态')).layoutWeight(1)
            .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .backgroundColor(DesignTokens.primary)
            .fontWeight(FontWeight.Bold)
            .shadow(DesignTokens.jelly(DesignTokens.primaryDeep, DesignTokens.jellyDepth))
            .enabled(!this.pairingBusy)
            .onClick(() => this.reconcilePair())
          Button('取消配对').layoutWeight(1)
            .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .backgroundColor(DesignTokens.fillWeak)
            .fontColor(DesignTokens.textSecondary)
            .onClick(() => this.cancelWaiting())
        }.width('100%')

        // 只查询真实云端状态；邀请方见到待确认申请时在本机弹确认框。
        Text(this.waitingNote())
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textHint)
      } else {
        Row({ space: DesignTokens.space3 }) {
          Button(this.pairingBusy ? '生成中…' : '生成配对码').layoutWeight(1)
            .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .backgroundColor(DesignTokens.primary)
            .fontWeight(FontWeight.Bold)
            .shadow(DesignTokens.jelly(DesignTokens.primaryDeep, DesignTokens.jellyDepth))
            .enabled(!this.pairingBusy)
            .onClick(() => this.createInvite())
          Button('输码加入').layoutWeight(1)
            .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .backgroundColor(DesignTokens.fillWeak)
            .fontWeight(FontWeight.Bold)
            .shadow(DesignTokens.jelly(DesignTokens.borderWeak, DesignTokens.jellyDepth))
            .fontColor(DesignTokens.textSecondary)
            .enabled(!this.pairingBusy)
            .onClick(() => {
              this.showJoinInput = !this.showJoinInput;
            })
        }.width('100%')

        if (this.showJoinInput) {
          Row({ space: DesignTokens.space2 }) {
            Text('配对码').fontSize(DesignTokens.fontCaption)
            TextInput({ text: this.joinCode, placeholder: '6 位数字' })
              .layoutWeight(1)
              .constraintSize({ minHeight: DesignTokens.hitMin })
              .type(InputType.Number)
              .maxLength(6)
              .fontSize(DesignTokens.fontCaption)
              .borderRadius(DesignTokens.radiusInput)
              .border({ width: 1.5, color: DesignTokens.primaryBorder })
              .backgroundColor(DesignTokens.card)
              .accessibilityText('输入 6 位配对码')
              .onChange((v: string) => this.joinCode = v)
            Button(this.pairingBusy ? '加入中…' : '加入')
              .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
              .backgroundColor(DesignTokens.primary)
              .fontWeight(FontWeight.Bold)
              .shadow(DesignTokens.jelly(DesignTokens.primaryDeep, DesignTokens.jellyDepth))
              .enabled(!this.pairingBusy)
              .onClick(() => this.joinByCode())
          }.width('100%')
        }

      }
      UnifiedPairingStatus({ active: this.active && this.detailsOpen && this.detailKind === 'partner',
        legacyState: this.pairState, onState: (phase: string): void => {
          const completed = phase === 'READY' && this.unifiedPhase !== 'READY';
          this.unifiedPhase = phase;
          this.pairState = ProfileSettingsService.getPairState();
          this.isInviter = ProfileSettingsService.hasLocalInviteProof();
          if (completed) this.reload();
        } })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  levelBlock() {
    Column({ space: DesignTokens.space2 }) {
      Text('分享哪些信息')
        .fontSize(DesignTokens.fontCaption)
        .fontColor(DesignTokens.textTertiary)
      if (this.shareLevel === SHARE_LEVEL_UNKNOWN) {
        // 三行都不勾：勾上任何一档都是把"没读到"说成"用户选的"。这一句说的是事实，不猜等级。
        Text('分享设置暂时读不到，同步已暂停。请退出这一页后重试。')
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textHint)
      }
      ForEach([1, 2, 3], (lv: number) => {
        Row({ space: DesignTokens.space3 }) {
          Column({ space: 2 }) {
            Row({ space: DesignTokens.space1 }) {
              Text(this.levelTitle(lv))
                .fontSize(DesignTokens.fontBody)
                .fontColor(this.shareLevel === lv ? DesignTokens.textAccent : DesignTokens.textPrimary)
                .fontWeight(this.shareLevel === lv ? FontWeight.Medium : FontWeight.Normal)
              if (lv === 2) {
                Text('默认')
                  .fontSize(DesignTokens.fontCaption)
                  .fontColor(DesignTokens.heroText)
                  .padding({ left: DesignTokens.space2, right: DesignTokens.space2 })
                  .borderRadius(DesignTokens.radiusPill)
                  .backgroundColor(DesignTokens.primary)
              }
            }.alignItems(VerticalAlign.Center)

            Text(this.levelDesc(lv))
              .fontSize(DesignTokens.fontCaption)
              .fontColor(this.shareLevel === lv ? DesignTokens.textSecondary : DesignTokens.textTertiary)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding(DesignTokens.space2)
        .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
        .borderRadius(DesignTokens.radiusCard)
        .backgroundColor(this.shareLevel === lv ? DesignTokens.shareSelectedBg : Color.Transparent)
        .animation({ duration: this.shareLevel === lv ? 140 : 0, curve: Curve.EaseOut })
        .focusable(true).accessibilityGroup(true)
        .accessibilityRole(AccessibilityRoleType.BUTTON)
        .accessibilityChecked(this.shareLevel === lv)
        .accessibilityText(this.levelTitle(lv) + '，' + this.levelDesc(lv)
          + (this.shareLevel === lv ? '，已选择' : '，未选择'))
        .clickEffect(DesignTokens.tapButton())
        .onClick(() => this.pickLevel(lv))
      }, (lv: number) => 'lv' + lv)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 我的日程：日程录入页（栈目的地）的唯一入口，落「我」这侧；切 TA 在页内分段上。 */
  @Builder
  scheduleCard() {
    EditorialCard({ hero: false, cutTopLeft: false, tappable: false }) {
      Column({ space: DesignTokens.space2 }) {
        this.cardHead({ title: '我的日程', action: '', onAction: () => {} })

        this.navRow($r('sys.symbol.calendar'), '班表与课程',
          '按周排班、设置常用班次或导入课程', false, () => {
            this.onOpenRoute(NavRoutes.SCHEDULE_HUB, ownerParam(OWNER_ME));
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 紧凑草稿表单，保存动作固定在 sheet 底部。 */
  @Builder
  rhythmForm() {
    Column({ space: 6 }) {
      Row({ space: 10 }) {
        this.rhythmTimeButton(false)
        this.rhythmTimeButton(true)
      }.width('100%')
      Column() {
        Row({ space: 8 }) {
          Text('睡前准备（分钟）').fontSize(DesignTokens.fontCaption).fontColor(DesignTokens.textSecondary)
            .layoutWeight(1)
          TextInput({ text: this.myWind }).type(InputType.Number).fontSize(DesignTokens.fontBody)
            .fontColor(DesignTokens.textPrimary)
            .width(80).textAlign(TextAlign.End).padding({ left: 0, right: 0 }).enabled(!this.mySaving)
            .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .backgroundColor(Color.Transparent)
            .accessibilityText('睡前准备时长，单位分钟')
            .onChange((v: string) => { this.myWind = v; })
        }.width('100%')
        Divider().color(DesignTokens.divider).strokeWidth(1)
        Row({ space: 8 }) {
          Text('往后计算（天）').fontSize(DesignTokens.fontCaption).fontColor(DesignTokens.textSecondary)
            .layoutWeight(1)
          TextInput({ text: this.myHorizon }).type(InputType.Number).fontSize(DesignTokens.fontBody)
            .fontColor(DesignTokens.textPrimary)
            .width(80).textAlign(TextAlign.End).padding({ left: 0, right: 0 }).enabled(!this.mySaving)
            .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .backgroundColor(Color.Transparent)
            .accessibilityText('往后计算天数，可以填 ' + HORIZON_MIN + ' 到 ' + HORIZON_MAX)
            .onChange((v: string) => { this.myHorizon = v; })
        }.width('100%')
      }.width('100%').padding({ left: 12, right: 12 })
        .backgroundColor(DesignTokens.fillWeakest).borderRadius(DesignTokens.radiusInput)
      this.calculationForm()
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  rhythmTimeButton(bed: boolean) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 2 }) {
        Text(bed ? '就寝' : '起床').fontSize(DesignTokens.fontCaption).fontColor(DesignTokens.textSecondary)
        Text(bed ? this.myBed : this.myWake).fontSize(DesignTokens.fontTitle).fontWeight(FontWeight.Medium)
          .fontColor(DesignTokens.textPrimary)
      }.width('100%').alignItems(HorizontalAlign.Start)
    }.layoutWeight(1).padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .constraintSize({ minHeight: 60 }).backgroundColor(DesignTokens.fillWeakest)
      .borderRadius(DesignTokens.radiusInput).enabled(!this.mySaving)
      .accessibilityText((bed ? '就寝' : '起床') + '时间，' + (bed ? this.myBed : this.myWake) + '，点击选择时间')
      .onClick(() => this.pickRhythmTime(bed))
  }

  private minSlotChoices(): number[] {
    return MIN_SLOT_STEPS.indexOf(this.myMinSlot) >= 0 ? MIN_SLOT_STEPS : [this.myMinSlot].concat(MIN_SLOT_STEPS);
  }

  @Builder
  calculationForm() {
    Row({ space: 8 }) {
      Text('最短共同时段').fontSize(DesignTokens.fontCaption).fontColor(DesignTokens.textSecondary)
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.End }) {
        ForEach(this.minSlotChoices(), (v: number) => {
          Button(this.minSlotLabel(v))
            .fontSize(DesignTokens.fontCaption)
            .fontColor(this.myMinSlot === v ? DesignTokens.textAccent : DesignTokens.textSecondary)
            .padding({ left: 8, right: 8 }).margin({ left: 4 })
            .constraintSize({ minWidth: 44, minHeight: AccessibilityPolicy.minHit(this.senior) })
            .borderRadius(DesignTokens.radiusInput)
            .backgroundColor(this.myMinSlot === v ? DesignTokens.shareSelectedBg : Color.Transparent)
            .focusable(true).accessibilityChecked(this.myMinSlot === v)
            .accessibilityText('至少' + this.minSlotLabel(v) + (this.myMinSlot === v ? '，已选择' : '，未选择'))
            .enabled(!this.mySaving)
            .onClick(() => this.pickMinSlot(v))
        }, (v: number) => 'ms' + v)
      }.layoutWeight(1)
    }.width('100%')
  }

  @Builder
  dataCard() {
    EditorialCard({ hero: false, cutTopLeft: false, tappable: false }) {
      Column({ space: DesignTokens.space2 }) {
        this.cardHead({ title: '数据与隐私', action: '', onAction: () => {} })

        if (this.secureCleanupNote !== '') {
          Text(this.secureCleanupNote)
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.textHint)
          Button(this.secureCleanupBusy ? '正在核实清理…' : '重试云端清理')
            .enabled(!this.secureCleanupBusy && FeatureFlags.cloudPairing)
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.textPrimary)
            .backgroundColor(DesignTokens.primaryBg)
            .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .onClick(() => {
              this.secureCleanupBusy = true;
              secureCloudCleanup().retry().then((code: string) => {
                appToast(code === 'OK' ? '云端清理完成' : '仍有待清理记录，详情见下方提示');
              }).catch(() => { appToast('本次未能核实清理结果，记录仍保留'); })
                .finally(() => { this.secureCleanupBusy = false; this.reload(); });
            })
        }

        if (this.undeletableCloud > 0) {
          Text('云上还剩 ' + this.undeletableCloud + ' 份加密快照这台手机删不掉，云端不认这个删除凭据；'
            + '本机数据不受影响。')
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.textHint)
        }

        this.navRow($r('sys.symbol.checkmark_shield'), '隐私政策', '权限用途与数据去向', false, () => {
          this.policyOpen = true;
        })

        this.divider()

        if (this.clearing) {
          this.navRow($r('sys.symbol.trash'), '清空我的全部数据', '正在清空…', true, () => {
          })
        } else {
          this.navRow($r('sys.symbol.trash'), '清空我的全部数据',
            '删掉全部班表、课表、计划和设置，删了就找不回来', true, () => this.askClearAll())
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 隐私政策面板。 */
  @Builder
  policySheet() {
    PrivacyPolicySheet({ onClose: () => {
      this.policyOpen = false;
    } })
  }
}
