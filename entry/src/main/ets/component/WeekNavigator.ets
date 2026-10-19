import { DateLabel } from 'commons';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';
import { DesignTokens } from '../theme/DesignTokens';

/** 两种周历与周班表使用同一套翻周控件；日期与动画仍由父组件管理。 */
@Component
export struct WeekNavigator {
  @Prop weekStart: number = 0;
  @Prop horizontalOffset: number = 0;
  @Prop alpha: number = 1;
  onPrevious: () => void = () => {};
  onNext: () => void = () => {};
  onCurrent: () => void = () => {};
  @StorageProp('crd_senior_mode') senior: boolean = false;

  build() {
    Row({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(18).fontColor([DesignTokens.textSecondary])
        .padding({ left: 6, right: 6 })
        .constraintSize({ minWidth: AccessibilityPolicy.minHit(this.senior), minHeight: AccessibilityPolicy.minHit(this.senior) })
        .focusable(true).accessibilityText('查看上一周')
        .onClick(() => this.onPrevious())
      Text(DateLabel.md(this.weekStart) + ' – ' + DateLabel.md(this.weekStart + 6))
        .fontSize(14).fontWeight(FontWeight.Medium).fontColor(DesignTokens.textPrimary)
        .layoutWeight(1).textAlign(TextAlign.Center)
        .translate({ x: this.horizontalOffset }).opacity(this.alpha)
        .accessibilityText('当前显示 ' + DateLabel.md(this.weekStart) + ' 至 ' + DateLabel.md(this.weekStart + 6))
        .onClick(() => this.onCurrent())
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18).fontColor([DesignTokens.textSecondary])
        .padding({ left: 6, right: 6 })
        .constraintSize({ minWidth: AccessibilityPolicy.minHit(this.senior), minHeight: AccessibilityPolicy.minHit(this.senior) })
        .focusable(true).accessibilityText('查看下一周')
        .onClick(() => this.onNext())
      Text('本周').fontSize(12).fontColor(DesignTokens.textAccent)
        .fontWeight(FontWeight.Bold)
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(DesignTokens.radiusPill).backgroundColor(DesignTokens.fillWeak)
        .constraintSize({ minWidth: AccessibilityPolicy.minHit(this.senior), minHeight: AccessibilityPolicy.minHit(this.senior) })
        .focusable(true).accessibilityText('回到本周')
        .clickEffect(DesignTokens.tapChip()).onClick(() => this.onCurrent())
    }.width('100%')
  }
}
