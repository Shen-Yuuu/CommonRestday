import { DesignTokens } from '../theme/DesignTokens';

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
  tone: NoticeTone = NoticeTone.WARN;
  title: string = '';
  body: string = '';
  /** 覆盖语气默认符号（如"缺对方数据"用 ?），空串走默认。 */
  glyph: string = '';
  actionLabel: string = '';
  onAction: () => void = () => {};
  @StorageProp('crd_reduce_motion') reduceMotion: boolean = false;
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
        .fontFamily(DesignTokens.fontSerif)
        .fontWeight(600)
        .fontColor(this.accent())
        .textAlign(TextAlign.Center)
        .width(DesignTokens.space5)
        .height(DesignTokens.space5)
        .borderRadius(DesignTokens.radiusCardCut)
        .backgroundColor(DesignTokens.card)
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
          .fontColor(DesignTokens.primary)
          .fontWeight(600)
          .textAlign(TextAlign.Center)
          .constraintSize({
            minWidth: DesignTokens.hitMin,
            minHeight: DesignTokens.hitMin
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
