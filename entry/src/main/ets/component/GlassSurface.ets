import { uiMaterial } from '@kit.ArkUI';
import { DesignTokens } from '../theme/DesignTokens';
import { GlassMode, GlassStrength, MaterialPolicy } from '../theme/MaterialPolicy';

/**
 * 玻璃表面的取值口径。材质路径把自绘底色、描边、阴影全部让给系统材质
 * （规范 §5.5：非透明背景色与背景模糊不得无条件叠加），实色路径自己画。
 * 页面只报「强度 + 实色回退底」，不判断能力，也不在两条路径之间自己分支。
 */
export class GlassStyle {
  static material(strength: GlassStrength, reduceTransparency: boolean): uiMaterial.ImmersiveMaterial | undefined {
    return MaterialPolicy.material(strength, reduceTransparency);
  }

  static isSolid(reduceTransparency: boolean): boolean {
    return MaterialPolicy.mode(reduceTransparency) === GlassMode.SOLID;
  }

  /** 实色回退底由调用方给（底栏给暖白，Hero 给深莓），材质路径留透明。 */
  static fill(fallback: ResourceColor, reduceTransparency: boolean): ResourceColor {
    return GlassStyle.isSolid(reduceTransparency) ? fallback : Color.Transparent;
  }

  static borderWidth(reduceTransparency: boolean): number {
    return GlassStyle.isSolid(reduceTransparency) ? DesignTokens.glassBorderWidth : 0;
  }

  /** 阴影半径归 0 就等于关掉自绘阴影，避免与材质的 applyShadow 叠成两层。 */
  static shadow(reduceTransparency: boolean): ShadowOptions {
    const solid = GlassStyle.isSolid(reduceTransparency);
    return {
      radius: solid ? DesignTokens.glassShadowRadius : 0,
      color: solid ? DesignTokens.glassShadow : Color.Transparent,
      offsetX: 0,
      offsetY: solid ? DesignTokens.glassShadowOffsetY : 0
    };
  }
}

/**
 * 双路径玻璃容器：悬浮底栏、Sheet 与需要「浮在内容之上」的前景层共用。
 * 材质不可用、低算力档或降低透明度时得到近实色，而不是去掉模糊后剩下的透明底。
 */
@Component
export struct GlassSurface {
  /** STRONG＝悬浮底栏/Sheet，SOFT＝首页唯一主结果。 */
  strength: GlassStrength = GlassStrength.STRONG;
  /** 圆角沿用 radiusCard/radiusSheet/radiusPill，不另建一套形状语言。 */
  radius: Resource = DesignTokens.radiusCard;
  /** 实色回退底色。 */
  fallback: ResourceColor = DesignTokens.glassFallback;
  /** 半模态贴底时只圆顶部两角：底部留圆角会在 sheet 与屏幕下沿之间露出一条缝。 */
  topCornersOnly: boolean = false;
  // 装饰器实参必须是字面量，取值与 TRANSPARENCY_REDUCE_KEY 保持一致。
  @StorageProp('crd_reduce_transparency') reduceTransparency: boolean = false;
  @BuilderParam content: () => void = this.placeholder;

  @Builder
  placeholder(): void {
  }

  private corners(): Resource | BorderRadiuses {
    if (!this.topCornersOnly) {
      return this.radius;
    }
    return { topLeft: this.radius, topRight: this.radius, bottomLeft: 0, bottomRight: 0 };
  }

  build() {
    if (GlassStyle.isSolid(this.reduceTransparency)) {
      Stack({ alignContent: Alignment.Top }) {
        // 顶部 1vp 弱高光：材质路径由系统给边缘，实色路径自己补一条
        Row()
          .width('76%')
          .height(DesignTokens.glassBorderWidth)
          .backgroundColor(DesignTokens.glassHighlight)
          .accessibilityLevel('no')
        this.content()
      }
      .borderRadius(this.corners())
      .clip(true)
      .backgroundColor(GlassStyle.fill(this.fallback, this.reduceTransparency))
      .border({
        width: GlassStyle.borderWidth(this.reduceTransparency),
        color: DesignTokens.glassBorder,
        radius: this.corners()
      })
      .shadow(GlassStyle.shadow(this.reduceTransparency))
    } else {
      Stack() {
        this.content()
      }
      .borderRadius(this.corners())
      .clip(true)
      .systemMaterial(GlassStyle.material(this.strength, this.reduceTransparency))
    }
  }
}
