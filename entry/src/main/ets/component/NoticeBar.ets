import { DesignTokens } from '../theme/DesignTokens';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';

/** 提示条语气：过期/降级用警示色，读取失败用错误色。 */
export enum NoticeTone {
  WARN = 'WARN',
  ERROR = 'ERROR'
}

/**
 * 页内提示条：旧结果还在时不清空内容，只在内容上方说明结论的时效或降级原因。
 * 语气不只靠颜色区分——每种语气有独立符号，标题与说明始终是文字；
 * 动作可省略（只报事实的场景不给按钮），有动作时热区不小于 44vp 并带焦点环。
 */
@Component
export struct NoticeBar {
  // 这几格必须是 @Prop：提示条的说法由父页的状态算出来（`syncStateNoteOf(s)` 一类），
  // 而父页重渲染时门槛常常没变（同一格 WARN 里换了个 code），普通成员只在构造时赋值一次，
  // 于是节点留着、句子冻在上一份真相上（D-46）。
  @Prop tone: NoticeTone = NoticeTone.WARN;
  @Prop title: string = '';
  @Prop body: string = '';
  /** 覆盖语气默认符号（如"缺对方数据"用 ?），空串走默认。 */
  @Prop glyph: string = '';
  @Prop actionLabel: string = '';
  /** 函数不能做 @Prop，留普通成员：闭包读的是父组件的当前状态，节点不拆也点得对。 */
  onAction: () => void = () => {};
  @StorageProp('crd_reduce_motion') reduceMotion: boolean = false;
  // 装饰器实参必须是字面量，取值与 SENIOR_MODE_KEY 保持一致。
  @StorageProp('crd_senior_mode') senior: boolean = false;
  @State private hasActionFocus: boolean = false;

  private isError(): boolean {
    return this.tone === NoticeTone.ERROR;
  }

  private mark(): string {
    if (this.glyph !== '') {
      return this.glyph;
    }
    return this.isError() ? '!' : '↻';
  }

  private accent(): Resource {
    return this.isError() ? DesignTokens.danger : DesignTokens.warn;
  }

  build() {
    Row({ space: DesignTokens.space2 }) {
      Text(this.mark())
        .fontSize(DesignTokens.fontCaption)
        .fontFamily(DesignTokens.fontRound)
        .fontWeight(800)
        .fontColor(this.accent())
        .textAlign(TextAlign.Center)
        .width(DesignTokens.space5)
        .height(DesignTokens.space5)
        .borderRadius(DesignTokens.markRadius)
        .backgroundColor(DesignTokens.card)
        // 语气符号只作视觉分区，标题文字才是朗读内容
        .accessibilityLevel('no')
      Column({ space: 2 }) {
        Text(this.title)
          .fontSize(DesignTokens.fontCaption)
          .fontWeight(600)
          .fontColor(this.accent())
        if (this.body !== '') {
          Text(this.body)
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.textTertiary)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.actionLabel !== '') {
        Text(this.actionLabel)
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textAccent)
          .fontWeight(600)
          .textAlign(TextAlign.Center)
          .constraintSize({
            minWidth: AccessibilityPolicy.minHit(this.senior),
            minHeight: AccessibilityPolicy.minHit(this.senior)
          })
          .border({
            width: 2,
            color: this.hasActionFocus ? DesignTokens.focusRing : Color.Transparent,
            radius: DesignTokens.radiusCardCut
          })
          .focusable(true)
          .onFocus(() => {
            this.hasActionFocus = true;
          })
          .onBlur(() => {
            this.hasActionFocus = false;
          })
          .onClick(() => {
            this.onAction();
          })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      left: DesignTokens.space3,
      right: DesignTokens.space1,
      top: DesignTokens.space2,
      bottom: DesignTokens.space2
    })
    .borderRadius(DesignTokens.cardRadius(false))
    .backgroundColor(this.isError() ? DesignTokens.dangerBg : DesignTokens.fillWeak)
    .transition(this.reduceMotion
      ? TransitionEffect.IDENTITY
      : TransitionEffect.OPACITY.animation({ duration: DesignTokens.motionFade, curve: DesignTokens.curve }))
  }
}
