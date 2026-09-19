import { promptAction, Chip, ChipSize } from '@kit.ArkUI';
import { MIN_PER_DAY } from 'domain';
import { DateLabel } from 'commons';
import { PlanUseCase } from 'feature';
import { PLAN_KINDS, PlanKindOption } from '../util/PlanKindUtil';

const STEP_MIN = 15;
const MIN_PLAN_MIN = 15;
/** 新计划的默认时长（2 小时，超出窗口时收缩）。 */
const DEFAULT_PLAN_MIN = 120;

/**
 * 窗口详情半模态（US5 / FR-009）：
 * - 顶部：日期 + 窗口起止 + 时长 + 标签；
 * - 时间轴可视化：窗口横条 + 计划区间高亮预览（Row 比例布局）；
 * - 计划类型选择 + 标题（默认=类型名）；
 * - 起止调节：±15 分钟步进，硬限制在 [窗口起, 窗口止]（越界禁用）；
 * - 「创建计划」→ PlanUseCase.createPlan → 成功 toast（日历未写入时提示"仅本机提醒"）+ 关闭。
 */
@Component
export struct WindowDetailSheet {
  @Prop winStart: number = 0;
  @Prop winEnd: number = 0;
  /** 窗口标签（'|' 分隔，仅展示）。 */
  @Prop winTags: string = '';
  /** 关闭（取消/创建成功后由父页收回 sheet）。 */
  onClose: () => void = () => {};

  @State kindIdx: number = 0;
  @State title: string = '';
  @State planStart: number = 0;
  @State planEnd: number = 0;
  @State saving: boolean = false;
  private titleTouched: boolean = false;

  aboutToAppear(): void {
    this.planStart = this.winStart;
    this.planEnd = Math.min(this.winStart + DEFAULT_PLAN_MIN, this.winEnd);
    if (this.planEnd - this.planStart < MIN_PLAN_MIN) {
      this.planEnd = Math.min(this.winStart + MIN_PLAN_MIN, this.winEnd);
    }
    this.title = PLAN_KINDS[0].label;
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
    this.planStart = this.planStart + delta;
  }

  shiftEnd(delta: number): void {
    if (delta < 0 && !this.canShiftEndEarlier()) {
      return;
    }
    if (delta > 0 && !this.canShiftEndLater()) {
      return;
    }
    this.planEnd = this.planEnd + delta;
  }

  // ---------- 类型与标题 ----------

  pickKind(idx: number): void {
    const prev = PLAN_KINDS[this.kindIdx];
    // 标题未被手工修改（仍为上一类型默认名）时跟随类型切换；自定义则保留原文本
    if (!this.titleTouched || this.title === prev.label) {
      this.title = idx === PLAN_KINDS.length - 1 ? '' : PLAN_KINDS[idx].label;
      if (idx === PLAN_KINDS.length - 1) {
        this.titleTouched = true;
      }
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

  // ---------- 创建 ----------

  async create(): Promise<void> {
    if (this.saving) {
      return;
    }
    if (this.title.trim() === '') {
      promptAction.showToast({ message: '请填写计划标题' });
      return;
    }
    if (this.planEnd - this.planStart < MIN_PLAN_MIN) {
      promptAction.showToast({ message: '计划时长至少 ' + MIN_PLAN_MIN + ' 分钟' });
      return;
    }
    this.saving = true;
    try {
      const r = await PlanUseCase.createPlan(this.winStart, this.winEnd, this.title,
        PLAN_KINDS[this.kindIdx].key, this.planStart, this.planEnd);
      if (r.ok) {
        promptAction.showToast({
          message: r.calendarWritten ? '计划已创建，并写入系统日历' : '计划已创建（仅本机提醒）'
        });
        this.onClose();
      } else {
        promptAction.showToast({ message: r.error });
        this.saving = false;
      }
    } catch (e) {
      promptAction.showToast({ message: '创建失败：' + (e as Error).message });
      this.saving = false;
    }
  }

  build() {
    Column() {
      // 顶部句柄
      Column()
        .width(36).height(4).borderRadius(2).backgroundColor($r('app.color.sheet_handle'))
        .margin({ top: 10, bottom: 12 })

      Scroll() {
        Column({ space: 14 }) {
          // ① 窗口摘要（渐变头，白字固定对比）
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

          // ② 时间轴可视化：窗口横条 + 计划区间高亮预览
          Column({ space: 4 }) {
            Row() {
              Stack({ alignContent: Alignment.Start }) {
                // 窗口底条
                Row()
                  .width('100%').height(18)
                  .borderRadius(9)
                  .backgroundColor($r('app.color.brand_pink_border'))
                // 计划区间高亮
                Row()
                  .width(this.pctOfWindow(this.planEnd - this.planStart))
                  .height(18)
                  .borderRadius(9)
                  .backgroundColor($r('app.color.brand_pink'))
                  .margin({ left: this.pctOfWindow(this.planStart - this.winStart) })
              }.width('100%')
            }.width('100%')

            Row() {
              Text(DateLabel.hm(this.winStart)).fontSize(10).fontColor($r('app.color.text_hint'))
              Blank()
              Text('计划 ' + DateLabel.endLabel(this.planStart, this.planEnd)
                + '（' + DateLabel.duration(this.planEnd - this.planStart) + '）')
                .fontSize(10).fontColor($r('app.color.brand_pink'))
              Blank()
              Text(DateLabel.hm(this.winEnd)).fontSize(10).fontColor($r('app.color.text_hint'))
            }.width('100%')
          }
          .width('100%')
          .padding({ left: 4, right: 4 })

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
                    size: ChipSize.SMALL,
                    onClicked: () => this.pickKind(idx)
                  })
                }.margin({ right: 8, bottom: 8 })
              }, (k: PlanKindOption) => k.key)
            }.width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // ④ 标题
          Column({ space: 8 }) {
            Text('标题').fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
            TextInput({ text: this.title, placeholder: '给这个计划起个名字' })
              .height(40).width('100%')
              .onChange((v: string) => this.onTitleChange(v))
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // ⑤ 起止调节（±15 分钟步进，窗口内硬限制）
          Column({ space: 8 }) {
            Text('时间调节（±' + STEP_MIN + ' 分钟，限制在窗口内）')
              .fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')

            Row({ space: 10 }) {
              Text('开始').fontSize(13).width(36)
              Text(DateLabel.hm(this.planStart))
                .fontSize(15).fontWeight(FontWeight.Medium).width(56).textAlign(TextAlign.Center)
              Button('−' + STEP_MIN).height(32).fontSize(12)
                .backgroundColor($r('app.color.fill_weak')).fontColor($r('app.color.text_secondary'))
                .enabled(this.canShiftStartEarlier())
                .onClick(() => this.shiftStart(-STEP_MIN))
              Button('+' + STEP_MIN).height(32).fontSize(12)
                .backgroundColor($r('app.color.fill_weak')).fontColor($r('app.color.text_secondary'))
                .enabled(this.canShiftStartLater())
                .onClick(() => this.shiftStart(STEP_MIN))
            }.width('100%')

            Row({ space: 10 }) {
              Text('结束').fontSize(13).width(36)
              Text(DateLabel.hm(this.planEnd))
                .fontSize(15).fontWeight(FontWeight.Medium).width(56).textAlign(TextAlign.Center)
              Button('−' + STEP_MIN).height(32).fontSize(12)
                .backgroundColor($r('app.color.fill_weak')).fontColor($r('app.color.text_secondary'))
                .enabled(this.canShiftEndEarlier())
                .onClick(() => this.shiftEnd(-STEP_MIN))
              Button('+' + STEP_MIN).height(32).fontSize(12)
                .backgroundColor($r('app.color.fill_weak')).fontColor($r('app.color.text_secondary'))
                .enabled(this.canShiftEndLater())
                .onClick(() => this.shiftEnd(STEP_MIN))
            }.width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ left: 20, right: 20 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)

      // ⑥ 底部操作（胶囊双按钮）
      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1).height(44).borderRadius(22)
          .backgroundColor($r('app.color.fill_weak')).fontColor($r('app.color.text_secondary'))
          .onClick(() => this.onClose())
        Button(this.saving ? '创建中…' : '创建计划')
          .layoutWeight(1).height(44).borderRadius(22)
          .backgroundColor($r('app.color.brand_pink'))
          .enabled(!this.saving)
          .onClick(() => this.create())
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 8, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.card_bg'))
  }
}
