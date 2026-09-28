import { AnswerState } from 'feature';
import { DesignTokens } from '../theme/DesignTokens';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';

/**
 * 首页一条答案：问题小字 + 圆体粗字结论 + 依据摘要，行首一颗粉点表示整行可点。
 * 结论与依据文本全部来自 CommonTimeQueryService，页面只按 state 换色，不从中文文案反推业务状态。
 */
@Component
export struct QuickAnswerRow {
  /** 问题文案（页面按体验形态选口径，与服务里的名词保持一致）。 */
  @Prop question: string = '';
  /** 非首行画分隔线（对应原型 .arow+.arow）。 */
  showDivider: boolean = false;
  @Prop answerState: AnswerState = AnswerState.UNAVAILABLE;
  @Prop headline: string = '';
  @Prop supporting: string = '';
  onTap: () => void = () => {};
  @StorageProp('crd_reduce_motion') reduceMotion: boolean = false;
  // 装饰器实参必须是字面量，取值与 SENIOR_MODE_KEY 保持一致。
  @StorageProp('crd_senior_mode') senior: boolean = false;
  @State private isPressed: boolean = false;
  @State private hasFocus: boolean = false;

  /** 四种答案状态用不同字色：可用=主文本，暂无=次文本，缺对方数据=弱文本，过期=提示色。 */
  private headlineColor(): Resource {
    if (this.answerState === AnswerState.AVAILABLE) {
      return DesignTokens.textPrimary;
    }
    if (this.answerState === AnswerState.STALE) {
      return DesignTokens.warn;
    }
    if (this.answerState === AnswerState.UNKNOWN) {
      return DesignTokens.textTertiary;
    }
    return DesignTokens.textSecondary;
  }

  /**
   * 状态用字色区分，读屏里颜色不存在，所以非"可用"三态各补一句可朗读的话。
   * AVAILABLE 不补：结论本身已经是答案，再念一遍是噪音。
   */
  private stateWord(): string {
    if (this.answerState === AnswerState.STALE) {
      return '数据可能过期';
    }
    if (this.answerState === AnswerState.UNKNOWN) {
      return '缺少 TA 的数据';
    }
    if (this.answerState === AnswerState.UNAVAILABLE) {
      return '暂时算不出结果';
    }
    return '';
  }

  private press(down: boolean): void {
    this.getUIContext().animateTo({
      duration: DesignTokens.motion(this.reduceMotion, DesignTokens.motionPress),
      curve: DesignTokens.curve
    }, () => {
      this.isPressed = down;
    });
  }

  build() {
    Column() {
      if (this.showDivider) {
        // 原型 .arow+.arow：1.5vp 虚线，比实线更轻，行与行之间只留一道糖纸似的痕迹
        Row()
          .width('100%')
          .height(2)
          .border({
            width: { top: 1.5 },
            color: { top: DesignTokens.borderWeak },
            style: { top: BorderStyle.Dashed }
          })
      }
      Row({ space: DesignTokens.space2 }) {
        // 原型 .arow::before：行首一颗 6vp 粉点，贴在问题那一行的高度上
        Column()
          .width(6)
          .height(6)
          .borderRadius(DesignTokens.radiusPill)
          .backgroundColor(DesignTokens.primaryBorder)
          .alignSelf(ItemAlign.Start)
          .margin({ top: DesignTokens.space3 })
          .accessibilityLevel('no')
        Column({ space: 2 }) {
          Text(this.question)
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.textTertiary)
          Text(this.headline)
            .fontSize(DesignTokens.fontBody)
            .fontFamily(DesignTokens.fontRound)
            .fontWeight(FontWeight.Bolder)
            .fontColor(this.headlineColor())
          if (this.supporting !== '') {
            Text(this.supporting)
              .fontSize(DesignTokens.fontCaption)
              .fontColor(DesignTokens.textTertiary)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('›')
          .fontSize(DesignTokens.fontBody)
          .fontColor(DesignTokens.textDisabled)
          .accessibilityLevel('no')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      // 问题 + 结论 + 依据合成一个朗读单元；箭头是装饰，改成一句可朗读的操作说明。
      .accessibilityGroup(true)
      .accessibilityDescription('整行可点，展开这条答案的详情')
      .padding({
        top: DesignTokens.space3,
        bottom: DesignTokens.space3,
        left: DesignTokens.space2,
        right: DesignTokens.space1
      })
      .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
      // 按压底色按原型的行卡（.li）收 18vp，比正文卡小一档。
      .borderRadius(18)
      .backgroundColor(this.isPressed ? DesignTokens.fillWeakest : Color.Transparent)
      // 焦点环常驻 2vp 透明边，聚焦时不跳动。
      .border({
        width: 2,
        color: this.hasFocus ? DesignTokens.focusRing : Color.Transparent,
        radius: 18
      })
      .focusable(true)
      .onFocus(() => {
        this.hasFocus = true;
      })
      .onBlur(() => {
        this.hasFocus = false;
      })
      .onTouch((e: TouchEvent) => {
        if (e.type === TouchType.Down) {
          this.press(true);
        } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
          this.press(false);
        }
      })
      .onClick(() => {
        this.onTap();
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
