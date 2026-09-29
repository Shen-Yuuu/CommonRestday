import { HORIZON_DEFAULT_DAYS, OWNER_ME, PairLink, PairOffer } from 'domain';
import { PAIRED, PAIR_NONE, PAIR_PENDING, PAIR_WAITING } from 'data';
import {
  FeatureFlags, HORIZON_MAX, HORIZON_MIN, InviteResult, isCrossMidnight, MyRhythm,
  PairChannels, PairingShareGateway, PairOpResult, PartnerInput, ProfileSettingsService,
  ScanOutcome, ScanResult, SettingsResult, SYNC_STATE_BLOCKED, SYNC_STATE_OK, SyncState,
  syncStateNoteOf, syncStateTitleOf, syncTroubleOf
} from 'feature';
import { PrivacyPolicySheet } from '../component/PrivacyPolicySheet';
import { DesignTokens } from '../theme/DesignTokens';
import { NavRoutes } from '../navigation/NavRoutes';
import { ownerParam } from '../model/RouteParams';
import { EditorialCard } from '../component/EditorialCard';
import { NoticeBar, NoticeTone } from '../component/NoticeBar';
import { Breakpoint, Breakpoints } from '../responsive/Breakpoints';
import { ResponsiveContainer } from '../responsive/ResponsiveContainer';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';
import { appToast } from '../util/AppToast';
import { askConfirm } from '../util/AppConfirm';
import { syncOnPull } from '../util/PullRefresh';

/** 最短共同时段的常用档：碎片小于 1 小时几乎安排不了事，大于 4 小时又太难得。 */
const MIN_SLOT_STEPS: number[] = [60, 120, 240];

/** @Builder 传两个及以上参数时不参与动态渲染（ArkUI 限制），所以一格合成一个对象字面量按引用传。 */
interface ParamStatArg {
  value: string;
  label: string;
}

/** 卡内小标题的入参：`action` 由父页状态算出来（编辑态要收起"编辑"这颗），必须跟着换（D-46 第二形）。 */
interface CardHeadArg {
  title: string;
  action: string;
  onAction: () => void;
}

/**
 * 我的页：四段收纳——伴侣与同步、我的日程、作息、数据与隐私。
 * - 作息只摆起床/就寝/收整三个主参数，视界与最短共同时段收进「高级设置」；
 * - 班表录入不再是底部 Tab，这里给一条直达入口；我这侧与代录 TA 那侧是同一个页面的两个视图，
 *   所以只给一颗，进去后用页首的「我的班表 / TA 的班表」分段切侧；
 * - 首发零通知：本页不摆任何通知/提醒开关，到点报时全部交给系统日历（D-20）；
 * - 云端配对关闭时这一页不摆任何云入口（生成/输码/扫码/分享/等级一起收），只留本机代录与退出通道。
 */
@Component
export struct MeView {
  /** 打开路由（班表页并指定录哪一侧），由 AppNavigator 注入：路由种类只有壳层知道。 */
  onOpenRoute: (name: string, params?: Object) => void = (name: string, params?: Object) => {
  };
  @State private shareLevel: number = 2;
  @State private pairState: string = PAIR_NONE;
  /**
   * 云同步三态（协议 §3.4 末行）：默认「已同步」= 提示条不出。
   * 只在进这一页时读一次——它是后台推送/拉取失败时写的，没有理由为一条提示条挂监听。
   */
  @State private syncState: SyncState = { outcome: SYNC_STATE_OK, day: 0, code: '' };
  // 伴侣档案
  @State private partnerExists: boolean = false;
  @State private partnerEditing: boolean = false;
  @State private pNick: string = '';
  @State private pWake: string = '07:00';
  @State private pBed: string = '22:30';
  @State private pWind: string = '20';
  // 云端配对
  @State private pairingBusy: boolean = false;
  @State private showJoinInput: boolean = false;
  @State private myCode: string = '';
  @State private joinCode: string = '';
  /**
   * 一次性确认凭据（协议 §4.2 下发给加入方，由加入方交回发起方，§4.3 才转 ACTIVE）。
   * 只活在进程里：冷启动回来就没了，那时这一侧只剩「检查配对状态」可点——§4.4 要不要把凭据
   * 回传给发起方，是开闸前必须定的协议修订项（记在批次 U 的欠账里）。
   * 6 位配对码不进二维码，所以没有凭据就没有链接可画，页面退回"突出短码"。
   */
  @State private pairToken: string = '';
  /** 扫码/分享入口由能力探测决定，不在页面里硬编机型。 */
  @State private channels: PairChannels = { scan: false, share: false, emphasizeCode: true };
  // 我的作息参数
  @State private myEditing: boolean = false;
  @State private advanced: boolean = false;
  @State private myWake: string = '07:00';
  @State private myBed: string = '22:30';
  @State private myWind: string = '20';
  // 回填前的占位值：loadMyRhythm() 落地之前输入框念的是出厂默认，所以这个数必须跟着 domain 的
  // 那一家走，不能自己抄一份 '120'（D-63：这一份是默认天数的第三份抄写）。
  @State private myHorizon: string = '' + HORIZON_DEFAULT_DAYS;
  @State private myMinSlot: number = 120;
  @State private clearing: boolean = false;
  /** 下拉刷新的转圈：重算（含向云上要一次对方快照）落地后才收。 */
  @State private refreshing: boolean = false;
  /** 《隐私政策》全文半模态（与首启弹窗同一个组件，随包出厂、离线可读）。 */
  @State private policyOpen: boolean = false;
  /** 本页容器宽度档位：expanded 把卡片区并成两列，其余档位与改造前一致。 */
  @State private bp: Breakpoint = Breakpoint.COMPACT;
  // 装饰器实参必须是字面量，取值与 SENIOR_MODE_KEY 保持一致。
  @StorageProp('crd_senior_mode') senior: boolean = false;
  // 保存动作 → 重算广播：伴侣侧数据或参数变了，摘要文案要跟着走
  @StorageProp('recomputeCount') @Watch('onRecomputeChanged') recomputeCount: number = 0;
  // 一次性配对请求到达（扫到的或从配对链接拉起本机的）：确认页在这页弹
  @StorageProp('pairOfferCount') @Watch('onPairOffer') pairOfferCount: number = 0;

  aboutToAppear(): void {
    this.reload();
    // 深链可能比本页早到：请求由网关暂存，挂载后补取一次，不丢冷启动的那一条
    this.takePendingOffer();
  }

  onRecomputeChanged(): void {
    this.reload();
  }

  /** 下拉刷新：重算一遍视界（已配对时顺带拉对方最新快照），本页摘要跟着重读广播走。 */
  private async onRefresh(): Promise<void> {
    await syncOnPull();
    this.refreshing = false;
  }

  onPairOffer(): void {
    this.takePendingOffer();
  }

  takePendingOffer(): void {
    const offer: PairOffer | null = PairingShareGateway.peekOffer();
    if (offer !== null) {
      this.confirmPair(offer);
    }
  }

  /** 二维码/分享链接的唯一内容源：没有一次性凭据就没有链接。 */
  pairLink(): string {
    return PairLink.build(this.pairToken, 0);
  }

  // ---------- 扫码 / 分享 / 确认（Task 4.1：能力探测 + 不自动绑定） ----------

  startPairScan(): void {
    if (this.pairingBusy) {
      return;
    }
    this.pairingBusy = true;
    PairingShareGateway.offerFromScan().then((res: ScanResult) => {
      this.pairingBusy = false;
      if (res.outcome === ScanOutcome.OFFER && res.offer !== null) {
        this.confirmPair(res.offer);
        return;
      }
      if (res.message !== '') {
        appToast(res.message);
      }
    });
  }

  sharePairLink(): void {
    PairingShareGateway.shareLink(this.pairLink()).then((res: PairOpResult) => {
      appToast(res.message);
    });
  }

  copyPairCode(): void {
    if (this.myCode === '') {
      appToast('还没有配对码，先点「生成邀请码」');
      return;
    }
    PairingShareGateway.copyText(this.myCode).then((res: PairOpResult) => {
      appToast(res.message);
    });
  }

  /**
   * 确认页：点开链接不直接绑，先让用户看清"这是谁的哪一次请求"（协议 §4.3 由发起方按确认）。
   * token 只露首尾，整条凭据不进屏幕文本、不进日志。
   */
  confirmPair(offer: PairOffer): void {
    askConfirm(this.getUIContext(), {
      title: '确认配对请求',
      message: 'TA 已经输入你的配对码（确认号 ' + PairLink.mask(offer.token)
        + '）。你确认后两边才开始同步。',
      cancelText: '忽略',
      confirmText: '确认配对',
      onCancel: () => {
        PairingShareGateway.ignoreOffer();
      },
      onConfirm: () => this.acceptPairOffer()
    });
  }

  acceptPairOffer(): void {
    PairingShareGateway.acceptOffer().then((res: PairOpResult) => {
      appToast(res.message);
    });
  }

  reload(): void {
    this.shareLevel = ProfileSettingsService.getShareLevel();
    this.pairState = ProfileSettingsService.getPairState();
    this.syncState = ProfileSettingsService.getCloudSyncState();
    this.pairToken = ProfileSettingsService.getOutboundToken();
    this.channels = PairingShareGateway.channels();
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
      return FeatureFlags.cloudPairing ? '已配对' : '已标记配对';
    }
    if (this.pairState === PAIR_WAITING) {
      return '等待 TA 输码';
    }
    if (this.pairState === PAIR_PENDING) {
      return '等待确认';
    }
    return '未配对';
  }

  /** 「已配对」不许说成"正在同步"：云端开关关着时它只是本机状态（验收清单 §9.5 的偏离口径）。 */
  pairedNote(): string {
    if (FeatureFlags.cloudPairing) {
      return '已配对：班表改动会按你选的共享等级加密同步给 TA。';
    }
    return '云端还没开通，TA 的班表不会自动同步。想现在就算，用上方「伴侣（本机代录）」。';
  }

  /**
   * 云同步现在是不是坏消息（待重试 / 已停止）。「已同步」与从未试过都不算。
   * 两处读它：身份卡那一行与配对卡里的提示条——同一件事不能在页上两种说法。
   * 判据本身在 `syncTroubleOf`，首页与共同时间页用的是同一条，这里只加本页的两道闸。
   * 关闭态一律不出：那一档压根没有同步通路，`pairedNote()` 已经说了"云端未开通"，
   * 而偏好里残留的降级结论讲的是上一版开通时的事，挂出来只会让页上同时存在两种说法。
   */
  syncTrouble(): boolean {
    return FeatureFlags.cloudPairing && syncTroubleOf(this.syncState);
  }

  /**
   * 等待态的一句现况：这一侧到底在等什么，只由"手上有什么"决定——
   * 有确认凭据说明本机是加入方（要把链接交回去），只有短码说明本机是发起方（还在等对方输码）。
   * 不另存"我是发起方还是加入方"这一位：云端 §4.4 认得成员表，本机跟着它给的进度说就够了。
   */
  waitingNote(): string {
    if (this.pairLink() !== '') {
      return '把这条链接发给 TA：TA 点开后按「确认配对」，两边才开始同步。';
    }
    if (this.pairState === PAIR_PENDING) {
      return '还差 TA 点一次确认。没收到链接就请 TA 重新分享一次。';
    }
    return 'TA 输完配对码不会自动往下走，点「检查配对状态」同步一次进度。';
  }

  /**
   * 配对码的朗读文案：逐位分开报，避免 "384106" 被读成一个数值。
   * 只处理自己生成的 6 位短码，不含任何长期凭据。
   */
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
        // 输码不等于配对：协议 §4.2 之后还要 §4.3，本机先落在"等待确认"
        this.pairState = PAIR_PENDING;
        this.pairToken = ProfileSettingsService.getOutboundToken();
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
      this.pairToken = ProfileSettingsService.getOutboundToken();
      appToast(res.message);
    });
  }

  /** 取消等待中的配对（只清配对标记，不动本机代录数据）。 */
  cancelWaiting(): void {
    ProfileSettingsService.cancelWaiting().then(() => {
      this.pairState = PAIR_NONE;
      this.myCode = '';
    });
  }

  /**
   * 解除配对（二次确认）：云端删成功才清本机标记（协议 §4.5 批次 U·U5）。
   *
   * 确认框里要把"这一步要联网、云上那份是硬删除"说在操作现场：过去这里只说"不再同步"，
   * 而云端删失败时又照清本机标记，用户读到的是"已解除配对"，看到的却是一份永远删不掉的密文。
   */
  askUnpair(): void {
    askConfirm(this.getUIContext(), {
      message: '解除后不再同步 TA 的数据，云上那份加密快照会一起删掉（要联网）。本机代录的内容会留着。',
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
    });
  }

  // ---------- 数据管理 ----------

  /**
   * 清空我的全部数据（二次确认）：先清系统侧投影（受管日程 +「同休日」日历），再删 8 张 RDB 表与全部设置；
   * 隐私同意标记保留（避免重启重复弹窗）。
   *
   * 配着对的时候要在这里额外说一句：清空会把云侧那份快照一起删掉，而这一步删不成本机也照清，
   * 只会留下凭据等下次联网补删（批次 U·U5）——隐私政策里那句"先解除配对"替代不了操作现场的告知。
   */
  askClearAll(): void {
    if (this.clearing) {
      return;
    }
    const paired = FeatureFlags.cloudPairing && this.pairState !== PAIR_NONE;
    askConfirm(this.getUIContext(), {
      title: '清空全部数据',
      message: (paired ? '还在和 TA 配对：云上那份加密快照也一起删，删不成本机也照清，下次联网会再试。\n' : '')
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

  // ---------- 我的作息参数（起床/就寝/收整；视界与最短时段在高级设置） ----------

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
    this.myEditing = true;
  }

  cancelMyEdit(): void {
    this.myEditing = false;
    this.advanced = false;
    this.reloadMyParams();
  }

  /** 解析、校验与重算都在 ProfileSettingsService：就寝早于起床按次日凌晨计入。 */
  saveMyParams(): void {
    const input: MyRhythm = {
      wakeText: this.myWake, bedText: this.myBed, windText: this.myWind,
      horizonText: this.myHorizon, minSlotMin: this.myMinSlot
    };
    ProfileSettingsService.saveMyRhythm(input).then((res: SettingsResult) => {
      appToast(res.message);
      if (!res.ok) {
        return;
      }
      this.myEditing = false;
      this.advanced = false;
      this.reloadMyParams();
    });
  }

  private pickMinSlot(v: number): void {
    if (this.myMinSlot === v) {
      return;
    }
    this.myMinSlot = v;
  }

  private minSlotLabel(v: number): string {
    return '≥ ' + (v % 60 === 0 ? '' + (v / 60) + ' 小时' : v + ' 分钟');
  }

  // ---------- 身份卡文案 ----------

  private identityTitle(): string {
    if (this.partnerExists) {
      return '我 & ' + this.pNick;
    }
    if (this.pairState === PAIRED) {
      return '我 & TA';
    }
    return '我（单人模式）';
  }

  private identitySub(): string {
    if (this.pairState === PAIR_WAITING) {
      return '等待 TA 输入配对码';
    }
    if (this.pairState === PAIR_PENDING) {
      return '已加入 · 还差 TA 确认，尚未同步';
    }
    if (this.pairState === PAIRED) {
      if (!FeatureFlags.cloudPairing) {
        return '本机标记已配对 · 云端未开通，未同步';
      }
      // 同步已经死了还在顶上那一行写"加密同步"，就是协议 §8 明令禁止的那种假态；
      // 三态的名字在这里念一次，配对卡里的提示条才是同一句话的展开。
      if (this.syncTrouble()) {
        return '已配对 · ' + syncStateTitleOf(this.syncState);
      }
      return '已配对 · 按' + this.levelTitle(this.shareLevel) + '加密同步';
    }
    if (this.partnerExists) {
      return '本机代录 · 数据只写在本机的应用沙箱里';
    }
    return '数据只写在本机的应用沙箱里 · 单人模式只算我的空闲';
  }

  // ---------- 隐私共享等级（L1/L2/L3 切换 + 持久化） ----------

  /** 各等级 TA 能看到多少。 */
  levelDesc(level: number): string {
    if (level === 1) {
      return 'TA 只看得到你有空还是在忙，看不到原因和具体时间';
    }
    if (level === 2) {
      return 'TA 看得到你在做什么（比如上课、上班），看不到几点到几点';
    }
    return 'TA 看得到你完整的忙碌时段，共同时间算得最准';
  }

  levelTitle(level: number): string {
    if (level === 1) {
      return 'L1 忙闲状态';
    }
    if (level === 2) {
      return 'L2 班次类型';
    }
    return 'L3 完整时间';
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
      Refresh({ refreshing: $$this.refreshing, offset: 64, friction: 10 }) {
        Scroll() {
          if (Breakpoints.isExpanded(this.bp)) {
            // 宽屏两列：伴侣/日程一列，作息/数据一列，读屏顺序仍是先左后右自上而下
            Row({ space: DesignTokens.space4 }) {
              Column({ space: DesignTokens.space3 }) {
                this.identityCard()
                this.partnerSyncCard()
                this.scheduleCard()
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Column({ space: DesignTokens.space3 }) {
                this.rhythmCard()
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
              this.partnerSyncCard()
              this.scheduleCard()
              this.rhythmCard()
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
      }
      .onRefreshing(() => {
        this.onRefresh();
      })
      .width('100%')
      .height('100%')
      // 页面底画在 Refresh 上而不是 Scroll 上：下拉时 Scroll 整体平移，底跟着走会露出一条空白
      .linearGradient(DesignTokens.pageGradient())
    }
  }

  /** 留白在滚动内容上而不是 Scroll 上：底部留白要跟着内容一起滚，不占死视口。 */
  private contentPadding(): Padding {
    const h: number = Breakpoints.hPadding(this.bp);
    return { left: h, right: h, top: DesignTokens.space5, bottom: DesignTokens.dockClearance };
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
          .fontColor(DesignTokens.primary)
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
          // 「我」字徽标只是装饰，标题文案已经说明了同一件事。no 挂在 Text 自己身上才摘得掉——
          // 挂在外层 Column 上只摘容器，这枚字照样进读屏树（D-29）
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
          Text(this.identitySub())
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.heroText)
            .opacity(0.82)
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

  /**
   * 伴侣与同步：本机代录（离线，无需第二个账号）与云端配对（两台手机）并列，
   * 代录是保底路径，配对未开通时不影响它。
   */
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
            .fontColor(this.pairState === PAIRED ? DesignTokens.primary : DesignTokens.textTertiary)
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
      Text('伴侣（本机代录）')
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
              Text('收整(分)').fontSize(DesignTokens.fontCaption)
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

          Text('时间按 HH:MM 填。TA 的作息单独参与计算，就寝早于起床就算第二天。')
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
        Text('还没有伴侣。添加后就能替 TA 在这台手机上记班表和课表，一起算共同时间。')
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textSecondary)
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
            Text('起床 ' + this.pWake + ' · 就寝 ' + this.pBed + ' · 收整 ' + this.pWind + ' 分钟')
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
            .fontColor(DesignTokens.primary)
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
      Text('两台手机配对同步')
        .fontSize(DesignTokens.fontCaption)
        .fontColor(DesignTokens.textTertiary)

      if (!FeatureFlags.cloudPairing) {
        // 关闭态一格云入口都不摆（阶段 6R.2，验收报告 B1）：没有生成邀请码、没有输码、没有扫码、
        // 没有二维码也没有分享。真正的拒绝在 ProfileSettingsService 那一层，这里只是不给人试探的机会。
        Text(FeatureFlags.cloudClosedMessage)
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textSecondary)
        Text('想现在就算，请用上方「伴侣（本机代录）」。')
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textHint)
        // 退出通道留着：上一版原型可能在单机上留下 WAITING/PENDING/PAIRED 标记，藏了入口就不能再撤了
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
        // 三态里唯一的坏消息出口（协议 §3.4 末行）：待重试用警示色 ↻，已停止用错误色 !。
        // 刻意不给「立即重试」这颗按钮：§3.3 明写端侧没有自动退避重试，手动重试也不在 §7 的触发时机里，
        // 给了等于让用户自己按一次就烧一次免费档的按天配额。
        // 两种结论走 if / else if 两个分支而不是同一个节点：门槛与句子一一对得上，读页面的人不用推。
        // （句子本身跟着状态换是靠 NoticeBar 的说法字段是 @Prop——普通成员只在构造时赋值一次，
        //  同格里换个 code 就换不了那一句，见 D-46。）
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
        Button('解除配对')
          .width('100%')
          .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
          .backgroundColor(DesignTokens.fillWeak)
          .fontWeight(FontWeight.Bold)
          .shadow(DesignTokens.jelly(DesignTokens.borderWeak, DesignTokens.jellyDepth))
          .fontColor(DesignTokens.danger)
          .onClick(() => this.askUnpair())
      } else if (this.pairState === PAIR_WAITING || this.pairState === PAIR_PENDING) {
        if (this.pairLink() !== '') {
          // 二维码只画一次性链接：黑白固定对比色，不随深浅色反转，保证扫码可读
          Row() {
            QRCode(this.pairLink())
              .width(128)
              .height(128)
              .color('#1A1A1A')
              .backgroundColor('#FFFFFF')
              .padding(10)
              .borderRadius(8)
              // 读屏用户扫不到屏上的码，这里把替代路径说出来
              .accessibilityText('配对二维码。扫不了就改用配对码或分享链接')
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)

          Text('把这条链接发给 TA：TA 点开后按「确认配对」，两边才开始同步。')
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.textHint)
            .textAlign(TextAlign.Center)
            .width('100%')
          Button('分享配对链接')
            .width('100%')
            .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .backgroundColor(DesignTokens.primary)
            .fontWeight(FontWeight.Bold)
            .shadow(DesignTokens.jelly(DesignTokens.primaryDeep, DesignTokens.jellyDepth))
            .onClick(() => this.sharePairLink())
        } else if (this.myCode !== '') {
          // 没有一次性凭据就没有二维码可画：6 位短码抬成主路径（Task 4.1「不支持时突出短码」）
          Text(this.myCode)
            .fontSize(34)
            .fontWeight(FontWeight.Bold)
            .fontColor(DesignTokens.primary)
            .letterSpacing(6)
            .width('100%')
            .textAlign(TextAlign.Center)
            // 视觉上是"384106"，朗读必须逐位报数，否则会被读成"三十八万四千一百零六"
            .accessibilityText(this.codeRead())
          Text('让 TA 在「我的 · 伴侣与同步」里输入这 6 位码，之后 TA 会发回一条确认链接。')
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.textHint)
            .textAlign(TextAlign.Center)
            .width('100%')
          Button('复制配对码')
            .width('100%')
            .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .backgroundColor(DesignTokens.fillWeak)
            .fontWeight(FontWeight.Bold)
            .shadow(DesignTokens.jelly(DesignTokens.borderWeak, DesignTokens.jellyDepth))
            .fontColor(DesignTokens.textSecondary)
            .onClick(() => this.copyPairCode())
        } else {
          Text(this.pairState === PAIR_PENDING
            ? '这台手机重启过，确认信息丢了：让 TA 再发一次，或点「检查配对状态」。'
            : '配对码已经生成，但这次没显示出来。TA 没收到的话可以重新生成。')
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.textHint)
        }
        Row({ space: DesignTokens.space3 }) {
          Button(this.pairingBusy ? '检查中…' : '检查配对状态').layoutWeight(1)
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

        // 这条按钮从前叫「本机标记已配对」，点了就把本机写成已配对——云端还停在 WAITING，
        // 界面上"正在同步"就是句谎话（协议 §8 记的偏离）。现在它只查一次 §4.4，进度跟着云端走。
        Text(this.waitingNote())
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textHint)
      } else {
        Text('一台手机生成 6 位配对码，另一台输入，之后按你选的等级加密同步。')
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textSecondary)
        Row({ space: DesignTokens.space3 }) {
          Button(this.pairingBusy ? '生成中…' : '生成邀请码').layoutWeight(1)
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

        if (this.channels.scan) {
          Button(this.pairingBusy ? '扫码中…' : '扫码配对')
            .width('100%')
            .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .backgroundColor(DesignTokens.fillWeak)
            .fontWeight(FontWeight.Bold)
            .shadow(DesignTokens.jelly(DesignTokens.borderWeak, DesignTokens.jellyDepth))
            .fontColor(DesignTokens.primary)
            .enabled(!this.pairingBusy)
            .onClick(() => this.startPairScan())
        }

        if (this.channels.emphasizeCode) {
          Text('这台手机不能扫码，让 TA 手动输入 6 位配对码。')
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.textHint)
        }

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

        Text('配对同步需要云服务能力。没开通时这里只会提示改用本机代录，不影响上面的功能。')
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textHint)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  levelBlock() {
    Column({ space: DesignTokens.space2 }) {
      Text('共享等级（配对后 TA 能看到多少）')
        .fontSize(DesignTokens.fontCaption)
        .fontColor(DesignTokens.textTertiary)
      ForEach([1, 2, 3], (lv: number) => {
        Row({ space: DesignTokens.space3 }) {
          Radio({ value: '' + lv, group: 'shareLevel' })
            .checked(this.shareLevel === lv)
            .accessibilityText(this.levelTitle(lv))
            .onChange((checked: boolean) => {
              if (checked) {
                this.pickLevel(lv);
              }
            })
          Column({ space: 2 }) {
            Row({ space: DesignTokens.space1 }) {
              Text(this.levelTitle(lv))
                .fontSize(DesignTokens.fontBody)
                .fontColor(this.shareLevel === lv ? DesignTokens.primary : DesignTokens.textPrimary)
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
              .fontColor(DesignTokens.textTertiary)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding(DesignTokens.space2)
        // 整行可点，热区跟着走；朗读入口留给行内的 Radio（它自带选中态），
        // 行本身不再 focusable，否则同一档会出现两个焦点。
        .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
        .borderRadius(DesignTokens.radiusCard)
        .backgroundColor(this.shareLevel === lv ? DesignTokens.primaryBg : Color.Transparent)
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

        this.navRow($r('sys.symbol.calendar'), '班表与班次',
          '循环模板、单日改班、课程、上下班时间与通勤', false, () => {
            this.onOpenRoute(NavRoutes.SCHEDULE_HUB, ownerParam(OWNER_ME));
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 作息：三个主参数常驻，视界与最短共同时段收进高级设置。 */
  @Builder
  rhythmCard() {
    EditorialCard({ hero: false, cutTopLeft: true, tappable: false }) {
      Column({ space: DesignTokens.space3 }) {
        this.cardHead({ title: '作息', action: this.myEditing ? '' : '编辑', onAction: () => this.startEditMyParams() })

        if (this.myEditing) {
          // 与 partnerBlock 同一口径：单行钉死宽度在 2 倍字号下会横向溢出，三对各自成组后换行
          Flex({ wrap: FlexWrap.Wrap }) {
            Row({ space: DesignTokens.space2 }) {
              Text('起床').fontSize(DesignTokens.fontCaption)
              TextInput({ text: this.myWake })
                .constraintSize({ minWidth: 64, minHeight: DesignTokens.hitMin })
                .fontSize(DesignTokens.fontCaption)
                .borderRadius(DesignTokens.radiusInput)
                .border({ width: 1.5, color: DesignTokens.primaryBorder })
                .backgroundColor(DesignTokens.card)
                .accessibilityText('我的起床时间，格式 HH:MM')
                .onChange((v: string) => this.myWake = v)
            }
            .margin({ right: DesignTokens.space2, bottom: DesignTokens.space2 })
            .accessibilityGroup(true)

            Row({ space: DesignTokens.space2 }) {
              Text('就寝').fontSize(DesignTokens.fontCaption)
              TextInput({ text: this.myBed })
                .constraintSize({ minWidth: 64, minHeight: DesignTokens.hitMin })
                .fontSize(DesignTokens.fontCaption)
                .borderRadius(DesignTokens.radiusInput)
                .border({ width: 1.5, color: DesignTokens.primaryBorder })
                .backgroundColor(DesignTokens.card)
                .accessibilityText('我的就寝时间，格式 HH:MM')
                .onChange((v: string) => this.myBed = v)
            }
            .margin({ right: DesignTokens.space2, bottom: DesignTokens.space2 })
            .accessibilityGroup(true)

            Row({ space: DesignTokens.space2 }) {
              Text('收整(分)').fontSize(DesignTokens.fontCaption)
              TextInput({ text: this.myWind })
                .constraintSize({ minWidth: 56, minHeight: DesignTokens.hitMin })
                .type(InputType.Number)
                .fontSize(DesignTokens.fontCaption)
                .borderRadius(DesignTokens.radiusInput)
                .border({ width: 1.5, color: DesignTokens.primaryBorder })
                .backgroundColor(DesignTokens.card)
                .accessibilityText('我的收整时长，单位分钟')
                .onChange((v: string) => this.myWind = v)
            }
            .margin({ right: DesignTokens.space2, bottom: DesignTokens.space2 })
            .accessibilityGroup(true)
          }
          .width('100%')

          this.advancedHead()
          if (this.advanced) {
            this.advancedForm()
          }

          Row({ space: DesignTokens.space3 }) {
            Button('保存').layoutWeight(1)
              .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
              .backgroundColor(DesignTokens.primary)
              .fontWeight(FontWeight.Bold)
              .shadow(DesignTokens.jelly(DesignTokens.primaryDeep, DesignTokens.jellyDepth))
              .onClick(() => this.saveMyParams())
            Button('取消').layoutWeight(1)
              .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
              .backgroundColor(DesignTokens.fillWeak)
              .fontColor(DesignTokens.textSecondary)
              .onClick(() => this.cancelMyEdit())
          }.width('100%')
        } else {
          Row() {
            this.paramStat({ value: this.myWake, label: '起床' })
            this.paramStat({ value: this.myBed, label: '就寝' })
            this.paramStat({ value: this.myWind + '分', label: '收整' })
          }.width('100%')

          if (this.bedNote(this.myWake, this.myBed) !== '') {
            Text(this.bedNote(this.myWake, this.myBed))
              .fontSize(DesignTokens.fontCaption)
              .fontColor(DesignTokens.textSecondary)
          }

          Text('改完就会重新计算共同时间。')
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.textHint)

          this.advancedHead()
          if (this.advanced) {
            Text('往后算 ' + this.myHorizon + ' 天 · 最短共同时段 ' + this.minSlotLabel(this.myMinSlot))
              .fontSize(DesignTokens.fontCaption)
              .fontColor(DesignTokens.textSecondary)
            Text('夜班窗口等其他判定都用默认值，不用管。')
              .fontSize(DesignTokens.fontCaption)
              .fontColor(DesignTokens.textHint)
          }
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  paramStat(row: ParamStatArg) {
    Column({ space: 2 }) {
      Text(row.value)
        .fontSize(DesignTokens.fontBody)
        .fontFamily(DesignTokens.fontRound)
        .fontWeight(FontWeight.Medium)
        .fontColor(DesignTokens.primary)
      Text(row.label)
        .fontSize(DesignTokens.fontCaption)
        .fontColor(DesignTokens.textTertiary)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    // 数值和标签分两行画，读屏要连成一句"07:30 起床"
    .accessibilityGroup(true)
    .accessibilityText(row.value + ' ' + row.label)
  }

  @Builder
  advancedHead() {
    Row({ space: DesignTokens.space1 }) {
      Text('高级设置（算多少天 / 最短时段）')
        .fontSize(DesignTokens.fontCaption)
        .fontColor(DesignTokens.textSecondary)
        .layoutWeight(1)
      SymbolGlyph(this.advanced ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
        .fontSize(14).fontColor([DesignTokens.textTertiary])
        .accessibilityLevel('no')
    }
    .width('100%')
    .padding({ top: DesignTokens.space2, bottom: DesignTokens.space2 })
    .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
    .focusable(true)
    .accessibilityGroup(true)
    .accessibilityText('高级设置（算多少天 / 最短时段），' + (this.advanced ? '已展开' : '已收起'))
    .onClick(() => {
      this.advanced = !this.advanced;
    })
  }

  @Builder
  advancedForm() {
    Column({ space: DesignTokens.space2 }) {
      Row({ space: DesignTokens.space2 }) {
        Text('往后算多少天').fontSize(DesignTokens.fontCaption)
        TextInput({ text: this.myHorizon })
          .constraintSize({ minWidth: 64, minHeight: DesignTokens.hitMin })
          .type(InputType.Number)
          .fontSize(DesignTokens.fontCaption)
          .borderRadius(DesignTokens.radiusInput)
          .border({ width: 1.5, color: DesignTokens.primaryBorder })
          .backgroundColor(DesignTokens.card)
          .accessibilityText('往后算多少天，可以填 ' + HORIZON_MIN + ' 到 ' + HORIZON_MAX)
          .onChange((v: string) => this.myHorizon = v)
        Text(HORIZON_MIN + '–' + HORIZON_MAX + ' 天')
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textHint)
      }.width('100%')

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(MIN_SLOT_STEPS, (v: number) => {
          Text(this.minSlotLabel(v))
            .fontSize(DesignTokens.fontCaption)
            .fontColor(this.myMinSlot === v ? DesignTokens.heroText : DesignTokens.textSecondary)
            .fontWeight(FontWeight.Bold)
            .textAlign(TextAlign.Center)
            .padding({ left: DesignTokens.space3, right: DesignTokens.space3 })
            .margin({ right: DesignTokens.space2, bottom: DesignTokens.space2 })
            .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .borderRadius(DesignTokens.radiusPill)
            .backgroundColor(this.myMinSlot === v ? DesignTokens.primary : DesignTokens.fillWeakest)
            .shadow(this.myMinSlot === v
              ? DesignTokens.jelly(DesignTokens.primaryDeep, DesignTokens.jellyDepthChip) : undefined)
            .focusable(true)
            .accessibilityText(this.minSlotLabel(v) + (this.myMinSlot === v ? '，当前档位' : '，点按设为最短共同时段'))
            .clickEffect(DesignTokens.tapChip())
            .onClick(() => this.pickMinSlot(v))
        }, (v: number) => 'ms' + v)
      }
      .width('100%')

      Text('比这更短的空闲会直接忽略，不算成一个窗口。')
        .fontSize(DesignTokens.fontCaption)
        .fontColor(DesignTokens.textHint)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  dataCard() {
    EditorialCard({ hero: false, cutTopLeft: false, tappable: false }) {
      Column({ space: DesignTokens.space2 }) {
        this.cardHead({ title: '数据与隐私', action: '', onAction: () => {} })

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
      .bindSheet($$this.policyOpen, this.policySheet(), {
        detents: [SheetSize.LARGE],
        dragBar: false,
        showClose: false,
        // 底色/圆角由 PrivacyPolicySheet 自己画，系统层再铺一次就是两层不透明背景
        backgroundColor: Color.Transparent,
        blurStyle: BlurStyle.NONE,
        maskColor: DesignTokens.scrim
      })
    }
  }

  /** 《隐私政策》全文（与首启弹窗同一个组件、同一份文本）。 */
  @Builder
  policySheet() {
    PrivacyPolicySheet({ onClose: () => {
      this.policyOpen = false;
    } })
  }
}
