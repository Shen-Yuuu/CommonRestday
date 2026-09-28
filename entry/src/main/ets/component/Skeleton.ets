import { DesignTokens } from '../theme/DesignTokens';

/**
 * 骨架屏的灰条：首页、共同时间页、计划页共用同一条占位语言。
 *
 * 抽出来的理由：前两页原先各写了一份逐字相同的 `skeletonBar`，第三页（计划）当时没接，
 * 加载时只吐一行裸文字——同一个 App 里"正在读"有三种长相。条形本身统一在这里，
 * **哪几条、多高、什么底色留给各页**：那是各页真实版面决定的，不是占位符的风格。
 *
 * 灰条没有可朗读内容，所以使用它的那一列必须自己挂 `accessibilityGroup(true)`
 * 并给一句"正在读取××"，否则读屏用户面对的是一片静默。
 */
@Component
export struct SkeletonBar {
  /** 百分比宽度字符串：占位条要跟着真实内容的长短排，不给固定 vp。 */
  barWidth: string = '100%';
  /** 高度取间距令牌，与真实文字的行高一档一档对得上。 */
  barHeight: Resource = DesignTokens.space3;
  /** hero 卡上的条用光晕色（粉底上的暖白），正文卡用 fillWeak。 */
  tint: Resource = DesignTokens.fillWeak;

  build() {
    Row()
      .width(this.barWidth)
      .height(this.barHeight)
      .borderRadius(DesignTokens.radiusPill)
      .backgroundColor(this.tint)
  }
}
