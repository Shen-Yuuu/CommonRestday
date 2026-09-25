import { promptAction } from '@kit.ArkUI';
import { OWNER_ME, ShiftType } from 'domain';
import { DateLabel } from 'commons';
import {
  DayShiftState, ScheduleCommandResult, ScheduleCommandService, ScheduleOverviewQueryService
} from 'feature';
import { DesignTokens } from '../theme/DesignTokens';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';

/** 休息哨兵：覆盖表用 shiftTypeId=null 表示"这天强制休息"，组件内统一用空串表达。 */
const REST_ID = '';

/**
 * 单日改班半模态（「临时调整」主入口）：只写这一天的覆盖，不动循环模板。
 * 覆盖与月历涂抹是同一条数据（覆盖优先于模板展开），清除后即回到模板推算值；
 * 长期规律请去循环模板，这里只解决"就这天不一样"。
 */
@Component
export struct DayShiftSheet {
  @Prop @Watch('reload') owner: string = OWNER_ME;
  /** 目标日（epochDay）：点周历日格进入时由父页给。 */
  @Prop @Watch('reload') epochDay: number = 0;
  onClose: () => void = () => {
  };
  @State private types: ShiftType[] = [];
  /** 循环模板推算的当日班次（'' = 休）；无模板时恒为 ''。 */
  @State private baseId: string = '';
  @State private hasTpl: boolean = false;
  /** 手动覆盖是否存在（null 覆盖=休息，所以必须单独记一位）。 */
  @State private hasOv: boolean = false;
  @State private ovId: string = REST_ID;
  @State private loading: boolean = true;
  @State private saving: boolean = false;
  // 装饰器实参必须是字面量，取值与 SENIOR_MODE_KEY 保持一致。
  @StorageProp('crd_senior_mode') senior: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  reload(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    try {
      const st: DayShiftState = await ScheduleOverviewQueryService.getDayShiftState(this.owner,
        this.epochDay);
      this.types = st.types;
      this.hasTpl = st.hasTemplate;
      this.baseId = st.baseTypeId;
      this.hasOv = st.hasOverride;
      this.ovId = st.overrideTypeId;
    } catch (e) {
      this.types = [];
      this.hasOv = false;
      this.ovId = REST_ID;
      this.baseId = REST_ID;
    }
    this.loading = false;
  }

  /** 当日实际生效班次：覆盖优先，其次模板。 */
  private effectiveId(): string {
    return this.hasOv ? this.ovId : this.baseId;
  }

  private isSelected(id: string): boolean {
    return this.effectiveId() === id;
  }

  private nameOf(id: string): string {
    if (id === REST_ID) {
      return '休息';
    }
    for (let i = 0; i < this.types.length; i++) {
      if (this.types[i].id === id) {
        return this.types[i].name;
      }
    }
    // 覆盖指向的班次可能已在管理页删除，这里说清状态而不是留空
    return '已删除的班次';
  }

  private colorOf(id: string): ResourceColor {
    for (let i = 0; i < this.types.length; i++) {
      if (this.types[i].id === id) {
        return this.types[i].color;
      }
    }
    return DesignTokens.fillWeak;
  }

  private currentNote(): string {
    if (this.hasOv) {
      return '手动覆盖 · ' + this.nameOf(this.ovId);
    }
    return (this.hasTpl ? '循环模板推算 · ' : '未配置模板 · ') + this.nameOf(this.baseId);
  }

  // ---------- 写入（一次一条覆盖，重算与广播由命令层收口） ----------

  /** 保存失败要说清是"没写进去"还是"写进去了但共同时间没刷新"，否则用户不知道要不要重试。 */
  private failNote(res: ScheduleCommandResult): string {
    return res.errorCode === 'RECOMPUTE_FAILED'
      ? '已保存，但共同时间这轮没刷新，稍后会自动重算' : '保存失败，未做任何改动';
  }

  private write(shiftId: string): void {
    if (this.saving || (this.hasOv && this.ovId === shiftId)) {
      return;
    }
    this.saving = true;
    ScheduleCommandService.setDayShift(this.epochDay, shiftId === REST_ID ? null : shiftId,
      this.owner).then((res: ScheduleCommandResult) => {
      this.saving = false;
      if (!res.ok) {
        promptAction.showToast({ message: this.failNote(res) });
        return;
      }
      this.hasOv = true;
      this.ovId = shiftId;
      promptAction.showToast({ message: DateLabel.md(this.epochDay) + ' 已改为' + this.nameOf(shiftId) });
    });
  }

  private clearOverride(): void {
    if (this.saving || !this.hasOv) {
      return;
    }
    this.saving = true;
    ScheduleCommandService.clearDayShift(this.epochDay, this.owner)
      .then((res: ScheduleCommandResult) => {
        this.saving = false;
        if (!res.ok) {
          promptAction.showToast({ message: this.failNote(res) });
          return;
        }
        this.hasOv = false;
        this.ovId = REST_ID;
        promptAction.showToast({ message: '已恢复模板排班' });
      });
  }

  private chipBg(id: string): ResourceColor {
    if (!this.isSelected(id)) {
      return DesignTokens.fillWeakest;
    }
    // 休息没有自带色，用次级文本色即可与真班次区分
    return id === REST_ID ? DesignTokens.textTertiary : this.colorOf(id);
  }

  private chipFg(id: string): ResourceColor {
    return this.isSelected(id) ? DesignTokens.heroText : DesignTokens.textSecondary;
  }

  /**
   * 选中态不能只靠底色（docs/06 §3.10 B）：文字前加记号给眼睛，
   * 朗读文本再说明当前生效与点按后果，色觉与读屏用户拿到的是同一句事实。
   */
  private chipLabel(id: string): string {
    return (this.isSelected(id) ? '✓ ' : '') + this.nameOf(id);
  }

  private chipRead(id: string): string {
    if (this.isSelected(id)) {
      return this.nameOf(id) + '，当前生效';
    }
    return id === REST_ID ? '休息，点按把这天设为休息' : this.nameOf(id) + '，点按把这天改为该班次';
  }

  build() {
    Column({ space: DesignTokens.space4 }) {
      Column({ space: DesignTokens.space1 }) {
        Text(DateLabel.mdw(this.epochDay))
          .fontSize(DesignTokens.fontTitle)
          .fontFamily(DesignTokens.fontRound)
          .fontWeight(FontWeight.Bolder)
          .fontColor(DesignTokens.textPrimary)
        Text('当前：' + this.currentNote())
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textSecondary)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      // 日期和"当前是什么班"是一句话，分开念会听不出后半句在说哪天
      .accessibilityGroup(true)
      .accessibilityText(DateLabel.mdw(this.epochDay) + '，' + this.currentNote())

      if (this.loading) {
        Text('加载中…')
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textTertiary)
          .width('100%').textAlign(TextAlign.Center)
          .padding({ top: DesignTokens.space5, bottom: DesignTokens.space5 })
      } else {
        Column({ space: DesignTokens.space2 }) {
          Text('这天算什么')
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.textTertiary)
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.types, (st: ShiftType) => {
              Text(this.chipLabel(st.id))
                .fontSize(DesignTokens.fontBody)
                .fontColor(this.chipFg(st.id))
                .fontWeight(600)
                .textAlign(TextAlign.Center)
                .padding({ left: DesignTokens.space3, right: DesignTokens.space3 })
                .margin({ right: DesignTokens.space2, bottom: DesignTokens.space2 })
                .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
                .borderRadius(DesignTokens.radiusPill)
                .backgroundColor(this.chipBg(st.id))
                // 选中那颗才有下沿：没被选中的芯片是浅底，不该浮起来
                .shadow(this.isSelected(st.id)
                  ? DesignTokens.jelly(DesignTokens.primaryDeep, DesignTokens.jellyDepthChip)
                  : undefined)
                .focusable(true)
                .accessibilityText(this.chipRead(st.id))
                .onClick(() => this.write(st.id))
            }, (st: ShiftType) => st.id)
            Text(this.chipLabel(REST_ID))
              .fontSize(DesignTokens.fontBody)
              .fontColor(this.chipFg(REST_ID))
              .fontWeight(600)
              .textAlign(TextAlign.Center)
              .padding({ left: DesignTokens.space3, right: DesignTokens.space3 })
              .margin({ right: DesignTokens.space2, bottom: DesignTokens.space2 })
              .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
              .borderRadius(DesignTokens.radiusPill)
              .backgroundColor(this.chipBg(REST_ID))
              .shadow(this.isSelected(REST_ID)
                ? DesignTokens.jelly(DesignTokens.primaryDeep, DesignTokens.jellyDepthChip)
                : undefined)
              .focusable(true)
              .accessibilityText(this.chipRead(REST_ID))
              .onClick(() => this.write(REST_ID))
          }
          .width('100%')

          Text('单日覆盖优先于循环模板，且会立刻重算共同时间；长期规律请到「循环模板」里改序列。')
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.textHint)
            .margin({ top: DesignTokens.space2 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      Row({ space: DesignTokens.space3 }) {
        Button(this.hasOv ? '清除覆盖' : '无覆盖可清除')
          .layoutWeight(1)
          .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
          .backgroundColor(DesignTokens.fillWeak)
          .fontColor(this.hasOv ? DesignTokens.textSecondary : DesignTokens.textDisabled)
          .shadow(DesignTokens.jelly(DesignTokens.borderWeak, DesignTokens.jellyDepth))
          .enabled(this.hasOv && !this.saving)
          .onClick(() => this.clearOverride())
        Button('完成')
          .layoutWeight(1)
          .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
          .backgroundColor(DesignTokens.primary)
          .fontWeight(700)
          .shadow(DesignTokens.jelly(DesignTokens.primaryDeep, DesignTokens.jellyDepth))
          .enabled(!this.saving)
          .onClick(() => this.onClose())
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 20, right: 20, top: DesignTokens.space4, bottom: DesignTokens.space6 })
    .backgroundColor(DesignTokens.page)
  }
}
