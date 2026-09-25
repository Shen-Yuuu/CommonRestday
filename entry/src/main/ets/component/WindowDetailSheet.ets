import { promptAction, Chip } from '@kit.ArkUI';
import { Interval, MIN_PER_DAY, todayEpochDay } from 'domain';
import { DateLabel, Logger } from 'commons';
import {
  CreatePlanOptions, isOnSystemCalendar, LOCAL_ONLY_NOTE, MIN_PLAN_MIN, OTHER_PLAN_KIND_KEY,
  PlanDraft, PlanKindOption, PLAN_KINDS, PlanUseCase, ScheduleUseCase, defaultDraft, planDraftError,
  DRAFT_GRID_MIN
} from 'feature';
import { DesignTokens } from '../theme/DesignTokens';
import { GlassStrength } from '../theme/MaterialPolicy';
import { GlassSurface } from './GlassSurface';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';

const STEP_MIN = DRAFT_GRID_MIN;
const TAG = 'WindowDetailSheet';

/**
 * 窗口详情半模态（US5 / FR-009）：
 * - 顶部：日期 + 窗口起止 + 时长 + 标签；
 * - 时间轴可视化：窗口横条 + 计划区间高亮预览（Row 比例布局）；条下方两端是窗口起止
 *   （跨日才带日期），中间标窗口总长——计划区间条上已高亮、下面表单里有数字，不再占这一行；
 * - 计划类型选择 + 标题（默认=类型名）+ 起止调节：±15 分钟步进，硬限制在 [窗口起, 窗口止]；
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

  @State kindIdx: number = 0;
  @State title: string = '';
  @State planStart: number = 0;
  @State planEnd: number = 0;
  @State saving: boolean = false;
  /** 是否写进应用专属「同休日」日历（受管：改期与取消会自动跟着同步）。默认开。 */
  @State writeToCalendar: boolean = true;
  private titleTouched: boolean = false;
  /** 用户是否手动调过起止：异步补来的"避开作息"起点不得覆盖他已经选好的时间。 */
  private timeTouched: boolean = false;
  // 装饰器实参必须是字面量，取值与 SENIOR_MODE_KEY 保持一致。
  @StorageProp('crd_senior_mode') senior: boolean = false;

  aboutToAppear(): void {
    this.resetDraft();
  }

  /** 按当前窗口重置草稿（口径在 PlanFlow.defaultDraft，和恢复/换窗口重开共用一份）。 */
  resetDraft(): void {
    const draft: PlanDraft = defaultDraft(this.winStart, this.winEnd, PLAN_KINDS[0].label,
      PLAN_KINDS[0].key, null, this.nowMin());
    this.kindIdx = 0;
    this.titleTouched = false;
    this.timeTouched = false;
    this.title = draft.title;
    this.planStart = draft.start;
    this.planEnd = draft.end;
    this.arrangePastOwnRhythm();
  }

  /** 当下，用的是模型那套"自 epoch 起的分钟"刻度（与 winStart/winEnd 同轴才能直接比）。 */
  private nowMin(): number {
    const d = new Date();
    return todayEpochDay() * MIN_PER_DAY + d.getHours() * 60 + d.getMinutes();
  }

  /**
   * 把默认起点挪到双方都排不开的时间之外（D-25 / D-28）：旅行通道的窗口只扣真忙、不扣睡眠，
   * 一段连续休息的窗口从 00:00 就开始，于是"点开窗口不改动任何参数直接保存"的第一条计划
   * 必然收到一句"落在你的作息时段外"——那是本应用自己给的答案反驳自己。
   * 本机代录态下这一份含 TA 的作息，所以清晨那段只要 TA 还在睡就不会再被建议成起点。
   *
   * 不可用区间要读班表才算得出来，所以先按窗口起点同步给一版草稿、再异步纠正一次；
   * 期间用户已经调过时间或换了窗口就丢掉这次结果，取数失败也维持原草稿（冲突解释链照旧会说）。
   */
  private async arrangePastOwnRhythm(): Promise<void> {
    const winStart = this.winStart;
    const winEnd = this.winEnd;
    let unavailable: Interval[] = [];
    try {
      unavailable = await ScheduleUseCase.unavailableForDraftOver(winStart, winEnd);
    } catch (e) {
      Logger.warn(TAG, 'load my unavailable failed: ' + (e as Error).message);
      return;
    }
    if (this.timeTouched || this.winStart !== winStart || this.winEnd !== winEnd) {
      return;
    }
    const draft: PlanDraft = defaultDraft(winStart, winEnd, this.title, PLAN_KINDS[this.kindIdx].key,
      unavailable, this.nowMin());
    this.planStart = draft.start;
    this.planEnd = draft.end;
  }

  // ---------- 时间步进（硬限制窗口内，越界禁用） ----------

  canShiftStartEarlier(): boolean {
    return this.planStart - STEP_MIN >= this.winStart;
  }

  canShiftStartLater(): boolean {
    return this.planStart + STEP_MIN <= this.planEnd - MIN_PLAN_MIN;
  }

  canShiftEndEarlier(): boolean {
    return this.planEnd - STEP_MIN >= this.planStart + MIN_PLAN_MIN;
  }

  canShiftEndLater(): boolean {
    return this.planEnd + STEP_MIN <= this.winEnd;
  }

  shiftStart(delta: number): void {
    if (delta < 0 && !this.canShiftStartEarlier()) {
      return;
    }
    if (delta > 0 && !this.canShiftStartLater()) {
      return;
    }
    this.timeTouched = true;
    this.planStart = this.planStart + delta;
  }

  shiftEnd(delta: number): void {
    if (delta < 0 && !this.canShiftEndEarlier()) {
      return;
    }
    if (delta > 0 && !this.canShiftEndLater()) {
      return;
    }
    this.timeTouched = true;
    this.planEnd = this.planEnd + delta;
  }

  // ---------- 类型与标题 ----------

  pickKind(idx: number): void {
    // 标题没被手工改过就跟着类型走；「其他」没有默认名，留空等用户自填。
    // 选了「其他」不置 titleTouched：只有两项时"点过去再点回来"很常见，钉住标题会让
    // 切回「一起吃饭」时默认名回不来。
    if (!this.titleTouched) {
      this.title = PLAN_KINDS[idx].key === OTHER_PLAN_KIND_KEY ? '' : PLAN_KINDS[idx].label;
    }
    this.kindIdx = idx;
  }

  onTitleChange(v: string): void {
    this.title = v;
    this.titleTouched = true;
  }

  // ---------- 时间轴比例（百分比字符串） ----------

  pctOfWindow(min: number): string {
    const total = this.winEnd - this.winStart;
    if (total <= 0) {
      return '0%';
    }
    const pct = Math.max(0, Math.min(100, min / total * 100));
    return pct.toFixed(2) + '%';
  }

  // ---------- 时间轴端点文字 ----------

  /** 端点落在哪个日历日：窗口结束若是整午夜，记在前一天的 24:00，与 DateLabel.endLabel 同一口径。 */
  private edgeDay(min: number, isEnd: boolean): number {
    if (isEnd && min % MIN_PER_DAY === 0) {
      return min / MIN_PER_DAY - 1;
    }
    return Math.floor(min / MIN_PER_DAY);
  }

  /**
   * 跨日窗口两端都写「00:00」，读者判不出比例尺（D-13），所以跨日时端点带日期。
   * 同一天不带的理由是上方 hero 已经念过「9月24日 周四 07:00–22:30」，重复一遍只会挤掉中间那行。
   */
  private crossesDays(): boolean {
    return this.edgeDay(this.winEnd, true) > this.edgeDay(this.winStart, false);
  }

  private edgeLabel(min: number, isEnd: boolean): string {
    const day = this.edgeDay(min, isEnd);
    const time = isEnd && min % MIN_PER_DAY === 0 ? '24:00' : DateLabel.hm(min);
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
    if (this.saving) {
      return;
    }
    const draft: PlanDraft = {
      title: this.title, kind: PLAN_KINDS[this.kindIdx].key, start: this.planStart, end: this.planEnd
    };
    // 越界在按钮上是禁用的，这里兜住"草稿还开着但窗口变了"的情况
    const invalid = planDraftError(draft, this.winStart, this.winEnd);
    if (invalid !== '') {
      promptAction.showToast({ message: invalid });
      return;
    }
    this.saving = true;
    const options: CreatePlanOptions = { writeToCalendar: this.writeToCalendar };
    const r = await PlanUseCase.createPlan(this.winStart, this.winEnd, draft.title, draft.kind,
      draft.start, draft.end, options);
    if (!r.ok) {
      promptAction.showToast({ message: r.error });
      this.saving = false;
      return;
    }
    promptAction.showToast({
      message: isOnSystemCalendar(r.calendarState) ? '计划已创建，并写入系统日历' : '计划已创建（' + LOCAL_ONLY_NOTE + '）'
    });
    // 成功即由父页收回，saving 保持 true 直到关闭：期间不再接受第二次提交
    this.onClose();
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
      Column() {
        GlassSurface({
          strength: GlassStrength.STRONG,
          radius: DesignTokens.radiusSheet,
          fallback: $r('app.color.card_bg'),
          topCornersOnly: true
        }) {
          this.formBody(true)
        }
      }
      .width('100%')
      .height('100%')
    }
  }

  /** 表单体：withHandle 决定要不要半模态的顶部句柄与贴底留白。 */
  @Builder
  formBody(withHandle: boolean) {
    Column() {
      if (withHandle) {
        // 顶部句柄
        Column()
          .width(36).height(4).borderRadius(2).backgroundColor($r('app.color.sheet_handle'))
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

      // ⑥ 底部操作（胶囊双按钮）
      Row({ space: 10 }) {
        Button(withHandle ? '取消' : '收起')
          .layoutWeight(1).constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
          .borderRadius(22)
          .backgroundColor($r('app.color.fill_weak')).fontColor($r('app.color.text_secondary'))
          .onClick(() => this.onClose())
        Button(this.saving ? '创建中…' : '创建计划')
          .layoutWeight(1).constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
          .borderRadius(22)
          .backgroundColor($r('app.color.brand_pink'))
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
      Text(DateLabel.mdw(Math.floor(this.winStart / MIN_PER_DAY)))
        .fontSize(17).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
      Text(DateLabel.endLabel(this.winStart, this.winEnd)
        + ' · 共 ' + DateLabel.duration(this.winEnd - this.winStart))
        .fontSize(13).fontColor('#FFFFFFB8')
      if (this.winTags !== '') {
        Text(this.winTags.split('|').join(' · '))
          .fontSize(11).fontColor('#FFFFFFB8')
      }
    }
    .width('100%')
    .padding({ top: 16, bottom: 16 })
    .borderRadius(20)
    .linearGradient({
      angle: 135,
      colors: [[$r('app.color.sunset_from'), 0], [$r('app.color.sunset_to'), 1]]
    })
    .alignItems(HorizontalAlign.Center)
    // 日期 / 起止 / 标签三行说的是同一个窗口，合成一句读，避免读屏逐行断句
    .accessibilityGroup(true)
    .accessibilityText(DateLabel.mdw(Math.floor(this.winStart / MIN_PER_DAY)) + ' '
      + DateLabel.endLabel(this.winStart, this.winEnd) + '，共 '
      + DateLabel.duration(this.winEnd - this.winStart)
      + (this.winTags === '' ? '' : '，' + this.winTags.split('|').join('、')))
  }

  /** ② 时间轴：窗口底条 + 计划区间高亮预览。 */
  @Builder
  timeline() {
    Column({ space: 4 }) {
      Row() {
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%').height(18)
            .borderRadius(9)
            .backgroundColor($r('app.color.brand_pink_border'))
          Row()
            .width(this.pctOfWindow(this.planEnd - this.planStart))
            .height(18)
            .borderRadius(9)
            .backgroundColor($r('app.color.brand_pink'))
            .margin({ left: this.pctOfWindow(this.planStart - this.winStart) })
        }.width('100%')
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
                label: { text: k.label, fontSize: 12, fontColor: $r('app.color.text_secondary'), activatedFontColor: '#FFFFFF' },
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
      Column({ space: 8 }) {
        Text('标题').fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
        TextInput({ text: this.title, placeholder: '给这个计划起个名字' })
          // 固定 height 会在大字体下把文字切掉，改成高度下限让输入框跟着文字长
          .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) }).width('100%')
          .accessibilityText('计划标题')
          .onChange((v: string) => this.onTitleChange(v))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      // ⑤ 起止调节（±15 分钟步进，窗口内硬限制）
      Column({ space: 8 }) {
        Text('时间调节（±' + STEP_MIN + ' 分钟，限制在窗口内）')
          .fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')

        Row({ space: 10 }) {
          Text('开始').fontSize(13).constraintSize({ minWidth: 36 })
          Text(this.stampOf(this.planStart, false))
            .fontSize(15).fontWeight(FontWeight.Medium).constraintSize({ minWidth: 96 })
            .textAlign(TextAlign.Center)
            .accessibilityText('计划开始 ' + this.stampOf(this.planStart, false))
          Button('−' + STEP_MIN).constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .fontSize(12)
            .backgroundColor($r('app.color.fill_weak')).fontColor($r('app.color.text_secondary'))
            .enabled(this.canShiftStartEarlier())
            .accessibilityText('开始时间提前 ' + STEP_MIN + ' 分钟')
            .onClick(() => this.shiftStart(-STEP_MIN))
          Button('+' + STEP_MIN).constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .fontSize(12)
            .backgroundColor($r('app.color.fill_weak')).fontColor($r('app.color.text_secondary'))
            .enabled(this.canShiftStartLater())
            .accessibilityText('开始时间推迟 ' + STEP_MIN + ' 分钟')
            .onClick(() => this.shiftStart(STEP_MIN))
        }.width('100%')

        Row({ space: 10 }) {
          Text('结束').fontSize(13).constraintSize({ minWidth: 36 })
          Text(this.stampOf(this.planEnd, true))
            .fontSize(15).fontWeight(FontWeight.Medium).constraintSize({ minWidth: 96 })
            .textAlign(TextAlign.Center)
            .accessibilityText('计划结束 ' + this.stampOf(this.planEnd, true))
          Button('−' + STEP_MIN).constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .fontSize(12)
            .backgroundColor($r('app.color.fill_weak')).fontColor($r('app.color.text_secondary'))
            .enabled(this.canShiftEndEarlier())
            .accessibilityText('结束时间提前 ' + STEP_MIN + ' 分钟')
            .onClick(() => this.shiftEnd(-STEP_MIN))
          Button('+' + STEP_MIN).constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .fontSize(12)
            .backgroundColor($r('app.color.fill_weak')).fontColor($r('app.color.text_secondary'))
            .enabled(this.canShiftEndLater())
            .accessibilityText('结束时间推迟 ' + STEP_MIN + ' 分钟')
            .onClick(() => this.shiftEnd(STEP_MIN))
        }.width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Divider().color($r('app.color.divider'))

      // ⑦ 系统日历：默认写进应用专属日历（受管），关掉只留在应用里
      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Text('写入系统日历').fontSize(13).fontColor($r('app.color.text_secondary'))
          Text('写进本应用专属的「同休日」日历，改期和取消会自动同步；关掉只留在应用里')
            .fontSize(11).fontColor($r('app.color.text_hint'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.writeToCalendar })
          .selectedColor($r('app.color.brand_pink'))
          // 开关自己没有任何文字标签，读屏只会念"开/关"，说不出关的是哪件事
          .accessibilityText('写入系统日历')
          .accessibilityDescription('写进本应用专属的「同休日」日历，改期和取消会自动同步；关掉只留在应用里')
          .onChange((on: boolean) => {
            this.writeToCalendar = on;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({
      left: 14, right: 14, top: 14, bottom: 14
    })
    .borderRadius(DesignTokens.radiusCard)
    .backgroundColor($r('app.color.fill_weakest'))
    .border({ width: 1, color: $r('app.color.border_weak') })
    .alignItems(HorizontalAlign.Start)
  }
}
