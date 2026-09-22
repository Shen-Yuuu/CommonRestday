import { DesignTokens } from '../theme/DesignTokens';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';

/** ResourceStr 既可能是字符串也可能是资源引用，只有空字符串算“没有文案”。 */
function hasLabel(v: ResourceStr): boolean {
  return typeof v === 'string' ? v.length > 0 : true;
}

/**
 * 页面级小节：眉标 + 衬线小标题 + 右侧补充说明，下面挂内容。
 * 小节本身不带底色，可直接放在纸面背景上，也可放进 EditorialCard。
 */
@Component
export struct EditorialSection {
  /** 眉标：分类小字，可空。 */
  eyebrow: ResourceStr = '';
  title: ResourceStr = '';
  /** 右侧补充说明或操作文字，可空。 */
  trailing: ResourceStr = '';
  /** trailing 是操作时置 true：补足 44vp 热区、焦点环与点击。 */
  trailingAction: boolean = false;
  onTrailingTap: () => void = () => {};
  @StorageProp('crd_reduce_motion') reduceMotion: boolean = false;
  // 装饰器实参必须是字面量，取值与 SENIOR_MODE_KEY 保持一致。
  @StorageProp('crd_senior_mode') senior: boolean = false;
  @BuilderParam content: () => void = this.placeholder;
  @State private hasTrailingFocus: boolean = false;

  @Builder
  placeholder(): void {
  }

  build() {
    Column() {
      // 眉标（MAIN / EXTRA / 三个问题）是版式装饰，长辈模式下按 docs/06 §3.10 C 收起，
      // 小标题本身已经把这一节是什么说清楚了
      if (hasLabel(this.eyebrow) && !this.senior) {
        Text(this.eyebrow)
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.primary)
          .fontFamily(DesignTokens.fontSans)
          .letterSpacing(1)
          .margin({ bottom: DesignTokens.space1 })
      }
      Row() {
        Text(this.title)
          .fontSize(DesignTokens.fontTitle)
          .fontColor(DesignTokens.textPrimary)
          .fontFamily(DesignTokens.fontSerif)
          .fontWeight(FontWeight.Medium)
          .letterSpacing(-0.7)
          .layoutWeight(1)
        if (hasLabel(this.trailing)) {
          Text(this.trailing)
            .fontSize(DesignTokens.fontCaption)
            .fontColor(this.trailingAction ? DesignTokens.primary : DesignTokens.textTertiary)
            .textAlign(TextAlign.End)
            .constraintSize({
              minWidth: this.trailingAction ? AccessibilityPolicy.minHit(this.senior) : 0,
              minHeight: this.trailingAction ? AccessibilityPolicy.minHit(this.senior) : 0
            })
            .padding({ left: this.trailingAction ? DesignTokens.space2 : 0 })
            .border({
              width: 2,
              color: this.hasTrailingFocus ? DesignTokens.focusRing : Color.Transparent,
              radius: DesignTokens.radiusCardCut
            })
            .focusable(this.trailingAction)
            .onFocus(() => {
              this.hasTrailingFocus = true;
            })
            .onBlur(() => {
              this.hasTrailingFocus = false;
            })
            .onClick(() => {
              if (this.trailingAction) {
                this.onTrailingTap();
              }
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Column() {
        this.content()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: DesignTokens.space3 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .transition(this.reduceMotion
      ? TransitionEffect.IDENTITY
      : TransitionEffect.OPACITY
        .animation({ duration: DesignTokens.motionFade, curve: DesignTokens.curve }))
  }
}
