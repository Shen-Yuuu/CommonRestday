import { DesignTokens } from '../theme/DesignTokens';

/**
 * 首页气氛背景层：暖象牙底之上叠一条低饱和、低对比的抽象色带（日光→莓粉→冷蓝），
 * 向下自然淡出，并在它和正文之间压一层暖白雾，保证文字底下的合成底色可预测。
 *
 * 只有静态渐变与遮罩：不下载网络壁纸，也不在滚动容器里做实时模糊。
 * 规范允许的 8–16 秒极轻背景漂移暂不启用——没有设备性能证据前不常驻重绘。
 */
@Component
export struct AmbientScene {
  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column()
        .width('100%')
        .height('62%')
        .linearGradient({
          angle: 168,
          colors: [[DesignTokens.sceneWarm, 0], [DesignTokens.sceneRose, 0.42],
            [DesignTokens.sceneBlue, 0.72], [Color.Transparent, 1]]
        })
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [[DesignTokens.sceneVeilSoft, 0], [DesignTokens.sceneVeilStrong, 0.34],
            [Color.Transparent, 0.66]]
        })
    }
    .width('100%')
    .height('100%')
    // 背景层不参与命中：滚动与点击全部交给它上面的内容
    .hitTestBehavior(HitTestMode.None)
    // 读屏同样跳过整层：色带没有信息量，念出来只会把正文挤后
    .accessibilityLevel('no-hide-descendants')
  }
}
