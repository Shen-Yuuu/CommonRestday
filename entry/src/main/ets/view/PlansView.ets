import { CommonTimeQueryService, LOCAL_ONLY_NOTE, PlanConflictView, PlanOpResult, PlanSummary,
  PlanUseCase, calendarBadgeOf, canExportToCalendar, canRetryCalendarSync, canRetryCleanup,
  isAppManagedEvent, isOnSystemCalendar, planKindLabel } from 'feature';
import { DateLabel } from 'commons';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';
import { SleepBunny } from '../component/StatePanel';
import { DesignTokens } from '../theme/DesignTokens';
import { appToast } from '../util/AppToast';
import { askConfirm } from '../util/AppConfirm';
import { syncOnPull } from '../util/PullRefresh';

/** 主句 + 系统侧残留说明：note 为空时只报主句，不 trailing 一个分号。 */
function joinNote(main: string, note: string): string {
  return note === '' ? main : main + '；' + note;
}

/**
 * `planCard` 的入参：必须是"单个对象字面量"这一种写法。
 * `Repeat` 复用到旧节点时只重跑按引用传（对象字面量 / `$$`）的 `@Builder`；
 * `this.planCard(ri.item)` 这种按值传，复用到的节点会继续念旧行——改期后列表顺序都跟着变了，
 * 卡片文字却还停在旧时间（D-30 的设备复验）。与 D-26 的 `MeView.paramStat` 同一类。
 */
interface PlanCardArg {
  p: PlanSummary;
}

/** 同上，冲突块多带一个解释对象：两个字段都得按引用传，否则改期后条件文案冻在旧值。 */
interface ConflictBlockArg {
  p: PlanSummary;
  c: PlanConflictView;
}

/** 卡内文字链的入参：单对象字面量，理由同 `PlanCardArg`（多参数按值传的链会带旧行回调）。 */
interface LinkActionArg {
  label: string;
  plan: string;
  tone: ResourceColor;
  onTap: () => void;
}

/**
 * 计划列表（US5 / FR-010 / FR-012，阶段 2 Task 2.3）：
 * 共同时间页「共同计划」分段的内容；分段页头由宿主承担，本页只带一行条数与"下一个窗口"的出口，
 * 条目一律走 feature 读模型。
 * - 冲突条目：原因（已按对方隐私等级降维）+ 受影响区间 + 替代窗口，框内给改期主操作与
 *   "重新选窗口 / 保留原计划"次操作；取消计划不分冲突与否都在页脚；
 * - "保留原计划"只是不再催改期，冲突事实与状态都留着，安排再变动会重新提示；
 * - 日历徽标按"归谁管"分说法（写在页脚那颗 chip 上）：应用受管的写成/待清理、editEvent 导出的由系统日历管理、
 *   没写成的常驻"仅保存在应用内"，并各自给出可用出口（补写 / 导出 / 重新清理）；
 * - 监听 recomputeCount 刷新（创建/取消/课表变更自动重算后状态同步）。
 */
@Component
export struct PlansView {
  /** 宿主切换到"时间窗口"分段：分段归宿主，这里只提请求。 */
  onGoWindow: () => void = () => {
  };
  /** 头部行的「＋ 在下一个窗口计划」：宿主除了切分段，还要把视界内第一段空闲直接开成建计划入口。 */
  onNextWindow: () => void = () => {
  };
  @State plans: PlanSummary[] = [];
  @State loading: boolean = true;
  /** 同一时刻只放行一个写操作：改期/取消/补写日历都会重排列表，并发点击只会互相踩。 */
  @State private working: boolean = false;
  /** 下拉刷新的转圈：重算（含向云上要一次对方快照）落地后才收。 */
  @State private refreshing: boolean = false;
  // 装饰器实参必须是字面量，取值与 SENIOR_MODE_KEY 保持一致。
  @StorageProp('crd_senior_mode') senior: boolean = false;
  @StorageProp('recomputeCount') @Watch('onRecomputeChanged') recomputeCount: number = 0;

  aboutToAppear(): void {
    this.reload();
  }

  /** 重算广播（创建/取消计划、课表/参数变更）→ 重新读列表（状态与冲突解释同步）。 */
  onRecomputeChanged(): void {
    this.reload();
  }

  reload(): void {
    CommonTimeQueryService.getPlanCards().then((rows: PlanSummary[]) => {
      this.plans = rows;
      this.loading = false;
    }).catch(() => {
      this.plans = [];
      this.loading = false;
    });
  }

  statusLabel(s: string): string {
    if (s === 'CONFLICT') {
      return '冲突';
    }
    if (s === 'CANCELLED') {
      return '已取消';
    }
    return '已确认';
  }

  statusColor(s: string): ResourceColor {
    if (s === 'CONFLICT') {
      return $r('app.color.danger_red');
    }
    if (s === 'CANCELLED') {
      return $r('app.color.text_hint');
    }
    return $r('app.color.success_green');
  }

  /**
   * 列表键：状态/冲突解释/日历状态任一变化都要重绘卡片（改文案不改键，键只吃解释文本）。
   * 起止时间也在键里——时间是语义字段，漏了它这张卡就没有身份变化。
   * 但**光有键不解决问题**：D-30 的设备复验显示，键里的时间变了、列表顺序也跟着重排了，
   * 复用到的那张卡却仍念旧时间；真正让它刷新的是 `PlanCardArg` 的按引用传参。
   */
  cardKey(p: PlanSummary): string {
    const kept = p.conflict != null && p.conflict.kept ? '1' : '0';
    return p.id + '-' + p.start + '-' + p.end + '-' + p.status + '-' + p.conflictText + '-' + kept
      + '-' + p.calendarState;
  }

  subLabel(p: PlanSummary): string {
    return DateLabel.mdw(Math.floor(p.start / 1440)) + ' ' + DateLabel.endLabel(p.start, p.end) + ' · '
      + DateLabel.duration(p.end - p.start);
  }

  private kindName(p: PlanSummary): string {
    return planKindLabel(p.kind);
  }

  /** 页脚徽标：冲突与否 ＋ 日历归属，合成原型那颗「重叠 · 启用中」位上的两句实话。 */
  private footerBadge(p: PlanSummary): string {
    const badge = calendarBadgeOf(p.calendarState);
    const head = p.conflict != null ? '重叠' : '无冲突';
    return badge === '' ? head : head + ' · ' + badge;
  }

  private hasCalendarAction(p: PlanSummary): boolean {
    return canRetryCleanup(p.calendarState) || canRetryCalendarSync(p.calendarState)
      || canExportToCalendar(p.calendarState);
  }

  private say(msg: string): void {
    appToast(msg);
  }

  /** 点击计划 → 操作弹窗（冲突条目额外给"改到替代时间"）。 */
  onPlanTap(p: PlanSummary): void {
    const alt = p.conflict != null && p.conflict.altStart > 0;
    askConfirm(this.getUIContext(), {
      title: p.title,
      message: this.subLabel(p),
      cancelText: '关闭',
      confirmText: alt ? '改到替代时间' : '取消计划',
      onConfirm: () => {
        if (alt) {
          this.askAcceptAlternative(p);
        } else {
          this.confirmCancel(p);
        }
      }
    });
  }

  /** 取消计划二次确认：能说"日历上那条会一并删掉"的只有应用受管的那份。 */
  confirmCancel(p: PlanSummary): void {
    askConfirm(this.getUIContext(), {
      title: '取消计划',
      message: '确定取消「' + p.title + '」？该时段将恢复空闲。' + this.cancelCalendarNote(p.calendarState),
      cancelText: '暂不',
      confirmText: '确定取消',
      onConfirm: () => this.doCancel(p)
    });
  }

  /** 取消前关于系统日历的一句实话：导出的那份本应用删不动。 */
  private cancelCalendarNote(calendarState: string): string {
    if (isAppManagedEvent(calendarState)) {
      return '应用写进系统日历的那条也会一起删掉。';
    }
    if (isOnSystemCalendar(calendarState)) {
      return '导出的那条已经交给系统日历，要去系统日历里删。';
    }
    return '';
  }

  async doCancel(p: PlanSummary): Promise<void> {
    if (this.working) {
      return;
    }
    this.working = true;
    const r: PlanOpResult = await PlanUseCase.cancelPlan(p.id);
    // 本机一定取消；系统侧没清掉的部分由 cleanupNote 说，不留"已全部清理干净"的错觉
    this.say(r.ok ? joinNote('已取消，这段时间空出来了', r.cleanupNote) : r.error);
    this.reload();
    this.working = false;
  }

  /** 采用替代时间（冲突动作一）：二次确认后级联改期（受管日程同步迁移）。 */
  askAcceptAlternative(p: PlanSummary): void {
    const c = p.conflict;
    // 框念的是计划落地的起止，不是整段替代空档（后者是卡片上「可改到 …」那句的口径）：
    // 空档比计划长时两个数不一样，把空档当"新时间"就是承诺一个不会发生的时间（D-32）。
    const when = c != null && c.landedStart > 0
      ? DateLabel.mdw(Math.floor(c.landedStart / 1440)) + ' ' + DateLabel.endLabel(c.landedStart, c.landedEnd)
      : '';
    askConfirm(this.getUIContext(), {
      title: '改到替代时间',
      message: (when !== '' ? '新时间：' + when + '。' : '')
        + (isAppManagedEvent(p.calendarState) ? '系统日历里的那条会跟着改。'
          : '计划会改到新时间；' + this.cancelCalendarNote(p.calendarState)),
      cancelText: '暂不',
      confirmText: '确认改期',
      onConfirm: () => this.doAcceptAlternative(p)
    });
  }

  async doAcceptAlternative(p: PlanSummary): Promise<void> {
    if (this.working) {
      return;
    }
    this.working = true;
    const r: PlanOpResult = await PlanUseCase.acceptAlternative(p.id);
    if (!r.ok) {
      this.say(r.error);
    } else {
      // 计划已经改到新时间；日历没跟上时不喊失败，条目上的重试入口才是该点的那个
      this.say(joinNote(isOnSystemCalendar(r.calendarState) ? '已改期，日历已同步'
        : '已改期（' + LOCAL_ONLY_NOTE + '）', r.cleanupNote));
    }
    this.reload();
    this.working = false;
  }

  /** 保留原计划（冲突动作三）：不再催改期，冲突状态原样留着。 */
  async doKeepOriginal(p: PlanSummary): Promise<void> {
    if (this.working) {
      return;
    }
    this.working = true;
    const kept = await PlanUseCase.keepOriginalPlan(p.id);
    this.say(kept ? '先按原时间留着，不再提示改期' : '这条计划没有要处理的冲突了');
    this.reload();
    this.working = false;
  }

  /** 把"仅保存在应用内"的计划补写到系统日历（创建/改期没写成时的重试入口）。 */
  async doSyncCalendar(p: PlanSummary): Promise<void> {
    if (this.working) {
      return;
    }
    this.working = true;
    const r: PlanOpResult = await PlanUseCase.syncToCalendar(p.id);
    this.say(r.ok ? '已写入系统日历' : r.error);
    this.reload();
    this.working = false;
  }

  /**
   * 导出到系统日历（editEvent）：日程交给系统日历，之后由用户在系统日历里改删。
   * 只有日历上确实还没有这条计划时才给这个出口——见 PlanUseCase.exportToCalendar 的口径。
   */
  async doExportCalendar(p: PlanSummary): Promise<void> {
    if (this.working) {
      return;
    }
    this.working = true;
    const r: PlanOpResult = await PlanUseCase.exportToCalendar(p.id);
    this.say(r.ok ? joinNote('已导出到系统日历', r.cleanupNote) : r.error);
    this.reload();
    this.working = false;
  }

  /** 重新清理系统侧残留（权限撤回后重新授权即可清掉；启动时也会自动补一次）。 */
  async doRetryCleanup(p: PlanSummary): Promise<void> {
    if (this.working) {
      return;
    }
    this.working = true;
    const r: PlanOpResult = await PlanUseCase.retryProjection(p.id);
    this.say(r.ok ? joinNote('系统侧已清理干净', r.cleanupNote) : joinNote(r.error, r.cleanupNote));
    this.reload();
    this.working = false;
  }

  build() {
    Column() {
      if (!this.loading && this.plans.length > 0) {
        this.headerRow()
      }
      Refresh({ refreshing: $$this.refreshing, offset: 64, friction: 10 }) {
        List({ space: 12 }) {
          if (this.loading) {
            ListItem() {
              Text('加载中…').fontSize(14).fontColor($r('app.color.text_tertiary')).margin({ top: 40 })
            }
          } else if (this.plans.length === 0) {
            // 空态引导（US5：窗口 → 计划的转化出口）
            ListItem() {
              Column({ space: 12 }) {
                // 原型 emptyCard() 被三个空态共用，App 此前只有共同页接了它，计划页画的是心形符号
                SleepBunny()
                Text('还没有计划').fontSize(16).fontWeight(FontWeight.Medium)
                Text($r('app.string.plans_empty_desc'))
                  .fontSize(12).fontColor($r('app.color.text_tertiary')).textAlign(TextAlign.Center)
                Button('去选一个窗口创建计划')
                  .backgroundColor($r('app.color.brand_pink'))
                  .borderRadius(22)
                  .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
                  .onClick(() => {
                    this.onGoWindow();
                  })
              }
              .alignItems(HorizontalAlign.Center)
              .width('100%').padding({ top: 36, bottom: 36, left: 24, right: 24 }).borderRadius(DesignTokens.cardRadius(false))
              .backgroundColor($r('app.color.brand_pink_bg'))
            }
          } else {
            // Repeat（API 26 稳定）替代 ForEach：键值 diff 更高效，行为一致
            Repeat<PlanSummary>(this.plans)
              .key((p: PlanSummary) => this.cardKey(p))
              .each((ri: RepeatItem<PlanSummary>) => {
                ListItem() {
                  this.planCard({ p: ri.item })
                }
                .swipeAction({
                  end: () => {
                    this.cancelSwipe({ p: ri.item })
                  },
                  edgeEffect: SwipeEdgeEffect.Spring
                })
              })
          }
        }
        .padding({ bottom: DesignTokens.dockClearance })
        .width('100%').height('100%')
        // alwaysEnabled：一条计划都没有时列表不满一屏，默认不接下拉手势，Refresh 就白挂。
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      }
      .onRefreshing(() => {
        this.onRefresh();
      })
      .width('100%').layoutWeight(1)
    }
    .width('100%').height('100%')
  }

  /** 下拉刷新：重算一遍视界（已配对时顺带拉对方最新快照），重算广播会带动本页重读列表。 */
  private async onRefresh(): Promise<void> {
    await syncOnPull();
    this.refreshing = false;
  }

  /**
   * 头部行：条数 + "续到下一个窗口"的出口。空态不放——空态卡片自己就是那条出口，
   * 两处同样一句话只会让第一次进来的人在两个按钮间犹豫。
   */
  @Builder
  headerRow() {
    Row() {
      Text('共 ' + this.plans.length + ' 条')
        .fontSize(12).fontColor($r('app.color.text_tertiary'))
      Blank()
      Text('＋ 在下一个窗口计划')
        .fontSize(13).fontColor($r('app.color.brand_pink'))
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        // 原型这颗是 .chip，跟着芯片一起收成胶囊。
        .borderRadius(DesignTokens.radiusPill)
        .backgroundColor($r('app.color.brand_pink_bg'))
        .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
        .focusable(true)
        .accessibilityText('在下一个窗口创建计划')
        .onClick(() => {
          this.onNextWindow();
        })
    }
    .width('100%')
    .padding({ bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }

  /** 左滑露出的"取消计划"按钮（点击走原有二次确认弹窗）。 */
  @Builder
  cancelSwipe(arg: PlanCardArg) {
    Row() {
      Text('取消计划').fontSize(14).fontColor(DesignTokens.heroText)
    }
    .width(88)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.danger_red'))
    .borderRadius(14)
    .focusable(true)
    .accessibilityText('取消计划：' + arg.p.title)
    .onClick(() => this.confirmCancel(arg.p))
  }

  /** 计划卡片：通高状态条 + 标题行 + 时间行 + 冲突框（说明与改期） + 页脚（徽标与取消）。 */
  @Builder
  planCard(arg: PlanCardArg) {
    Row({ space: 12 }) {
      Column().width(4).borderRadius(2)
        .backgroundColor(this.statusColor(arg.p.status))
        .alignSelf(ItemAlign.Stretch)
        // 状态另有文字标注（冲突/已取消/已确认），色条只是重复信息
        .accessibilityLevel('no')
      Column({ space: 6 }) {
        this.cardHead({ p: arg.p })

        Text(this.subLabel(arg.p))
          .fontSize(12).fontColor($r('app.color.text_tertiary'))

        if (arg.p.conflict != null) {
          this.conflictBlock({ p: arg.p, c: arg.p.conflict })
        }

        if (this.hasCalendarAction(arg.p)) {
          this.calendarActions({ p: arg.p })
        }

        this.planFooter({ p: arg.p })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%').padding(16).borderRadius(DesignTokens.cardRadius(false)).backgroundColor($r('app.color.card_bg'))
    // 原型给计划卡留了一档更轻的落影（0 4px 16px），比正文卡薄，一列排下来才不糊。
    .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })
    .onClick(() => this.onPlanTap(arg.p))
  }

  /** 标题行：标题与状态 chip 靠左，类型名只在和标题不一样时补在右边。 */
  @Builder
  cardHead(arg: PlanCardArg) {
    Row({ space: 6 }) {
      Text(arg.p.title)
        .fontSize(15).fontWeight(FontWeight.Medium)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .flexShrink(1)
      Text(this.statusLabel(arg.p.status))
        .fontSize(11).fontColor($r('app.color.hero_fg'))
        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        .borderRadius(6)
        .backgroundColor(this.statusColor(arg.p.status))
      Blank()
      if (this.kindName(arg.p) !== arg.p.title) {
        Text(this.kindName(arg.p)).fontSize(11).fontColor($r('app.color.text_tertiary'))
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // 标题、状态、类型各念一遍会打断，合成一句
    .accessibilityGroup(true)
    .accessibilityText(arg.p.title + '，' + this.statusLabel(arg.p.status)
      + (this.kindName(arg.p) !== arg.p.title ? '，类型' + this.kindName(arg.p) : ''))
  }

  /** 页脚：徽标 chip 说"重叠与否 · 日历上归谁管"，右边那颗才是取消计划的正式出口。 */
  @Builder
  planFooter(arg: PlanCardArg) {
    Row({ space: 8 }) {
      Text(this.footerBadge(arg.p))
        .fontSize(11).fontColor($r('app.color.text_secondary'))
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .borderRadius(6)
        .backgroundColor($r('app.color.fill_weak'))
      Blank()
      Text('取消计划')
        .fontSize(12).fontColor($r('app.color.danger_red'))
        .padding({ left: 4, right: 4, top: DesignTokens.space1, bottom: DesignTokens.space1 })
        .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
        .focusable(true)
        .accessibilityText('取消计划：' + arg.p.title)
        .onClick(() => this.confirmCancel(arg.p))
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 冲突解释 + 改期主操作 + 一个次操作（Task 2.3）；取消计划归页脚，不挤在这里。 */
  @Builder
  conflictBlock(arg: ConflictBlockArg) {
    Column({ space: 6 }) {
      Text(arg.c.reasonText).fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.danger_red'))
      if (arg.c.affectedText !== '') {
        Text(arg.c.affectedText).fontSize(11).fontColor($r('app.color.text_tertiary'))
      }
      if (arg.c.kept) {
        Text('已按原时间保留，你们的安排再有变动时会重新提示')
          .fontSize(11).fontColor($r('app.color.text_hint'))
      } else if (arg.c.altText !== '') {
        Text(arg.c.altText).fontSize(12).fontColor($r('app.color.brand_pink'))
      } else {
        Text('暂时找不到合适的替代时间，可以保留原计划或另约')
          .fontSize(11).fontColor($r('app.color.text_hint'))
      }
      Row({ space: 10 }) {
        if (!arg.c.kept && arg.c.altStart > 0) {
          Button('改到替代时间').fontSize(12)
            .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .backgroundColor($r('app.color.brand_pink'))
            .fontWeight(FontWeight.Bold)
            .shadow(DesignTokens.jelly(DesignTokens.primaryDeep, DesignTokens.jellyDepth))
            .onClick(() => this.askAcceptAlternative(arg.p))
        }
        this.linkAction({
          label: '重新选窗口', plan: arg.p.title, tone: $r('app.color.info_blue'),
          onTap: () => {
            this.onGoWindow();
          }
        })
        if (arg.c.kept && arg.c.altStart > 0) {
          this.linkAction({
            label: '仍然改期', plan: arg.p.title, tone: $r('app.color.info_blue'),
            onTap: () => this.askAcceptAlternative(arg.p)
          })
        } else if (!arg.c.kept) {
          this.linkAction({
            label: '保留原计划', plan: arg.p.title, tone: $r('app.color.info_blue'),
            onTap: () => this.doKeepOriginal(arg.p)
          })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ top: 6, bottom: 6, left: 10, right: 10 })
    .borderRadius(8)
    .backgroundColor($r('app.color.danger_bg'))
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 日历出口：没写成的给「写入日历」（受管）与「导出到系统日历」，待清理的只给「重新清理」——
   * 这时日历上还挂着旧日程，补写就是同一天两条。归属本身已经写在页脚徽标里，这里只留动作。
   */
  @Builder
  calendarActions(arg: PlanCardArg) {
    Flex({ wrap: FlexWrap.Wrap }) {
      if (canRetryCleanup(arg.p.calendarState)) {
        this.linkAction({
          label: '重新清理', plan: arg.p.title, tone: $r('app.color.info_blue'),
          onTap: () => this.doRetryCleanup(arg.p)
        })
      }
      if (canRetryCalendarSync(arg.p.calendarState)) {
        this.linkAction({
          label: '写入日历', plan: arg.p.title, tone: $r('app.color.info_blue'),
          onTap: () => this.doSyncCalendar(arg.p)
        })
      }
      if (canExportToCalendar(arg.p.calendarState)) {
        this.linkAction({
          label: '导出到系统日历', plan: arg.p.title, tone: $r('app.color.info_blue'),
          onTap: () => this.doExportCalendar(arg.p)
        })
      }
    }
    .width('100%')
  }

  /**
   * 卡内文字链：朗读名带上计划标题（只剩一句"取消计划"时，列表里第几条无从判断），
   * 热区按 44/48vp 走，2 倍字号下靠外层 Flex 换行而不是挤出卡片。
   * 入参同样是单对象字面量：多参数是按值传，改期后复用到的链会继续带着旧行去回调。
   */
  @Builder
  linkAction(arg: LinkActionArg) {
    Text(arg.label)
      .fontSize(12).fontColor(arg.tone)
      .padding({ right: DesignTokens.space4, top: DesignTokens.space1, bottom: DesignTokens.space1 })
      .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
      .focusable(true)
      .accessibilityText(arg.label + '：' + arg.plan)
      .onClick(arg.onTap)
  }
}
