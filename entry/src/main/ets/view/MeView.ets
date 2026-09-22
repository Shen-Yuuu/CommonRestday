import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { OWNER_ME, OWNER_PARTNER, PairLink, PairOffer } from 'domain';
import { PAIRED, PAIR_NONE, PAIR_WAITING } from 'data';
import {
  FeatureFlags, InviteResult, isCrossMidnight, MyRhythm, PairChannels, PairingShareGateway,
  PairOpResult, PartnerInput, ProfileSettingsService, ScanOutcome, ScanResult, SettingsResult
} from 'feature';
import { openPrivacyPolicy } from '../util/PrivacyUtil';
import { DesignTokens } from '../theme/DesignTokens';
import { NavRoutes } from '../navigation/NavRoutes';
import { ownerParam } from '../model/RouteParams';
import { EditorialCard } from '../component/EditorialCard';

/** 最短共同时段的常用档：碎片小于 1 小时几乎安排不了事，大于 4 小时又太难得。 */
const MIN_SLOT_STEPS: number[] = [60, 120, 240];

/**
 * 我的页：四段收纳——伴侣与同步、我的日程、作息、数据与隐私。
 * - 作息只摆起床/就寝/收整三个主参数，视界与最短共同时段收进「高级设置」；
 * - 班表录入不再是底部 Tab，这里给直达入口（我这侧 / 代录 TA 那侧）；
 * - 云端配对未开通时全程降级提示，本机代录照常可用。
 */
@Component
export struct MeView {
  /** 打开路由（班表页并指定录哪一侧），由 AppNavigator 注入：路由种类只有壳层知道。 */
  onOpenRoute: (name: string, params?: Object) => void = (name: string, params?: Object) => {
  };
  @State private shareLevel: number = 2;
  @State private pairState: string = PAIR_NONE;
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
   * 服务端签发的一次性配对凭据。门禁（Task 0.4 = CLOUD_BLOCKED）解除前恒为空——
   * 6 位配对码不进二维码，所以没有 token 就没有二维码可画，页面退回"突出短码"。
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
  @State private myHorizon: string = '120';
  @State private myMinSlot: number = 120;
  @State private clearing: boolean = false;
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
        promptAction.showToast({ message: res.message });
      }
    });
  }

  sharePairLink(): void {
    PairingShareGateway.shareLink(this.pairLink()).then((res: PairOpResult) => {
      promptAction.showToast({ message: res.message });
    });
  }

  copyPairCode(): void {
    if (this.myCode === '') {
      promptAction.showToast({ message: '还没有配对码，先点「生成邀请码」' });
      return;
    }
    PairingShareGateway.copyText(this.myCode).then((res: PairOpResult) => {
      promptAction.showToast({ message: res.message });
    });
  }

  /**
   * 确认页：扫到/点开链接都不直接绑，先让用户看清"这是谁的哪一次请求"。
   * token 只露首尾，整条凭据不进屏幕文本、不进日志。
   */
  confirmPair(offer: PairOffer): void {
    this.getUIContext().showAlertDialog({
      title: '确认配对请求',
      message: '收到一次性配对凭据 ' + PairLink.mask(offer.token)
        + '。接受后由云端确认，本应用不会自动绑定。',
      primaryButton: {
        value: '忽略',
        fontColor: DesignTokens.textSecondary,
        action: () => {
          PairingShareGateway.ignoreOffer();
        }
      },
      secondaryButton: {
        value: '接受',
        fontColor: DesignTokens.primary,
        action: () => this.acceptPairOffer()
      }
    });
  }

  acceptPairOffer(): void {
    PairingShareGateway.acceptOffer().then((res: PairOpResult) => {
      promptAction.showToast({ message: res.message });
    });
  }

  reload(): void {
    this.shareLevel = ProfileSettingsService.getShareLevel();
    this.pairState = ProfileSettingsService.getPairState();
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
      promptAction.showToast({ message: res.message });
      if (res.ok) {
        this.partnerEditing = false;
        this.reloadPartner();
      }
    });
  }

  confirmDeletePartner(): void {
    this.getUIContext().showAlertDialog({
      title: '删除伴侣档案',
      message: '将同时清除 TA 的全部班表/课表数据，并回退到单人模式。确定删除？',
      primaryButton: {
        value: '删除',
        action: () => this.doDeletePartner()
      },
      secondaryButton: {
        value: '取消',
        action: () => {
        }
      }
    });
  }

  doDeletePartner(): void {
    ProfileSettingsService.deletePartner().then((res: SettingsResult) => {
      promptAction.showToast({ message: res.message });
      if (res.ok) {
        this.partnerEditing = false;
        this.reloadPartner();
      }
    });
  }

  /** 跨零点作息要说成人话，否则"就寝 01:00"看着像漏填。 */
  private bedNote(wakeStr: string, bedStr: string): string {
    return isCrossMidnight(wakeStr, bedStr) ? '就寝已过零点，按次日凌晨计入' : '';
  }

  // ---------- 云端配对（US9 / FR-015：AGC 未就绪时全程降级提示，不影响本机代录） ----------

  pairStateText(): string {
    if (this.pairState === PAIRED) {
      return FeatureFlags.cloudPairing ? '已配对' : '已标记配对';
    }
    if (this.pairState === PAIR_WAITING) {
      return '等待对方输码';
    }
    return '未配对';
  }

  /** 「已配对」不许说成"正在同步"：云端开关关着时它只是本机状态（验收清单 §9.5 的偏离口径）。 */
  pairedNote(): string {
    if (FeatureFlags.cloudPairing) {
      return '已与另一台设备配对：班表变更会按你的隐私等级加密后同步给 TA。';
    }
    return '本机已标记为已配对，但云端未开通：TA 的班表不会自动同步。'
      + '现在就要共同时间，请用上方「伴侣（本机代录）」。';
  }

  /** 生成邀请码（创建方）：云函数调用与配对标记读写都在 feature，这里只管按钮态与展示。 */
  createInvite(): void {
    if (this.pairingBusy) {
      return;
    }
    this.pairingBusy = true;
    ProfileSettingsService.createInvite().then((res: InviteResult) => {
      this.pairingBusy = false;
      promptAction.showToast({ message: res.message });
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
      promptAction.showToast({ message: res.message });
      if (res.ok) {
        this.pairState = PAIRED;
        this.showJoinInput = false;
        this.joinCode = '';
      }
    });
  }

  /** 创建方确认完成配对（体验版：无服务端推送，对方输码后手动确认）。 */
  markPaired(): void {
    ProfileSettingsService.markPaired().then((res: SettingsResult) => {
      if (res.ok) {
        this.pairState = PAIRED;
      }
      promptAction.showToast({ message: res.message });
    });
  }

  /** 取消等待中的配对（只清配对标记，不动本机代录数据）。 */
  cancelWaiting(): void {
    ProfileSettingsService.cancelWaiting().then(() => {
      this.pairState = PAIR_NONE;
      this.myCode = '';
    });
  }

  /** 解除配对（二次确认）：云端尽力解绑，本地配对标记一律清干净。 */
  askUnpair(): void {
    this.getUIContext().showAlertDialog({
      message: '解除配对后不再同步 TA 的加密快照（本机代录数据不受影响）。确定解除？',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '解除配对',
        fontColor: DesignTokens.danger,
        action: () => this.doUnpair()
      }
    });
  }

  doUnpair(): void {
    ProfileSettingsService.unpair().then((res: SettingsResult) => {
      promptAction.showToast({ message: res.message });
      if (res.ok) {
        this.pairState = PAIR_NONE;
        this.myCode = '';
      }
    });
  }

  // ---------- 数据管理 ----------

  /** 清空我的全部数据（二次确认）：8 张 RDB 表 + 全部设置；隐私同意标记保留（避免重启重复弹窗）。 */
  askClearAll(): void {
    if (this.clearing) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '清空全部数据',
      message: '将删除本机全部班表/课表/计划/窗口/伴侣档案与设置项，且不可恢复。确定清空？',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: DesignTokens.danger,
        action: () => this.doClearAll()
      }
    });
  }

  doClearAll(): void {
    this.clearing = true;
    ProfileSettingsService.clearAllData().then((res: SettingsResult) => {
      this.clearing = false;
      promptAction.showToast({ message: res.message });
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
      promptAction.showToast({ message: res.message });
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
      return '我 & 对方';
    }
    return '我（单人模式）';
  }

  private identitySub(): string {
    if (this.pairState === PAIR_WAITING) {
      return '等待对方输入配对码';
    }
    if (this.pairState === PAIRED) {
      return FeatureFlags.cloudPairing
        ? '已配对 · 按' + this.levelTitle(this.shareLevel) + '加密同步'
        : '本机标记已配对 · 云端未开通，未同步';
    }
    if (this.partnerExists) {
      return '本机代录 · 数据只存在这台手机';
    }
    return '数据只存在这台手机 · 单人模式只算我的空闲';
  }

  // ---------- 隐私共享等级（L1/L2/L3 切换 + 持久化） ----------

  /** 各等级"对方可见内容"对照说明。 */
  levelDesc(level: number): string {
    if (level === 1) {
      return '对方只见你有空/忙碌，看不到原因与具体时间';
    }
    if (level === 2) {
      return '对方可见忙碌类型（如上课/上班），不含精确时段';
    }
    return '对方可见完整忙碌时段，共同时间计算最精准';
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
      promptAction.showToast({
        message: res.ok ? '已切换到' + this.levelTitle(level) + '，重启后仍保持' : res.message
      });
      if (!res.ok) {
        this.shareLevel = ProfileSettingsService.getShareLevel();
      }
    });
  }

  // ---------- 构建 ----------

  build() {
    Scroll() {
      Column({ space: DesignTokens.space3 }) {
        this.identityCard()
        this.partnerSyncCard()
        this.scheduleCard()
        this.rhythmCard()
        this.dataCard()
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: DesignTokens.space5, bottom: DesignTokens.space6 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .backgroundColor(DesignTokens.page)
  }

  /** 卡内小标题：衬线标题 + 可选的右侧操作文字（编辑/收起等）。 */
  @Builder
  cardHead(title: string, action: string, onAction: () => void) {
    Row() {
      Text(title)
        .fontSize(DesignTokens.fontBody)
        .fontFamily(DesignTokens.fontSerif)
        .fontWeight(FontWeight.Medium)
        .fontColor(DesignTokens.textPrimary)
        .letterSpacing(-0.4)
      Blank()
      if (action !== '') {
        Text(action)
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.primary)
          .textAlign(TextAlign.End)
          .padding({ left: DesignTokens.space2, top: DesignTokens.space1, bottom: DesignTokens.space1 })
          .constraintSize({ minHeight: DesignTokens.hitMin })
          .onClick(onAction)
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
    }
    .width('100%')
    .padding(DesignTokens.space2)
    .constraintSize({ minHeight: DesignTokens.hitMin })
    .alignItems(VerticalAlign.Center)
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
            .fontFamily(DesignTokens.fontSerif)
            .fontWeight(FontWeight.Medium)
            .fontColor(DesignTokens.heroText)
        }
        .width(44)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .borderRadius(DesignTokens.radiusPill)
        .backgroundColor(DesignTokens.heroGlow)

        Column({ space: 2 }) {
          Text(this.identityTitle())
            .fontSize(DesignTokens.fontTitle)
            .fontFamily(DesignTokens.fontSerif)
            .fontWeight(FontWeight.Medium)
            .fontColor(DesignTokens.heroText)
            .letterSpacing(-0.9)
          Text(this.identitySub())
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.heroText)
            .opacity(0.82)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        SymbolGlyph($r('sys.symbol.heart'))
          .fontSize(22)
          .fontColor([DesignTokens.heroGlow])
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
            .fontFamily(DesignTokens.fontSerif)
            .fontWeight(FontWeight.Medium)
            .fontColor(DesignTokens.textPrimary)
            .letterSpacing(-0.4)
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

        this.divider()

        this.levelBlock()
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
              .layoutWeight(1).height(38)
              .fontSize(DesignTokens.fontCaption)
              .onChange((v: string) => this.pNick = v)
          }.width('100%')

          Row({ space: DesignTokens.space2 }) {
            Text('起床').fontSize(DesignTokens.fontCaption)
            TextInput({ text: this.pWake }).width(64).height(38)
              .fontSize(DesignTokens.fontCaption)
              .onChange((v: string) => this.pWake = v)
            Text('就寝').fontSize(DesignTokens.fontCaption)
            TextInput({ text: this.pBed }).width(64).height(38)
              .fontSize(DesignTokens.fontCaption)
              .onChange((v: string) => this.pBed = v)
            Text('收整(分)').fontSize(DesignTokens.fontCaption)
            TextInput({ text: this.pWind }).width(56).height(38)
              .type(InputType.Number)
              .fontSize(DesignTokens.fontCaption)
              .onChange((v: string) => this.pWind = v)
          }.width('100%')

          Text('作息格式 HH:MM。TA 的起床/就寝/收整独立参与计算；就寝早于起床即次日凌晨睡。')
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.textHint)
          Row({ space: DesignTokens.space3 }) {
            Button('保存').layoutWeight(1).backgroundColor(DesignTokens.primary)
              .onClick(() => this.savePartner())
            Button('取消').layoutWeight(1).backgroundColor(DesignTokens.fillWeak)
              .fontColor(DesignTokens.textSecondary)
              .onClick(() => this.cancelPartnerEdit())
          }.width('100%')
        }
        .width('100%')
      } else if (!this.partnerExists) {
        Text('还没有伴侣。添加后就能在这台手机上代录 TA 的课表/班表，自动算出你们的共同时间。')
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textSecondary)
        Button('添加伴侣（本机代录）')
          .width('100%')
          .backgroundColor(DesignTokens.primary)
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
            .onClick(() => this.startEditPartner())
          Text('删除')
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.danger)
            .padding(DesignTokens.space2)
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

      if (this.pairState === PAIRED) {
        Text(this.pairedNote())
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textSecondary)
        Button('解除配对')
          .width('100%')
          .backgroundColor(DesignTokens.fillWeak)
          .fontColor(DesignTokens.danger)
          .onClick(() => this.askUnpair())
      } else if (this.pairState === PAIR_WAITING) {
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
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)

          Text('让对方点「扫码配对」对准这个二维码，或直接把链接分享过去。')
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.textHint)
            .textAlign(TextAlign.Center)
            .width('100%')
          Button('分享配对链接')
            .width('100%')
            .backgroundColor(DesignTokens.primary)
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
          Text('对方在 TA 的「我的 · 伴侣与同步」输入此码即可。'
            + '二维码与分享链接只承载服务端签发的一次性凭据，云端配对开通后自动出现。')
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.textHint)
            .textAlign(TextAlign.Center)
            .width('100%')
          Button('复制配对码')
            .width('100%')
            .backgroundColor(DesignTokens.fillWeak)
            .fontColor(DesignTokens.textSecondary)
            .onClick(() => this.copyPairCode())
        } else {
          Text('配对码已生成（本次进入页面未显示）。如对方未收到，可重新生成。')
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.textHint)
        }
        Row({ space: DesignTokens.space3 }) {
          Button('本机标记已配对').layoutWeight(1)
            .backgroundColor(DesignTokens.primary)
            .onClick(() => this.markPaired())
          Button('取消配对').layoutWeight(1)
            .backgroundColor(DesignTokens.fillWeak)
            .fontColor(DesignTokens.textSecondary)
            .onClick(() => this.cancelWaiting())
        }.width('100%')

        Text('这个按钮只改本机显示：云端未开通时不会有任何数据同步过去。')
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textHint)
      } else {
        Text('一端生成 6 位配对码，另一端输入后按隐私等级加密同步。')
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textSecondary)
        Row({ space: DesignTokens.space3 }) {
          Button(this.pairingBusy ? '生成中…' : '生成邀请码').layoutWeight(1)
            .backgroundColor(DesignTokens.primary)
            .enabled(!this.pairingBusy)
            .onClick(() => this.createInvite())
          Button('输码加入').layoutWeight(1)
            .backgroundColor(DesignTokens.fillWeak)
            .fontColor(DesignTokens.textSecondary)
            .enabled(!this.pairingBusy)
            .onClick(() => {
              this.showJoinInput = !this.showJoinInput;
            })
        }.width('100%')

        if (this.channels.scan) {
          Button(this.pairingBusy ? '扫码中…' : '扫码配对')
            .width('100%')
            .backgroundColor(DesignTokens.fillWeak)
            .fontColor(DesignTokens.primary)
            .enabled(!this.pairingBusy)
            .onClick(() => this.startPairScan())
        }

        if (this.channels.emphasizeCode) {
          Text('这台设备不支持扫码：配对以 6 位短码为准，让对方手动输入。')
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.textHint)
        }

        if (this.showJoinInput) {
          Row({ space: DesignTokens.space2 }) {
            Text('配对码').fontSize(DesignTokens.fontCaption)
            TextInput({ text: this.joinCode, placeholder: '6 位数字' })
              .layoutWeight(1).height(38)
              .type(InputType.Number)
              .maxLength(6)
              .fontSize(DesignTokens.fontCaption)
              .onChange((v: string) => this.joinCode = v)
            Button(this.pairingBusy ? '加入中…' : '加入')
              .backgroundColor(DesignTokens.primary)
              .enabled(!this.pairingBusy)
              .onClick(() => this.joinByCode())
          }.width('100%')
        }

        Text('需开通 AGC 云服务；没开通时这里只会提示改用本机代录，上面的代录照常可用。')
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
      Text('共享等级（配对后对方可见内容）')
        .fontSize(DesignTokens.fontCaption)
        .fontColor(DesignTokens.textTertiary)
      ForEach([1, 2, 3], (lv: number) => {
        Row({ space: DesignTokens.space3 }) {
          Radio({ value: '' + lv, group: 'shareLevel' })
            .checked(this.shareLevel === lv)
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
        .borderRadius(DesignTokens.radiusCard)
        .backgroundColor(this.shareLevel === lv ? DesignTokens.primaryBg : Color.Transparent)
        .onClick(() => this.pickLevel(lv))
      }, (lv: number) => 'lv' + lv)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 我的日程：班表中心（栈目的地）直达，我这侧与代录 TA 那侧分别落对应 owner。 */
  @Builder
  scheduleCard() {
    EditorialCard({ hero: false, cutTopLeft: false, tappable: false }) {
      Column({ space: DesignTokens.space2 }) {
        this.cardHead('我的日程', '', () => {
        })

        this.navRow($r('sys.symbol.calendar'), '班表与班次',
          '循环模板 · 单日改班 · 课程 · 班次时段与通勤', false, () => {
            this.onOpenRoute(NavRoutes.SCHEDULE_HUB, ownerParam(OWNER_ME));
          })

        if (this.partnerExists) {
          this.navRow($r('sys.symbol.person_fill'), '代录 TA 的班表',
            '在这台手机上替 TA 记录，不必装第二份', false, () => {
              this.onOpenRoute(NavRoutes.SCHEDULE_HUB, ownerParam(OWNER_PARTNER));
            })
        }
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
        this.cardHead('作息', this.myEditing ? '' : '编辑', () => this.startEditMyParams())

        if (this.myEditing) {
          Row({ space: DesignTokens.space2 }) {
            Text('起床').fontSize(DesignTokens.fontCaption)
            TextInput({ text: this.myWake }).width(64).height(38)
              .fontSize(DesignTokens.fontCaption)
              .onChange((v: string) => this.myWake = v)
            Text('就寝').fontSize(DesignTokens.fontCaption)
            TextInput({ text: this.myBed }).width(64).height(38)
              .fontSize(DesignTokens.fontCaption)
              .onChange((v: string) => this.myBed = v)
            Text('收整(分)').fontSize(DesignTokens.fontCaption)
            TextInput({ text: this.myWind }).width(56).height(38)
              .type(InputType.Number)
              .fontSize(DesignTokens.fontCaption)
              .onChange((v: string) => this.myWind = v)
          }.width('100%')

          this.advancedHead()
          if (this.advanced) {
            this.advancedForm()
          }

          Row({ space: DesignTokens.space3 }) {
            Button('保存').layoutWeight(1).backgroundColor(DesignTokens.primary)
              .onClick(() => this.saveMyParams())
            Button('取消').layoutWeight(1).backgroundColor(DesignTokens.fillWeak)
              .fontColor(DesignTokens.textSecondary)
              .onClick(() => this.cancelMyEdit())
          }.width('100%')
        } else {
          Row() {
            this.paramStat(this.myWake, '起床')
            this.paramStat(this.myBed, '就寝')
            this.paramStat(this.myWind + '分', '收整')
          }.width('100%')

          if (this.bedNote(this.myWake, this.myBed) !== '') {
            Text(this.bedNote(this.myWake, this.myBed))
              .fontSize(DesignTokens.fontCaption)
              .fontColor(DesignTokens.textSecondary)
          }

          Text('决定你的睡眠与收整如何参与计算，改完立刻重算共同时间。')
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.textHint)

          this.advancedHead()
          if (this.advanced) {
            Text('视界 ' + this.myHorizon + ' 天 · 最短共同时段 ' + this.minSlotLabel(this.myMinSlot))
              .fontSize(DesignTokens.fontCaption)
              .fontColor(DesignTokens.textSecondary)
            Text('其余阈值（夜班窗口、半天/整日/可出行判定）用引擎默认值。')
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
  paramStat(value: string, label: string) {
    Column({ space: 2 }) {
      Text(value)
        .fontSize(DesignTokens.fontBody)
        .fontFamily(DesignTokens.fontSerif)
        .fontWeight(FontWeight.Medium)
        .fontColor(DesignTokens.primary)
      Text(label)
        .fontSize(DesignTokens.fontCaption)
        .fontColor(DesignTokens.textTertiary)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  advancedHead() {
    Row({ space: DesignTokens.space1 }) {
      Text('高级设置（视界 / 最短时段）')
        .fontSize(DesignTokens.fontCaption)
        .fontColor(DesignTokens.textSecondary)
        .layoutWeight(1)
      SymbolGlyph(this.advanced ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
        .fontSize(14).fontColor([DesignTokens.textTertiary])
    }
    .width('100%')
    .padding({ top: DesignTokens.space2, bottom: DesignTokens.space2 })
    .constraintSize({ minHeight: DesignTokens.hitMin })
    .onClick(() => {
      this.advanced = !this.advanced;
    })
  }

  @Builder
  advancedForm() {
    Column({ space: DesignTokens.space2 }) {
      Row({ space: DesignTokens.space2 }) {
        Text('计算视界(天)').fontSize(DesignTokens.fontCaption)
        TextInput({ text: this.myHorizon }).width(64).height(38)
          .type(InputType.Number)
          .fontSize(DesignTokens.fontCaption)
          .onChange((v: string) => this.myHorizon = v)
        Text('未来多少天参与计算（7–366）')
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textHint)
      }.width('100%')

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(MIN_SLOT_STEPS, (v: number) => {
          Text(this.minSlotLabel(v))
            .fontSize(DesignTokens.fontCaption)
            .fontColor(this.myMinSlot === v ? DesignTokens.heroText : DesignTokens.textSecondary)
            .textAlign(TextAlign.Center)
            .padding({ left: DesignTokens.space3, right: DesignTokens.space3 })
            .margin({ right: DesignTokens.space2, bottom: DesignTokens.space2 })
            .constraintSize({ minHeight: DesignTokens.hitMin })
            .borderRadius(DesignTokens.radiusPill)
            .backgroundColor(this.myMinSlot === v ? DesignTokens.primary : DesignTokens.fillWeakest)
            .onClick(() => this.pickMinSlot(v))
        }, (v: number) => 'ms' + v)
      }
      .width('100%')

      Text('短于此段的共同空闲会被直接丢掉，不算成一个窗口。')
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
        this.cardHead('数据与隐私', '', () => {
        })

        this.navRow($r('sys.symbol.checkmark_shield'), '隐私政策', '权限用途与数据去向', false, () => {
          const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
          openPrivacyPolicy(ctx, $r('app.string.privacy_fulltext_soon'));
        })

        this.divider()

        if (this.clearing) {
          this.navRow($r('sys.symbol.trash'), '清空我的全部数据', '正在清空…', true, () => {
          })
        } else {
          this.navRow($r('sys.symbol.trash'), '清空我的全部数据',
            '删除本机全部班表/课表/计划与设置，不可恢复', true, () => this.askClearAll())
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }
}
