import { FeatureFlags, SharedPlanAction, SharedPlanContent, SharedPlanRecord, SharedPlanViewData,
  SharedPlanViewService, sharedInlineActions, sharedDrawerActions, SharedPlanDrawerAction, SharedPlanDrawerItem,
  sharedActionLabel, sharedPlanStateLabel, sharedResultMessage,
  secureSharedPlans, PlanUseCase, sharedPlanDiagnosticText, SharedPlanDraftCommand } from 'feature';
import { DateLabel } from 'commons';
import { dayOfStart, epochDayOf, MIN_PER_DAY, minToHHmm } from 'domain';
import { DesignTokens } from '../theme/DesignTokens';
import { appToast } from '../util/AppToast';
import { askConfirm } from '../util/AppConfirm';
import { common } from '@kit.AbilityKit';
import { SettingsStore } from 'data';
import { PlanNotifications } from '../util/PlanNotifications';
import { LatestLanding } from '../util/LatestLanding';
import { LatestReadQueue } from '../util/LatestReadQueue';
import { PlanDateTicket } from './PlanDateTicket';

interface SharedCardArg { row: SharedPlanRecord; }

/** Explicit peer decisions; pending drafts never pass through the local confirmed-plan writer. */
@Component
export struct SharedPlansPanel {
  @Prop @Watch('onActiveChanged') active: boolean = true;
  /** Card mode receives already-read data; only the header instance reads the repository. */
  @Prop cardRow: SharedPlanRecord | null = null;
  @Prop actorId: string = '';
  @Prop linked: boolean = false;
  onChanged: () => void = () => {};
  onRead: (data: SharedPlanViewData) => void = () => {};
  onReadFailed: () => void = () => {};
  closeDrawer: () => void = () => {};
  @Prop @Watch('reload') refreshTick: number = 0;
  @Prop refreshing: boolean = false;
  @State private data: SharedPlanViewData = { pairId: '', actorId: '', rows: [], pendingCount: 0,
    unresolved: false, linked: false };
  @State private busy: boolean = false;
  @State private feedback: string = '';
  @State private editId: string = '';
  @State private editTitle: string = '';
  @State private editStart: number = 0;
  @State private editEnd: number = 0;
  @State private notifications: boolean = false;
  @State private cardHeight: number = 92;
  private editKind: string = '';
  private mounted: boolean = false;
  private landing: LatestLanding = new LatestLanding();
  private reads: LatestReadQueue = new LatestReadQueue();
  @StorageProp('recomputeCount') @Watch('reload') private recomputeTick: number = 0;
  @StorageProp('crdSharedPlanTick') @Watch('reload') private sharedPlanTick: number = 0;

  aboutToAppear(): void { this.mounted = true; this.reload(); }
  aboutToDisappear(): void { this.mounted = false; this.landing.begin(); this.reads.cancel(); }
  onActiveChanged(): void {
    if (!this.active) { this.landing.invalidate(); this.reads.cancel(); return; }
    if (this.mounted) this.reload();
  }
  async reload(): Promise<void> {
    if (this.cardRow !== null) return;
    if (!this.active || !this.mounted) return;
    const turn = this.landing.begin();
    await this.reads.run(async (): Promise<void> => {
      try {
        const data = await SharedPlanViewService.read();
        if (this.mounted && this.landing.isCurrent(turn)) {
          this.data = data; this.notifications = data.pairId !== '' && SettingsStore.getPlanNotificationPair() === data.pairId;
          this.onRead(data);
        }
      } catch {
        if (this.mounted && this.landing.isCurrent(turn)) {
          this.feedback = '共同计划暂时读不到，已有数据未改变'; this.onReadFailed();
        }
      }
    });
  }
  private async run(action: string, row: SharedPlanRecord | null = null, requestId: string = ''): Promise<void> {
    if (this.busy || this.refreshing || !this.mounted || (row !== null && !this.rowCurrent(row))) return;
    this.busy = true;
    try {
      let code: string;
      if (action === 'RETRY') code = await secureSharedPlans().retry();
      else if (action === 'CLOSE_REQUEST') code = await secureSharedPlans().closePending(requestId);
      else if (row !== null) {
        const draft: SharedPlanContent | null = action !== SharedPlanAction.AMEND ? null
          : { title: this.editTitle.trim(), kind: this.editKind, start: this.editStart, end: this.editEnd };
        code = await secureSharedPlans().respond(row.planId, action as SharedPlanAction, draft);
        if (code === 'OK' || code === 'SAVED_RECOMPUTE_PENDING') this.editId = '';
      } else return;
      if (this.mounted) {
        const detail = sharedPlanDiagnosticText(secureSharedPlans().diagnostic());
        this.feedback = sharedResultMessage(code) + (detail === '' ? '' : '\n\n' + detail);
        await this.reload(); this.onChanged();
      }
    } catch { if (this.mounted) { this.feedback = '结果尚未确认，请核实后再操作'; await this.reload(); this.onChanged(); } }
    finally { if (this.mounted) this.busy = false; }
  }
  private closeRequest(command: SharedPlanDraftCommand): void {
    if (this.busy || this.refreshing) return;
    askConfirm(this.getUIContext(), { title: '关闭未提交请求',
      message: '先向云端核实：若原请求已经提交，将恢复计划，不会取消；只有确认未提交时才会关闭，并阻止旧请求延迟发送。',
      confirmText: '核实并关闭', onConfirm: () => { this.run('CLOSE_REQUEST', null, command.requestId); } });
  }
  private requestContent(command: SharedPlanDraftCommand): SharedPlanContent | null {
    if (command.nextContent !== null) return command.nextContent;
    const row = this.data.rows.find((item: SharedPlanRecord): boolean => item.planId === command.planId);
    return command.checkedContent ?? row?.pendingContent ?? row?.acceptedContent ?? null;
  }
  @Builder
  unresolvedRequest(command: SharedPlanDraftCommand) {
    Column({ space: 8 }) {
      Text(command.action === 'PROPOSE' ? '原邀请 · 结果待核实' : sharedActionLabel(command.action as SharedPlanAction) + ' · 结果待核实')
        .fontSize(12).fontColor(DesignTokens.textSecondary)
      Text(this.requestContent(command)?.title ?? '共同计划')
        .fontSize(16).fontWeight(FontWeight.Bold).fontColor(DesignTokens.textPrimary)
      if (this.requestContent(command) !== null) {
        Text(this.stamp(this.requestContent(command)!)).fontSize(12).fontColor(DesignTokens.textSecondary)
      }
      Text('本机请求，送达结果待核实；未确认不新增占用。')
        .fontSize(12).fontColor(DesignTokens.textSecondary)
      Button('关闭未提交请求').fontSize(12).constraintSize({ minHeight: 44 })
        .backgroundColor(DesignTokens.fillWeak).fontColor(DesignTokens.textPrimary)
        .enabled(!this.busy && !this.refreshing && FeatureFlags.sharedPlan).onClick(() => this.closeRequest(command))
    }.width('100%').alignItems(HorizontalAlign.Start).padding(14)
      .backgroundColor(DesignTokens.card).borderRadius(18)
  }
  private pick(row: SharedPlanRecord, action: SharedPlanAction): void {
    if (this.busy || this.refreshing || !this.rowCurrent(row)) return;
    this.closeDrawer();
    if (action === SharedPlanAction.AMEND && row.acceptedContent !== null) {
      this.editId = row.planId; this.editTitle = row.acceptedContent.title;
      this.editStart = row.acceptedContent.start; this.editEnd = row.acceptedContent.end;
      this.editKind = row.acceptedContent.kind; return;
    }
    askConfirm(this.getUIContext(), { title: sharedActionLabel(action),
      message: action === SharedPlanAction.ACCEPT ? '同意后，这个时间会加入双方日程。当前会先检查你的最新安排。'
        : action === SharedPlanAction.CANCEL ? '同步取消后，双方应用里的该计划不再占用时间。'
          : '这次操作会同步给对方；已有的确认时间不会被未确认的改期覆盖。',
      confirmText: sharedActionLabel(action), danger: action === SharedPlanAction.CANCEL,
      onConfirm: () => { this.run(action, row); } });
  }
  private stamp(content: SharedPlanContent): string {
    return DateLabel.mdw(dayOfStart(content.start)) + ' ' + DateLabel.endLabel(content.start, content.end);
  }
  private timeRange(row: SharedPlanRecord): string {
    const content = row.pendingContent ?? row.acceptedContent;
    return content === null ? '申请已结束' : DateLabel.endLabel(content.start, content.end);
  }
  private timeRead(row: SharedPlanRecord): string {
    const content = row.pendingContent ?? row.acceptedContent;
    return content === null ? '申请已结束' : this.stamp(content);
  }
  private displayedStart(row: SharedPlanRecord): number {
    return (row.pendingContent ?? row.acceptedContent)?.start ?? -1;
  }
  private rowCurrent(row: SharedPlanRecord): boolean {
    return this.mounted && this.active && this.cardRow !== null && this.cardRow.pairId === row.pairId
      && this.cardRow.planId === row.planId && this.cardRow.stateVersion === row.stateVersion
      && (this.actorId === row.proposerUid || this.actorId === row.recipientUid);
  }
  private drawerEnabled(item: SharedPlanDrawerItem): boolean {
    return item.enabled && !this.busy && !this.refreshing && this.editId === ''
      && (item.action === SharedPlanDrawerAction.EXPORT || (FeatureFlags.sharedPlan && this.linked));
  }
  private drawerLabel(action: SharedPlanDrawerAction): string {
    return action === SharedPlanDrawerAction.EXPORT ? '导出到日历'
      : action === SharedPlanDrawerAction.AMEND ? '申请改期' : '取消计划';
  }
  private drawerSymbol(action: SharedPlanDrawerAction): Resource {
    return action === SharedPlanDrawerAction.EXPORT ? $r('sys.symbol.calendar')
      : action === SharedPlanDrawerAction.AMEND ? $r('sys.symbol.clock') : $r('sys.symbol.trash');
  }
  private drawerBg(action: SharedPlanDrawerAction): Resource {
    return action === SharedPlanDrawerAction.EXPORT ? DesignTokens.drawerCalendarBg
      : action === SharedPlanDrawerAction.AMEND ? DesignTokens.planSurface : DesignTokens.drawerCancelBg;
  }
  private drawerInk(action: SharedPlanDrawerAction): Resource {
    return action === SharedPlanDrawerAction.EXPORT ? DesignTokens.drawerCalendarInk
      : action === SharedPlanDrawerAction.AMEND ? DesignTokens.planInk : DesignTokens.drawerCancelInk;
  }
  private async exportCalendar(row: SharedPlanRecord): Promise<void> {
    if (this.busy || this.refreshing || !this.rowCurrent(row)) return;
    this.closeDrawer(); this.busy = true;
    try {
      const result = await PlanUseCase.exportToCalendar('shared:' + row.pairId + ':' + row.planId);
      if (this.mounted) appToast(result.ok ? '已处理日历导出，请以系统确认结果为准' : result.error);
    } catch { if (this.mounted) appToast('日历暂时无法打开'); }
    finally { if (this.mounted) this.busy = false; }
  }
  private drawerPick(row: SharedPlanRecord, item: SharedPlanDrawerItem): void {
    if (!this.rowCurrent(row) || !this.drawerEnabled(item)
      || !sharedDrawerActions(row, this.actorId).some((current: SharedPlanDrawerItem): boolean =>
        current.action === item.action && current.enabled)) return;
    if (item.action === SharedPlanDrawerAction.EXPORT) { this.exportCalendar(row); return; }
    this.pick(row, item.action === SharedPlanDrawerAction.AMEND ? SharedPlanAction.AMEND : SharedPlanAction.CANCEL);
  }
  @Builder
  drawer(arg: SharedCardArg) {
    Row() {
      ForEach(sharedDrawerActions(arg.row, this.actorId), (item: SharedPlanDrawerItem) => {
        Column({ space: 8 }) {
          SymbolGlyph(this.drawerSymbol(item.action)).fontSize(22).fontColor([this.drawerInk(item.action)])
            .accessibilityLevel('no')
          Text(item.action === SharedPlanDrawerAction.EXPORT ? '导出到\n日历'
            : item.action === SharedPlanDrawerAction.AMEND ? '申请\n改期' : '取消\n计划')
            .fontSize(13).fontWeight(FontWeight.Medium).textAlign(TextAlign.Center)
            .fontColor(this.drawerInk(item.action))
        }.width(76).height('100%').justifyContent(FlexAlign.Center)
          .backgroundColor(this.drawerBg(item.action)).enabled(this.drawerEnabled(item))
          .opacity(this.drawerEnabled(item) ? 1 : 0.45).focusable(true)
          .accessibilityGroup(true).accessibilityText(this.drawerLabel(item.action) + '：' + arg.row.acceptedContent?.title)
          .clickEffect(DesignTokens.tapButton()).onClick(() => this.drawerPick(arg.row, item))
      }, (item: SharedPlanDrawerItem) => item.action)
    }.height(this.cardHeight).borderRadius({ topRight: 24, bottomRight: 24 }).clip(true)
  }
  private pickTime(end: boolean): void {
    const editor = this.editId;
    const current = end ? this.editEnd : this.editStart;
    const parts = DateLabel.ymd(dayOfStart(current));
    const minute = current % MIN_PER_DAY;
    this.getUIContext().showTimePickerDialog({ selected: new Date(parts.y, parts.m - 1, parts.d,
      Math.floor(minute / 60), minute % 60), useMilitaryTime: true,
      onAccept: (value: TimePickerResult) => {
        if (!this.mounted || this.editId === '' || this.editId !== editor || value.hour === undefined || value.minute === undefined) return;
        const result = dayOfStart(current) * MIN_PER_DAY + value.hour * 60 + value.minute;
        if (end) this.editEnd = result; else this.editStart = result;
      } });
  }
  private pickDate(end: boolean): void {
    const editor = this.editId;
    const current = end ? this.editEnd : this.editStart;
    const parts = DateLabel.ymd(dayOfStart(current));
    this.getUIContext().showDatePickerDialog({ selected: new Date(parts.y, parts.m - 1, parts.d),
      onDateAccept: (value: Date) => {
        if (!this.mounted || this.editId === '' || this.editId !== editor) return;
        const result = epochDayOf(value.getFullYear(), value.getMonth() + 1, value.getDate()) * MIN_PER_DAY
          + current % MIN_PER_DAY;
        if (end) this.editEnd = result; else this.editStart = result;
      } });
  }
  private async toggleNotifications(): Promise<void> {
    if (this.busy || this.refreshing) return;
    this.busy = true;
    try {
      const code = this.notifications ? await PlanNotifications.disable()
        : await PlanNotifications.enable(this.getUIContext().getHostContext() as common.UIAbilityContext);
      if (this.mounted) {
        this.feedback = code === 'OK' ? '通知设置已更新；手机通知和锁屏设置也会影响展示'
          : code === 'NOTIFICATION_DENIED' ? '尚未允许通知，你仍可打开计划页查看'
            : '通知设置暂未完成，请稍后手动重试';
        await this.reload();
      }
    } finally { if (this.mounted) this.busy = false; }
  }
  @Builder
  editor(arg: SharedCardArg) {
    Column({ space: 10 }) {
      TextInput({ text: this.editTitle, placeholder: '计划标题' }).maxLength(120)
        .onChange((value: string) => { this.editTitle = value; })
      Row({ space: 8 }) {
        Text('开始').fontColor(DesignTokens.textSecondary)
        Button(DateLabel.md(dayOfStart(this.editStart))).layoutWeight(1).stateEffect(false)
          .backgroundColor(DesignTokens.fillWeak).fontColor(DesignTokens.textPrimary)
          .onClick(() => this.pickDate(false))
        Button(minToHHmm(this.editStart % MIN_PER_DAY)).stateEffect(false)
          .backgroundColor(DesignTokens.fillWeak).fontColor(DesignTokens.textPrimary).onClick(() => this.pickTime(false))
      }
      Row({ space: 8 }) {
        Text('结束').fontColor(DesignTokens.textSecondary)
        Button(DateLabel.md(dayOfStart(this.editEnd))).layoutWeight(1).stateEffect(false)
          .backgroundColor(DesignTokens.fillWeak).fontColor(DesignTokens.textPrimary).onClick(() => this.pickDate(true))
        Button(minToHHmm(this.editEnd % MIN_PER_DAY)).stateEffect(false)
          .backgroundColor(DesignTokens.fillWeak).fontColor(DesignTokens.textPrimary).onClick(() => this.pickTime(true))
      }
      Text('改期确认前，原计划仍有效。').fontSize(12).fontColor(DesignTokens.textSecondary)
      Row({ space: 8 }) {
        Button('取消').layoutWeight(1).stateEffect(false).onClick(() => { this.editId = ''; })
          .backgroundColor(DesignTokens.fillWeak).fontColor(DesignTokens.textPrimary)
        Button('发送改期申请').layoutWeight(1).stateEffect(false).constraintSize({ minHeight: 44 })
          .backgroundColor(DesignTokens.primary).fontColor(DesignTokens.heroText).enabled(!this.busy)
          .onClick(() => { this.run(SharedPlanAction.AMEND, arg.row); })
      }
    }.width('100%').padding({ top: 12 }).enabled(!this.busy)
  }
  @Builder
  card(arg: SharedCardArg) {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        PlanDateTicket({ start: this.displayedStart(arg.row) })
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            Text(arg.row.pendingContent?.title ?? arg.row.acceptedContent?.title ?? '共同计划')
              .layoutWeight(1).fontSize(17).fontWeight(FontWeight.Bold).fontColor(DesignTokens.textPrimary)
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(sharedPlanStateLabel(arg.row, this.actorId)).fontSize(11).fontWeight(FontWeight.Medium)
              .fontColor(DesignTokens.planInk).padding({ left: 6, right: 6, top: 3, bottom: 3 })
              .borderRadius(8).backgroundColor(DesignTokens.planSurface)
          }.width('100%')
          Text(this.timeRange(arg.row)).fontSize(12).fontColor(DesignTokens.textSecondary)
            .accessibilityText(this.timeRead(arg.row))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%').alignItems(VerticalAlign.Center)
      if (arg.row.pendingContent !== null) {
        Text(arg.row.acceptedContent === null
          ? arg.row.pendingAuthorUid === this.actorId ? '待对方确认 · 暂不占用时间' : '确认后加入双方日程'
          : '改期待确认 · 原计划有效')
          .fontSize(12).fontColor(DesignTokens.planMuted)
      }
      if (arg.row.acceptedContent !== null && arg.row.pendingContent !== null) {
        Text('原确认：' + this.stamp(arg.row.acceptedContent)).fontSize(12).fontColor(DesignTokens.textSecondary)
      }
      if (FeatureFlags.sharedPlan && this.linked && sharedInlineActions(arg.row, this.actorId).length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(sharedInlineActions(arg.row, this.actorId), (action: SharedPlanAction) => {
            Button(sharedActionLabel(action)).constraintSize({ minHeight: 44 }).fontSize(13).stateEffect(false)
              .backgroundColor(action === SharedPlanAction.ACCEPT ? DesignTokens.primary : DesignTokens.fillWeak)
              .fontColor(action === SharedPlanAction.ACCEPT ? DesignTokens.heroText : DesignTokens.textPrimary)
              .enabled(!this.busy && !this.refreshing).margin({ right: 8, bottom: 6 }).onClick(() => this.pick(arg.row, action))
          }, (action: SharedPlanAction) => action)
        }
      }
      if (this.editId === arg.row.planId) { this.editor({ row: arg.row }) }
      if (this.busy) { Text('正在处理…').fontSize(12).fontColor(DesignTokens.planMuted) }
      if (this.cardRow !== null && this.feedback !== '') {
        Text(this.feedback).fontSize(12).fontColor(DesignTokens.textSecondary)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
      .padding({ left: 14, right: 14, top: 10, bottom: 10 }).borderRadius(24)
      .backgroundColor(DesignTokens.card).constraintSize({ minHeight: 92 })
      .onAreaChange((_old: Area, area: Area) => {
        const height = Number(area.height);
        if (this.mounted && Number.isFinite(height) && Math.abs(height - this.cardHeight) > 0.5) this.cardHeight = height;
      })
  }
  build() {
    if (this.cardRow !== null) {
      ListItem() {
        this.card({ row: this.cardRow })
      }.swipeAction({ end: sharedDrawerActions(this.cardRow, this.actorId).length > 0 && this.editId === ''
        ? () => { if (this.cardRow !== null) this.drawer({ row: this.cardRow }) } : undefined,
        edgeEffect: SwipeEdgeEffect.None })
    } else {
      Column({ space: 12 }) {
        if (FeatureFlags.sharedPlan || this.data.rows.length > 0 || this.data.unresolved) {
          Row({ space: 8 }) {
            Text('双方共同计划').layoutWeight(1).fontSize(15).fontWeight(FontWeight.Bold).fontColor(DesignTokens.textPrimary)
            if (FeatureFlags.sharedPlan && this.data.linked) {
              Button(this.notifications ? '关闭计划通知' : '开启计划通知').stateEffect(false).constraintSize({ minHeight: 44 })
                .fontSize(12).backgroundColor(DesignTokens.fillWeak).fontColor(DesignTokens.textPrimary)
                .enabled(!this.busy && !this.refreshing).onClick(() => { this.toggleNotifications(); })
            }
          }.width('100%')
          if (!this.data.linked) {
            Text('到「我的 · 伴侣与同步」完成连接；已有记录可查看。')
              .fontSize(12).fontColor(DesignTokens.textSecondary)
          }
          if (this.data.unresolved) {
            ForEach(this.data.unresolvedRequests ?? [], (command: SharedPlanDraftCommand) => {
              this.unresolvedRequest(command)
            }, (command: SharedPlanDraftCommand): string => command.requestId)
            Button('核实 / 重试').stateEffect(false).constraintSize({ minHeight: 44 })
              .backgroundColor(DesignTokens.primaryBg).fontColor(DesignTokens.textAccent)
              .enabled(!this.busy && !this.refreshing && FeatureFlags.sharedPlan).onClick(() => { this.run('RETRY'); })
          }
          if (this.feedback !== '') { Text(this.feedback).fontSize(12).fontColor(DesignTokens.textSecondary) }
        }
      }
      .width('100%').alignItems(HorizontalAlign.Start)
    }
  }
}
