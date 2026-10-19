import { Chip } from '@kit.ArkUI';
import { Interval, nowEpochMin, todayEpochDay, dayOfStart, epochDayOf, MIN_PER_DAY } from 'domain';
import { DateLabel, Logger } from 'commons';
import {
  CreatePlanOptions, isOnSystemCalendar, LOCAL_ONLY_NOTE, OTHER_PLAN_KIND_KEY,
  PlanDraft, PlanKindOption, PLAN_KINDS, PlanUseCase, ScheduleUseCase, defaultDraft, planDraftError,
  DRAFT_GRID_MIN, FeatureFlags, secureSharedPlans, sharedResultMessage, SharedPlanContent, sharedPlanDiagnosticText,
  sharedPlanNeedsReview
} from 'feature';
import { SettingsStore, PAIRED } from 'data';
import { DesignTokens } from '../theme/DesignTokens';
import { publishPlanSaved } from '../util/PlanSavedSignal';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';
import { appToast } from '../util/AppToast';
import { PlanRangePreview } from './PlanRangePreview';

const STEP_MIN = DRAFT_GRID_MIN;
const TAG = 'WindowDetailSheet';
const SUCCESS_HOLD_MS = 400;

/**
 * 探头休休（原型 `.sheet-peek`，7 分甜的签名动作）：
 * 原造型休休按 96×88 等比显示；为耳朵预留 62vp 透明带，再下移 8vp，
 * 让实际爪缘（不含 PNG 底部透明边）轻压在摘要卡片上沿，而不是悬在 sheet 白边上。
 *
 * 系统半模态**按自己的窗口矩形裁内容**（设备实测：负 margin 抬出去那截，
 * `dumpLayout` 里 `origBounds` 高 218px 而 `bounds` 只剩 90px，被切掉的 128px=36.6vp
 * 正好等于外溢量），所以外溢不能靠负 margin 硬顶，得把窗口自己垫高——
 * 根 Stack 让出对应 PEEK_OUT 高的透明带（sheet 的 `backgroundColor` 已是 Transparent、
 * 面由本组件画，见批次 Q·Q2），休休落在这条带里，卡片贴边调整不缩短这条安全带。
 */
const PEEK_W: number = 96;
const PEEK_H: number = 88;
/** 下沿压进 sheet 内的量：CSS `bottom: sheetHeight - 26`。 */
const PEEK_IN: number = 26;
/** 探到面外的量，也就是根 Stack 顶部那条透明带的高。 */
const PEEK_OUT: number = PEEK_H - PEEK_IN;
/** 摘要顶部在句柄后 27vp；补偿透明底边后让实际爪缘压进摘要约 3vp。 */
const PEEK_CARD_DROP: number = 8;
const PEEK_MARGIN_TOP: number = -PEEK_OUT + PEEK_CARD_DROP;
const PEEK_LEFT: number = 22;
/** 起点 CSS `transform:translateY(130%)`，落位 0，.5s spring。 */
const PEEK_RISE_Y: number = PEEK_H * 1.3;
const PEEK_MS: number = 500;

/**
 * 窗口详情半模态（US5 / FR-009）：
 * - 顶部：日期 + 窗口起止 + 时长 + 标签；
 * - 时间轴可视化：窗口横条 + 计划区间高亮预览（Row 比例布局）；条下方两端是窗口起止
 *   （跨日才带日期），中间标窗口总长——计划区间条上已高亮、下面表单里有数字，不再占这一行；
 * - 计划类型选择 + 标题（默认=类型名）+ 起止调节：±15 分钟或自定义日期时间，提交时统一校验窗口；
 *   两端读数一律带日期（D-44，今天/明天/月日三档），只印 HH:MM 时"明天 07:00"读起来和今天没区别；
 * - 「创建计划」→ PlanUseCase.createPlan：默认受管写入应用专属「同休日」日历（开关可关成"只留在应用里"），
 *   没写成时计划照样保留，toast 明说"仅保存在应用内"。
 *
 * 视觉：Sheet 整体是玻璃顶层（规范 §3.3），表单区另铺近实色子表面保证输入可读性；
 * inline 嵌入宽屏详情栏时改铺卡片底，句柄与贴底留白一并去掉。
 */
@Component
export struct WindowDetailSheet {
  /** 窗口起止（@Watch：复用同一 sheet 实例打开不同窗口时重置草稿，防止上次窗口的残留）。 */
  @Prop @Watch('resetDraft') winStart: number = 0;
  @Prop @Watch('resetDraft') winEnd: number = 0;
  /**
   * 窗口标签展示串：传入方必须已经过 `WindowTagUtil.displayTagLine()` 收敛，
   * 即"完整同休日|周末|可出行"这一档中文，最多三项。这里不再查文案表，
   * 也不接受原始枚举串——卡片与 sheet 说同一份数据是 D-01 的验收判据。
   */
  @Prop winTags: string = '';
  /**
   * 嵌入模式（Task 5.1 宽屏「列表—详情」双栏）：同一套表单不弹半模态，而是常驻详情栏。
   * 差别只在容器——不画顶部句柄、四角都圆、不铺系统玻璃（规范里材质只给 Sheet/浮层）。
   */
  inline: boolean = false;
  /** 关闭（取消/创建成功后由父页收回 sheet）。 */
  onClose: () => void = () => {};
  onCreated: (planId: string) => void = () => {};

  @State kindIdx: number = 0;
  @State title: string = '';
  @State planStart: number = 0;
  @State planEnd: number = 0;
  /** -1 收起，0 开始，1 结束；编辑允许临时倒置或越界，不擅自挪动另一端。 */
  @State private customTimeEnd: number = -1;
  private pickerGeneration: number = 0;
  @State saving: boolean = false;
  @State private submitFeedback: string = '';
  /** Ambiguous writes must resolve the original durable request, not create another invitation. */
  @State private reviewOriginal: boolean = false;
  @State private created: boolean = false;
  private createdPlanId: string = '';
  private createdMessage: string = '';
  private successTimer: number = -1;
  private draftGeneration: number = 0;
  private mounted: boolean = false;
  /** 是否写进应用专属「同休日」日历（受管：改期与取消会自动跟着同步）。默认开。 */
  @State writeToCalendar: boolean = true;
  @State private cloudPlan: boolean = false;
  /** 用户是否手动调过起止：异步补来的"避开作息"起点不得覆盖他已经选好的时间。 */
  private timeTouched: boolean = false;
  // 装饰器实参必须是字面量，取值与 SENIOR_MODE_KEY 保持一致。
  @StorageProp('crd_senior_mode') senior: boolean = false;
  @StorageProp('crd_reduce_motion') reduceMotion: boolean = false;
  @StorageProp('crd_app_foreground') @Watch('onForegroundChanged') foreground: boolean = true;
  /** 探头休休是否已落位：false 是 CSS 的 translateY(130%) 起点，onAppear 里 animateTo 推到 true。 */
  @State private peekRisen: boolean = false;

  aboutToAppear(): void {
    this.mounted = true;
    this.resetDraft();
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.draftGeneration++;
    this.cancelSuccessTimer();
  }

  private cancelSuccessTimer(): void {
    if (this.successTimer >= 0) { clearTimeout(this.successTimer); this.successTimer = -1; }
  }

  closeSheet(): void {
    this.draftGeneration++;
    this.cancelSuccessTimer();
    this.onClose();
  }

  onForegroundChanged(): void {
    this.cancelSuccessTimer();
    if (!this.foreground) { this.pickerGeneration++; }
    if (this.foreground && this.created && this.mounted) { this.holdSuccess(); }
  }

  private holdSuccess(): void {
    this.cancelSuccessTimer();
    if (!this.foreground) { return; }
    const request = this.draftGeneration;
    const planId = this.createdPlanId;
    const message = this.createdMessage;
    this.successTimer = setTimeout(() => {
      this.successTimer = -1;
      if (!this.mounted || request !== this.draftGeneration || !this.created) { return; }
      // 固定顺序且只通知一次；父页负责关闭和定位刚保存的计划。
      this.created = false;
      this.onClose();
      this.onCreated(planId);
      appToast(message);
    }, SUCCESS_HOLD_MS);
  }

  /** 按当前窗口重置草稿（口径在 PlanFlow.defaultDraft，和恢复/换窗口重开共用一份）。 */
  resetDraft(): void {
    this.cloudPlan = FeatureFlags.sharedPlan && SettingsStore.getPairState() === PAIRED;
    this.draftGeneration++;
    this.cancelSuccessTimer();
    this.created = false;
    this.createdPlanId = '';
    this.createdMessage = '';
    this.saving = false;
    this.submitFeedback = '';
    this.reviewOriginal = false;
    this.customTimeEnd = -1;
    this.pickerGeneration++;
    const draft: PlanDraft = defaultDraft(this.winStart, this.winEnd, PLAN_KINDS[0].label,
      PLAN_KINDS[0].key, null, nowEpochMin());
    this.kindIdx = 0;
    this.timeTouched = false;
    this.title = draft.title;
    this.planStart = draft.start;
    this.planEnd = draft.end;
    this.arrangePastOwnRhythm();
  }

  /**
   * 把默认起点挪到双方都排不开的时间之外（D-25 / D-28）：旅行通道的窗口只扣真忙、不扣睡眠，
   * 一段连续休息的窗口从 00:00 就开始，于是"点开窗口不改动任何参数直接保存"的第一条计划
   * 必然收到一句"落在你的作息时段外"——那是本应用自己给的答案反驳自己。
   * 本机代录态与云配对态下这一份都含 TA 的作息，所以清晨那段只要 TA 还在睡就不会再被建议成起点。
   *
   * 不可用区间要读班表才算得出来，所以先按窗口起点同步给一版草稿、再异步纠正一次；
   * 期间用户已经调过时间或换了窗口就丢掉这次结果，取数失败也维持原草稿（冲突解释链照旧会说）。
   * TA 那半边只读缓存的最后一次有效快照或本机代录，不在这一次发云请求——半模态等不起云函数超时。
   */
  private async arrangePastOwnRhythm(): Promise<void> {
    const request = this.draftGeneration;
    const winStart = this.winStart;
    const winEnd = this.winEnd;
    let unavailable: Interval[] = [];
    try {
      unavailable = await ScheduleUseCase.unavailableForDraftOver(winStart, winEnd);
    } catch (e) {
      Logger.warn(TAG, 'load my unavailable failed: ' + (e as Error).message);
      return;
    }
    if (!this.mounted || request !== this.draftGeneration || this.saving || this.reviewOriginal
      || this.timeTouched || this.winStart !== winStart || this.winEnd !== winEnd) {
      return;
    }
    const draft: PlanDraft = defaultDraft(winStart, winEnd, this.title, PLAN_KINDS[this.kindIdx].key,
      unavailable, nowEpochMin());
    this.planStart = draft.start;
    this.planEnd = draft.end;
  }

  // ---------- 时间步进（与自定义编辑一样，提交时才校验业务范围） ----------

  shiftStart(delta: number): void {
    if (this.saving || this.reviewOriginal) { return; }
    this.pickerGeneration++;
    this.timeTouched = true;
    this.planStart = this.planStart + delta;
  }

  shiftEnd(delta: number): void {
    if (this.saving || this.reviewOriginal) { return; }
    this.pickerGeneration++;
    this.timeTouched = true;
    this.planEnd = this.planEnd + delta;
  }

  // ---------- 自定义日期时间（只编辑草稿，提交时才校验） ----------

  toggleCustomTime(end: boolean): void {
    if (this.saving || this.reviewOriginal) { return; }
    this.timeTouched = true;
    this.pickerGeneration++;
    const selected = end ? 1 : 0;
    this.customTimeEnd = this.customTimeEnd === selected ? -1 : selected;
  }

  private acceptsTimePicker(request: number, picker: number, end: boolean): boolean {
    return this.mounted && this.foreground && !this.saving && !this.reviewOriginal && request === this.draftGeneration
      && picker === this.pickerGeneration && this.customTimeEnd === (end ? 1 : 0);
  }

  private setCustomTime(end: boolean, value: number): void {
    if (!Number.isSafeInteger(value)) { return; }
    this.timeTouched = true;
    if (end) { this.planEnd = value; } else { this.planStart = value; }
  }

  private pickCustomDate(end: boolean): void {
    if (!this.mounted || !this.foreground || this.saving) { return; }
    const request = this.draftGeneration;
    const picker = ++this.pickerGeneration;
    const current = end ? this.planEnd : this.planStart;
    const parts = DateLabel.ymd(dayOfStart(current));
    try {
      this.getUIContext().showDatePickerDialog({ selected: new Date(parts.y, parts.m - 1, parts.d),
        onDateAccept: (value: Date) => {
          if (!this.acceptsTimePicker(request, picker, end) || !Number.isFinite(value.getTime())) { return; }
          this.setCustomTime(end, epochDayOf(value.getFullYear(), value.getMonth() + 1, value.getDate())
            * MIN_PER_DAY + ((current % MIN_PER_DAY) + MIN_PER_DAY) % MIN_PER_DAY);
        } });
    } catch {
      appToast('日期选择暂不可用，请重试');
    }
  }

  private pickCustomClock(end: boolean): void {
    if (!this.mounted || !this.foreground || this.saving) { return; }
    const request = this.draftGeneration;
    const picker = ++this.pickerGeneration;
    const current = end ? this.planEnd : this.planStart;
    const parts = DateLabel.ymd(dayOfStart(current));
    const minute = ((current % MIN_PER_DAY) + MIN_PER_DAY) % MIN_PER_DAY;
    try {
      this.getUIContext().showTimePickerDialog({
        selected: new Date(parts.y, parts.m - 1, parts.d, Math.floor(minute / 60), minute % 60),
        useMilitaryTime: true,
        onAccept: (value: TimePickerResult) => {
          if (!this.acceptsTimePicker(request, picker, end) || value.hour === undefined || value.minute === undefined
            || !Number.isInteger(value.hour) || value.hour < 0 || value.hour > 23
            || !Number.isInteger(value.minute) || value.minute < 0 || value.minute > 59) { return; }
          this.setCustomTime(end, dayOfStart(current) * MIN_PER_DAY + value.hour * 60 + value.minute);
        }
      });
    } catch {
      appToast('时间选择暂不可用，请重试');
    }
  }

  private customDateLabel(end: boolean): string {
    const day = dayOfStart(end ? this.planEnd : this.planStart);
    return DateLabel.ymd(day).y + '年' + DateLabel.md(day);
  }

  // ---------- 类型与标题 ----------

  pickKind(idx: number): void {
    if (this.saving || this.reviewOriginal) return;
    if (!Number.isInteger(idx) || idx < 0 || idx >= PLAN_KINDS.length) return;
    // 固定分类总是同步标题；「其他」只改变类型，不清空或替换当前标题。
    if (PLAN_KINDS[idx].key !== OTHER_PLAN_KIND_KEY) this.title = PLAN_KINDS[idx].label;
    this.kindIdx = idx;
  }

  onTitleChange(v: string): void {
    if (this.saving || this.reviewOriginal) return;
    this.title = v;
  }

  // ---------- 时间轴端点文字 ----------

  /**
   * 跨日窗口两端都写「00:00」，读者判不出比例尺（D-13），所以跨日时端点带日期。
   * 同一天不带的理由是上方 hero 已经念过「9月24日 周四 07:00–22:30」，重复一遍只会挤掉中间那行。
   * 「端点算哪一天、怎么念」两条判定都在 {@link DateLabel}（edgeDay／edgeTime），视图里不再抄第三份（D-58）。
   */
  private crossesDays(): boolean {
    return DateLabel.edgeDay(this.winEnd, true) > DateLabel.edgeDay(this.winStart, false);
  }

  private edgeLabel(min: number, isEnd: boolean): string {
    const day = DateLabel.edgeDay(min, isEnd);
    const time = DateLabel.edgeTime(min, isEnd);
    return this.crossesDays() ? DateLabel.md(day) + ' ' + time : time;
  }

  /**
   * 起止两行的读数（D-44）：日期按"看的那一刻"现算，所以草稿开着跨过零点，
   * 标签会跟着从「今天」翻成「明天」，不会留一个已经不成立的相对词。
   */
  private stampOf(min: number, isEnd: boolean): string {
    return DateLabel.stamp(min, isEnd, todayEpochDay());
  }

  // ---------- 创建 ----------

  async submitPlan(): Promise<void> {
    if (this.saving || !this.mounted) {
      return;
    }
    const draft: PlanDraft = {
      title: this.title, kind: PLAN_KINDS[this.kindIdx].key, start: this.planStart, end: this.planEnd
    };
    // 自定义和步进都允许中间态；确认时统一校验，再进入本地/云端写入。
    const invalid = this.reviewOriginal ? '' : planDraftError(draft, this.winStart, this.winEnd);
    if (invalid !== '') {
      appToast(invalid);
      return;
    }
    this.saving = true;
    this.submitFeedback = '';
    this.pickerGeneration++;
    const request = this.draftGeneration;
    const options: CreatePlanOptions = { writeToCalendar: this.writeToCalendar };
    try {
      if (this.cloudPlan) {
        const shared = secureSharedPlans();
        const content: SharedPlanContent = { title: draft.title.trim(), kind: draft.kind,
          start: draft.start, end: draft.end };
        const code = this.reviewOriginal ? await shared.retry() : await shared.propose(content);
        if (code !== 'OK' && code !== 'SAVED_RECOMPUTE_PENDING') {
          if (this.mounted && request === this.draftGeneration) {
            // Preserve the original draft after an uncertain result, including after closing/reopening.
            this.reviewOriginal = (this.reviewOriginal && code !== 'NOTHING_TO_RETRY') || sharedPlanNeedsReview(code);
            const detail = sharedPlanDiagnosticText(shared.diagnostic());
            this.submitFeedback = sharedResultMessage(code) + (detail === '' ? '' : '\n\n' + detail);
            appToast(sharedResultMessage(code)); this.saving = false;
          }
          return;
        }
        this.createdPlanId = shared.lastCreatedId();
        if (this.createdPlanId === '') {
          if (this.mounted && request === this.draftGeneration) {
            this.reviewOriginal = false; this.saving = false;
            this.submitFeedback = '原请求已核实，请查看计划页。若要发送当前草稿，请再次点击「发送计划邀请」。';
          }
          return;
        }
        publishPlanSaved(this.createdPlanId);
        if (!this.mounted || request !== this.draftGeneration) return;
        this.createdMessage = '邀请已发出，等待对方确认；确认前不占用双方时间';
        this.created = true; this.holdSuccess(); return;
      }
      const r = await PlanUseCase.createPlan(this.winStart, this.winEnd, draft.title, draft.kind,
        draft.start, draft.end, options);
      if (!r.ok) {
        if (this.mounted && request === this.draftGeneration) {
          appToast(r.error);
          this.saving = false;
        }
        return;
      }
      // 计划已真实落地，即使用户已退出也保留下一次列表定位信号。
      publishPlanSaved(r.planId);
      if (!this.mounted || request !== this.draftGeneration) { return; }
      this.createdMessage = isOnSystemCalendar(r.calendarState)
        ? '计划已创建，并写入系统日历' : '计划已创建（' + LOCAL_ONLY_NOTE + '）';
      this.createdPlanId = r.planId;
      this.created = true;
      this.holdSuccess();
    } catch (e) {
      Logger.warn(TAG, 'create plan failed: ' + (e as Error).message);
      if (this.mounted && request === this.draftGeneration) {
        this.saving = false;
        if (this.cloudPlan) {
          this.reviewOriginal = true;
          this.submitFeedback = '结果待核实，请点「核实 / 重试」。原请求会保留，不会重复创建邀请。';
        }
        appToast('暂时没能创建计划，请再试一次');
      }
    }
  }

  build() {
    // 自定义组件不吃链式属性，宽高由外层承担
    if (this.inline) {
      Column() {
        this.formBody(false)
      }
      .width('100%')
      .height('100%')
      .borderRadius(DesignTokens.radiusCard)
      .clip(true)
      // 卡片底而不是玻璃：详情栏是常驻面板，不是浮层
      .backgroundColor(DesignTokens.card)
    } else {
      // 透明带容纳完整耳朵；休休下沿贴住粉色摘要卡片，不以 sheet 白色面沿为落点。
      Stack({ alignContent: Alignment.TopStart }) {
        // 面由本组件自己画（与 PrivacyPolicySheet 同一份配方）：02 的 .sheet 是一条
        // 顶亮下页色的不透明渐变，本来就不是玻璃。走 GlassSurface 的材质路径时，
        // bindSheet 里那一层只留下透明填充，底下的周历格直接透上来（批次 Q·Q2）。
        Column() {
          this.formBody(true)
        }
        .width('100%')
        .height('100%')
        .backgroundColor(DesignTokens.page)
        .linearGradient(DesignTokens.sheetGradient())
        .borderRadius({ topLeft: DesignTokens.radiusSheet, topRight: DesignTokens.radiusSheet })
        .clip(true)

        // 透明带在 sheet 窗口之内，系统不把它当遮罩：不垫这一层，上沿多出来的 36.4vp
        // 就从"点一下就收起"变成点了没反应的死区（改之前那一行像素属于遮罩）。
        Column()
          .width('100%')
          .height(PEEK_OUT)
          .margin({ top: -PEEK_OUT })
          .onClick(() => {
            this.closeSheet();
          })

        Image($r('app.media.xiuxiu_peek'))
          .width(PEEK_W)
          .height(PEEK_H)
          .objectFit(ImageFit.Contain)
          .sourceSize({ width: 384, height: 358 })
          .draggable(false)
          .margin({ left: PEEK_LEFT, top: PEEK_MARGIN_TOP })
          .translate({ y: this.peekRisen ? 0 : PEEK_RISE_Y })
          // 透明兔子不加组件外框阴影，避免显露矩形边界；保留原位移与点击穿透。
          // 系统给 sheet 里的每个节点都挂了拖拽/长按识别器，所以这张图是"活跃节点"：
          // 默认档会阻塞兄弟，实测点在它占的那截透明带上收不起半模态（t20），
          // Transparent 才既让它跟着拖 sheet、又把点击放行给下面的垫片。
          .hitTestBehavior(HitTestMode.Transparent)
          // 签名动作，不承载信息；sheet 里的读数才是内容
          .accessibilityLevel('no')
          .onAppear(() => {
            this.risePeek();
          })
      }
      .width('100%')
      .height('100%')
      .padding({ top: PEEK_OUT })
      .hitTestBehavior(HitTestMode.Transparent)
    }
  }

  /** 探头落位：CSS `.sheet-peek` 的 translateY(130%)→0，spring 500ms；减少动效时时长归 0 直接落位。 */
  private risePeek(): void {
    this.getUIContext().animateTo({
      duration: DesignTokens.motion(this.reduceMotion, PEEK_MS),
      curve: DesignTokens.curve
    }, () => {
      this.peekRisen = true;
    });
  }

  /** 表单体：withHandle 决定要不要半模态的顶部句柄与贴底留白。 */
  @Builder
  formBody(withHandle: boolean) {
    Column() {
      if (withHandle) {
        // 顶部句柄
        Column()
          .width(44).height(5).borderRadius(3).backgroundColor(DesignTokens.sheetHandle)
          .margin({ top: 10, bottom: 12 })
          .accessibilityLevel('no')
      }

      Scroll() {
        Column({ space: 14 }) {
          this.windowSummary()
          this.timeline()
          this.planForm()
        }
        .width('100%')
        .padding({ left: 20, right: 20 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)

      if (this.submitFeedback !== '') {
        Text(this.submitFeedback).fontSize(12).fontColor(DesignTokens.textSecondary)
          .width('100%').padding({ left: 20, right: 20, top: 10, bottom: 10 })
          .backgroundColor(DesignTokens.fillWeak)
      }

      // ⑥ 底部操作（胶囊双按钮）
      Row({ space: 10 }) {
        Button(withHandle ? '取消' : '收起')
          .layoutWeight(1).constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
          .borderRadius(22)
          .backgroundColor($r('app.color.fill_weak')).fontColor($r('app.color.text_secondary'))
          .fontWeight(FontWeight.Bold)
          .shadow(DesignTokens.jelly(DesignTokens.borderWeak, DesignTokens.jellyDepth))
          .enabled(!this.created)
          .onClick(() => this.closeSheet())
        Button() {
          Row({ space: 6 }) {
            if (this.saving && !this.created) {
              LoadingProgress().width(16).height(16).color(DesignTokens.heroText).accessibilityLevel('no')
            }
            Text(this.created ? (this.cloudPlan ? '✓ 已发送' : '✓ 已创建')
              : (this.saving ? '处理中…' : (this.reviewOriginal ? '核实 / 重试' : (this.cloudPlan ? '发送计划邀请' : '创建计划'))))
              .fontColor(DesignTokens.heroText).fontWeight(FontWeight.Bold)
          }.justifyContent(FlexAlign.Center)
        }
          .layoutWeight(1).constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
          .borderRadius(22)
          .backgroundColor(this.created ? DesignTokens.successAction : DesignTokens.primary)
          .animation({ duration: DesignTokens.motion(this.reduceMotion, 140), curve: Curve.EaseOut })
          .stateEffect(false)
          .fontWeight(FontWeight.Bold)
          .shadow(DesignTokens.jelly(this.created ? DesignTokens.successAction : DesignTokens.primaryDeep,
            DesignTokens.jellyDepth))
          .enabled(!this.saving)
          .onClick(() => this.submitPlan())
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 8, bottom: withHandle ? 24 : 14 })
    }
    .width('100%')
    .height('100%')
    // 底色只由外层容器给（玻璃或卡片底），内容层不再叠一层不透明背景
    .backgroundColor(Color.Transparent)
  }

  /** ① 窗口摘要（渐变头，白字固定对比）。 */
  @Builder
  windowSummary() {
    Column({ space: 6 }) {
      Text(DateLabel.mdw(dayOfStart(this.winStart)))
        .fontSize(17).fontWeight(FontWeight.Bold).fontColor(DesignTokens.heroText)
      Text(DateLabel.endLabel(this.winStart, this.winEnd)
        + ' · 共 ' + DateLabel.duration(this.winEnd - this.winStart))
        .fontSize(13).fontColor(DesignTokens.heroText).opacity(0.72)
      if (this.winTags !== '') {
        Text(this.winTags.split('|').join(' · '))
          .fontSize(11).fontColor(DesignTokens.heroText).opacity(0.72)
      }
    }
    .width('100%')
    .padding({ top: 16, bottom: 16 })
    .borderRadius(DesignTokens.heroRadius())
    .linearGradient({
      angle: 135,
      colors: [[DesignTokens.sunsetFrom, 0], [DesignTokens.primary, 0.48], [DesignTokens.sunsetTo, 1]]
    })
    .alignItems(HorizontalAlign.Center)
    // 日期 / 起止 / 标签三行说的是同一个窗口，合成一句读，避免读屏逐行断句
    .accessibilityGroup(true)
    .accessibilityText(DateLabel.mdw(dayOfStart(this.winStart)) + ' '
      + DateLabel.endLabel(this.winStart, this.winEnd) + '，共 '
      + DateLabel.duration(this.winEnd - this.winStart)
      + (this.winTags === '' ? '' : '，' + this.winTags.split('|').join('、')))
  }

  /** ② 时间轴：窗口底条 + 计划区间高亮预览。 */
  @Builder
  timeline() {
    Column({ space: 4 }) {
      Row() {
        PlanRangePreview({ winStart: this.winStart, winEnd: this.winEnd,
          planStart: this.planStart, planEnd: this.planEnd })
      }
      .width('100%')
      // 纯预览条：读屏念下面的起止文字就够了，色块本身没有可朗读内容
      .accessibilityLevel('no')

      Row() {
        Text(this.edgeLabel(this.winStart, false)).fontSize(10).fontColor($r('app.color.text_hint'))
        Blank()
        Text('整段 ' + DateLabel.duration(this.winEnd - this.winStart))
          .fontSize(10).fontColor($r('app.color.text_secondary'))
        Blank()
        Text(this.edgeLabel(this.winEnd, true)).fontSize(10).fontColor($r('app.color.text_hint'))
      }
      .width('100%')
      .accessibilityGroup(true)
      // 计划区间在条上只是高亮色块，读屏拿不到，所以朗读里保留它，视觉上让位给窗口总长
      .accessibilityText('窗口 ' + this.edgeLabel(this.winStart, false) + ' 到 '
        + this.edgeLabel(this.winEnd, true) + '，整段 ' + DateLabel.duration(this.winEnd - this.winStart)
        + '，计划 ' + DateLabel.endLabel(this.planStart, this.planEnd))
    }
    .width('100%')
    .padding({ left: 4, right: 4 })
  }

  /** 自定义入口在原弹窗内展开；系统选择器只负责单个日期/时间，不做业务范围限制。 */
  @Builder
  customTimeEditor(end: boolean) {
    Row({ space: 8 }) {
      Button(this.customDateLabel(end))
        .layoutWeight(1).constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
        .fontSize(12).borderRadius(14).stateEffect(false)
        .backgroundColor(DesignTokens.card).fontColor(DesignTokens.textPrimary)
        .accessibilityText('自定义' + (end ? '结束' : '开始') + '日期，' + this.customDateLabel(end))
        .onClick(() => this.pickCustomDate(end))
      // 编辑器搭配实际日历日，午夜显示次日 00:00；摘要仍按区间终点显示前日 24:00。
      Button(DateLabel.edgeTime(end ? this.planEnd : this.planStart, false))
        .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior), minWidth: 76 })
        .fontSize(14).borderRadius(14).stateEffect(false)
        .backgroundColor(DesignTokens.card).fontColor(DesignTokens.primaryDeep)
        .accessibilityText('自定义' + (end ? '结束' : '开始') + '时间')
        .onClick(() => this.pickCustomClock(end))
    }
    .width('100%').padding(8).borderRadius(18)
    .backgroundColor($r('app.color.fill_weak'))
  }

  /** ③–⑤ 表单区：玻璃之上再铺一层近实色子表面，保证输入与按钮的可读性。 */
  @Builder
  planForm() {
    Column({ space: 12 }) {
      // ③ 计划类型
      Column({ space: 8 }) {
        Text('计划类型').fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(PLAN_KINDS, (k: PlanKindOption, idx: number) => {
            Column() {
              Chip({
                label: { text: k.label, fontSize: 12, fontColor: $r('app.color.text_secondary'),
                  activatedFontColor: DesignTokens.heroText },
                activated: this.kindIdx === idx,
                backgroundColor: $r('app.color.fill_weak'),
                activatedBackgroundColor: $r('app.color.brand_pink'),
                allowClose: false,
                onClicked: () => this.pickKind(idx)
              })
            }
            .margin({ right: 8, bottom: 8 })
            // Chip 是自定义组件，吃不到通用无障碍属性，朗读名挂在外层容器上。
            // 选中态原来只有底色一种表达，色觉与读屏用户都分辨不出选了哪个类型。
            // 同时去掉 size: ChipSize.SMALL：小档把高度压死，44vp 热区和长辈模式的放大都没了空间。
            // （SDK 只在 ChipOptions.size 传具体宽高时写明"适老化尺寸调节不生效"，
            //  api/@ohos.arkui.advanced.Chip.d.ets:939；SMALL 档是否同样禁用无证据，真机实测再判。）
            .accessibilityGroup(true)
            .accessibilityText(k.label + (this.kindIdx === idx ? '，当前类型' : '，点按选为计划类型'))
          }, (k: PlanKindOption) => k.key)
        }.width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      // ④ 标题
      Row({ space: 12 }) {
        Text('标题').fontSize(13).fontColor($r('app.color.text_secondary'))
          .flexShrink(0)
        TextInput({ text: this.title, placeholder: '给这个计划起个名字' })
          // 固定 height 会在大字体下把文字切掉，改成高度下限让输入框跟着文字长
          .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) }).layoutWeight(1)
          // 7 分甜的输入框是一颗白糖：浅粉描边 + 16vp 圆角，不再是灰底方框
          .borderRadius(DesignTokens.radiusInput)
          .border({ width: 1.5, color: DesignTokens.primaryBorder })
          .backgroundColor(DesignTokens.card)
          .accessibilityText('计划标题')
          .onChange((v: string) => this.onTitleChange(v))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // ⑤ 起止调节（快捷步进与自定义，保存时统一校验）
      Column({ space: 8 }) {
        Text('时间调节')
          .fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')

        Row({ space: 6 }) {
          Text('开始').fontSize(13).constraintSize({ minWidth: 28 }).flexShrink(0)
          Text(this.stampOf(this.planStart, false))
            .fontSize(13).fontWeight(FontWeight.Medium).layoutWeight(1).maxLines(2)
            .textAlign(TextAlign.Center)
            .accessibilityText('计划开始 ' + this.stampOf(this.planStart, false))
          Button('−' + STEP_MIN).constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .width(AccessibilityPolicy.minHit(this.senior)).padding(0)
            .fontSize(12)
            .backgroundColor($r('app.color.fill_weak')).fontColor($r('app.color.text_secondary'))
            .fontWeight(FontWeight.Bold)
            .shadow(DesignTokens.jelly(DesignTokens.borderWeak, DesignTokens.jellyDepth))
            .accessibilityText('开始时间提前 ' + STEP_MIN + ' 分钟')
            .onClick(() => this.shiftStart(-STEP_MIN))
          Button('+' + STEP_MIN).constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .width(AccessibilityPolicy.minHit(this.senior)).padding(0)
            .fontSize(12)
            .backgroundColor($r('app.color.fill_weak')).fontColor($r('app.color.text_secondary'))
            .fontWeight(FontWeight.Bold)
            .shadow(DesignTokens.jelly(DesignTokens.borderWeak, DesignTokens.jellyDepth))
            .accessibilityText('开始时间推迟 ' + STEP_MIN + ' 分钟')
            .onClick(() => this.shiftStart(STEP_MIN))
          Button('…').width(AccessibilityPolicy.minHit(this.senior))
            .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) }).padding(0)
            .fontSize(18).stateEffect(false)
            .backgroundColor(this.customTimeEnd === 0 ? DesignTokens.primaryBorder : $r('app.color.fill_weak'))
            .fontColor(DesignTokens.textSecondary)
            .accessibilityText('自定义开始日期和时间')
            .accessibilityDescription(this.customTimeEnd === 0 ? '已展开，点按收起' : '点按展开')
            .onClick(() => this.toggleCustomTime(false))
        }.width('100%')
        if (this.customTimeEnd === 0) {
          this.customTimeEditor(false)
        }

        Row({ space: 6 }) {
          Text('结束').fontSize(13).constraintSize({ minWidth: 28 }).flexShrink(0)
          Text(this.stampOf(this.planEnd, true))
            .fontSize(13).fontWeight(FontWeight.Medium).layoutWeight(1).maxLines(2)
            .textAlign(TextAlign.Center)
            .accessibilityText('计划结束 ' + this.stampOf(this.planEnd, true))
          Button('−' + STEP_MIN).constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .width(AccessibilityPolicy.minHit(this.senior)).padding(0)
            .fontSize(12)
            .backgroundColor($r('app.color.fill_weak')).fontColor($r('app.color.text_secondary'))
            .fontWeight(FontWeight.Bold)
            .shadow(DesignTokens.jelly(DesignTokens.borderWeak, DesignTokens.jellyDepth))
            .accessibilityText('结束时间提前 ' + STEP_MIN + ' 分钟')
            .onClick(() => this.shiftEnd(-STEP_MIN))
          Button('+' + STEP_MIN).constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .width(AccessibilityPolicy.minHit(this.senior)).padding(0)
            .fontSize(12)
            .backgroundColor($r('app.color.fill_weak')).fontColor($r('app.color.text_secondary'))
            .fontWeight(FontWeight.Bold)
            .shadow(DesignTokens.jelly(DesignTokens.borderWeak, DesignTokens.jellyDepth))
            .accessibilityText('结束时间推迟 ' + STEP_MIN + ' 分钟')
            .onClick(() => this.shiftEnd(STEP_MIN))
          Button('…').width(AccessibilityPolicy.minHit(this.senior))
            .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) }).padding(0)
            .fontSize(18).stateEffect(false)
            .backgroundColor(this.customTimeEnd === 1 ? DesignTokens.primaryBorder : $r('app.color.fill_weak'))
            .fontColor(DesignTokens.textSecondary)
            .accessibilityText('自定义结束日期和时间')
            .accessibilityDescription(this.customTimeEnd === 1 ? '已展开，点按收起' : '点按展开')
            .onClick(() => this.toggleCustomTime(true))
        }.width('100%')
        if (this.customTimeEnd === 1) {
          this.customTimeEditor(true)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      if (this.cloudPlan) {
        Text('双方确认后占用时间')
          .fontSize(12).fontColor(DesignTokens.textSecondary)
      } else {
      Divider().color($r('app.color.divider'))

      // ⑦ 系统日历：默认写进应用专属日历（受管），关掉只留在应用里
      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Text('写入系统日历').fontSize(13).fontColor($r('app.color.text_secondary'))
          Text('改期、取消会同步到系统日历')
            .fontSize(11).fontColor($r('app.color.text_hint'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.writeToCalendar })
          .selectedColor($r('app.color.brand_pink'))
          // 原型把滑块画成一颗白心；ArkUI 的 Switch 滑块只能是圆，这里先把"白"落实
          .switchPointColor(DesignTokens.heroText)
          // 开关自己没有任何文字标签，读屏只会念"开/关"，说不出关的是哪件事
          .accessibilityText('写入系统日历')
          .accessibilityDescription('写进「同休日」日历，改期和取消会跟着同步；关掉就只留在应用里')
          .onChange((on: boolean) => {
            this.writeToCalendar = on;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .padding({
      left: 14, right: 14, top: 14, bottom: 14
    })
    .borderRadius(DesignTokens.radiusCard)
    .backgroundColor($r('app.color.fill_weakest'))
    .border({ width: 1, color: $r('app.color.border_weak') })
    .alignItems(HorizontalAlign.Start)
    .enabled(!this.saving && !this.reviewOriginal)
  }
}
