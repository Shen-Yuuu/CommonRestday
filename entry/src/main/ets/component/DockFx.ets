import { DesignTokens } from '../theme/DesignTokens';

/**
 * Dock 光感粒子层（原型 `.dock-fx`）：悬浮岛之上的两层装饰——贴底的品牌粉光池、12 颗上升的糖粒（含两颗心）。
 * 这层是纯装饰：整层 `HitTestMode.Transparent`，命中测试放行给底下的悬浮岛（见 build 里的说明），
 * 底栏三项照常落点；挂在 Navigation 内容里，所以 push 班表页时它跟着页签栏一起被盖掉。
 * 开「减少动态效果」时只留光池：糖粒只剩动效，静帧会是一排钉在岛上的亮带。
 */

/** 单颗糖粒的规格，字段一一对应原型 CSS 的 --s/--c/--d/--dl/--dx/--o。 */
interface SparkSpec {
  /** 距岛左沿的百分比（原型 left）。 */
  left: string;
  /** 直径 vp；心形固定 10（原型 --s，is-heart 走 10px）。 */
  size: number;
  color: Resource;
  /** 一个周期的秒数（原型 --d）。 */
  period: number;
  /** 起跑延迟秒数（原型 --dl），用它把 12 颗错开。 */
  delay: number;
  /** 周期末的横向漂移 vp（原型 --dx，可为负）。 */
  drift: number;
  /** 峰值不透明度（原型 --o）。 */
  peak: number;
  /** 原型 `.b`：柔焦大颗，丢辉光换 blur。 */
  soft: boolean;
  /** 原型 `.is-heart`：画心形而不是圆点。 */
  heart: boolean;
}

/** 糖粒出生点：岛底再往下 10vp（原型 dockRise 的 0%）。 */
const RISE_FROM: number = 10;
/** 终点：向上 44vp（原型 dockRise 的 100%，正是一个周期的上升距离）。 */
const RISE_TO: number = -44;
/** 14% 前淡入、14%–60% 保持峰值、60%–100% 淡出。 */
const RISE_IN: number = 0.14;
const RISE_HOLD: number = 0.6;
/** 原型 bottom:4px。 */
const SPARK_BOTTOM: number = 4;
const GLOW_RADIUS: number = 120;
const HEART_SIZE: number = 10;

/** 原型一行一颗：这里同样一行一颗，soft=`.b` 柔焦大颗，heart=`.is-heart`。 */
function grain(left: string, size: number, color: Resource, period: number, delay: number,
  drift: number, peak: number, soft: boolean = false, heart: boolean = false): SparkSpec {
  return {
    left: left, size: size, color: color, period: period, delay: delay,
    drift: drift, peak: peak, soft: soft, heart: heart
  };
}

const SPARKS: SparkSpec[] = [
  grain('6%', 3, DesignTokens.sparkPink, 6.2, 0.2, 8, 0.8),
  grain('13%', 2, DesignTokens.sparkWhite, 7.4, 1.6, -6, 0.7),
  grain('21%', 4, DesignTokens.sparkAmber, 5.4, 2.8, 10, 0.85),
  grain('29%', 7, DesignTokens.sparkBlush, 8.2, 0.9, 6, 0.4, true),
  grain('38%', 2.5, DesignTokens.sparkWhite, 6.8, 3.4, -8, 0.75),
  grain('46%', HEART_SIZE, DesignTokens.sparkHeart, 7.8, 1.1, 9, 0.85, false, true),
  grain('54%', 3, DesignTokens.sparkLilac, 5.9, 4.2, -7, 0.8),
  grain('63%', 2.5, DesignTokens.sparkAmber, 7.1, 0.5, 8, 0.7),
  grain('71%', 6, DesignTokens.sparkWhite, 8.6, 2.2, -9, 0.35, true),
  grain('79%', HEART_SIZE, DesignTokens.sparkAmber, 6.5, 3.8, -8, 0.8, false, true),
  grain('87%', 3, DesignTokens.sparkPink, 5.6, 1.9, 7, 0.8),
  grain('94%', 2, DesignTokens.sparkWhite, 7.6, 4.6, -6, 0.65)
];

/**
 * 一颗糖粒：自己的 @State 只装「当前位移 + 当前透明度」，
 * 关键帧动画按原型 dockRise 的三段（淡入 / 保持 / 淡出）无限循环。
 */
@Component
struct SparkGrain {
  spec: SparkSpec = SPARKS[0];
  bandHeight: number = 52;
  @State private moveX: number = 0;
  @State private moveY: number = RISE_FROM;
  @State private alpha: number = 0;

  /** 时间进度 → 纵向位置（原型是整段线性上移，不随透明度分段）。 */
  private riseAt(t: number): number {
    return RISE_FROM + (RISE_TO - RISE_FROM) * t;
  }

  private start(): void {
    const total: number = this.spec.period * 1000;
    const mid: number = total * RISE_IN;
    const hold: number = total * (RISE_HOLD - RISE_IN);
    const tail: number = total * (1 - RISE_HOLD);
    this.getUIContext().keyframeAnimateTo({ iterations: -1, delay: this.spec.delay * 1000 }, [
      {
        duration: Math.round(mid),
        curve: Curve.Linear,
        event: () => {
          this.moveX = this.spec.drift * RISE_IN;
          this.moveY = this.riseAt(RISE_IN);
          this.alpha = this.spec.peak;
        }
      },
      {
        duration: Math.round(hold),
        curve: Curve.Linear,
        event: () => {
          this.moveX = this.spec.drift * RISE_HOLD;
          this.moveY = this.riseAt(RISE_HOLD);
          this.alpha = this.spec.peak;
        }
      },
      {
        duration: Math.round(tail),
        curve: Curve.Linear,
        event: () => {
          this.moveX = this.spec.drift;
          this.moveY = this.riseAt(1);
          this.alpha = 0;
        }
      }
    ]);
  }

  build() {
    Stack() {
      if (this.spec.heart) {
        SymbolGlyph($r('sys.symbol.heart_fill'))
          .fontSize(this.spec.size)
          .fontColor([this.spec.color])
      } else {
        Column()
          .width('100%')
          .height('100%')
          .borderRadius(this.spec.size / 2)
          .backgroundColor(this.spec.color)
      }
    }
    .width(this.spec.size)
    .height(this.spec.size)
    .position({ x: this.spec.left, y: this.bandHeight - SPARK_BOTTOM - this.spec.size })
    .translate({ x: this.moveX, y: this.moveY })
    .opacity(this.alpha)
    // 原型 filter：普通颗是自身色的 drop-shadow，`.b` 大颗换成 blur(2px) 的柔焦。
    .shadow(this.spec.soft || this.spec.heart
      ? undefined
      : { radius: 5, color: this.spec.color, offsetX: 0, offsetY: 0 })
    .blur(this.spec.soft ? 2 : 0)
    .onAppear(() => {
      this.start();
    })
  }
}

@Component
export struct DockFx {
  /**
   * 带宽（vp）：由壳层量出来的岛宽传进来，两层同宽才对得齐。
   * 必须是 @Prop：壳层的 bandVp 是 onAreaChange 之后才从兜底值改成真宽的，
   * 普通成员只在子组件创建时初始化一次，实测粒子层会一直停在兜底宽上。
   */
  @Prop bandWidth: number = 236;
  bottom: number = 10;
  bandHeight: number = 52;
  radius: number = 22;
  // 装饰器实参必须是字面量，取值与 MOTION_REDUCE_KEY 保持一致。
  @StorageProp('crd_reduce_motion') reduceMotion: boolean = false;

  /** 原型 `.dock-glow`：55% 62% 的椭圆粉池，圆心在 50% 62%——ArkUI 只有正圆，取等价的横向半径。 */
  private glowOf(): RadialGradientOptions {
    return {
      center: ['50%', '78%'],
      radius: GLOW_RADIUS,
      colors: [[DesignTokens.dockGlowPool, 0], [Color.Transparent, 0.7], [Color.Transparent, 1]]
    };
  }

  build() {
    Row() {
      Stack({ alignContent: Alignment.BottomStart }) {
        // 光池：浅色档的 dock_glow_pool 是全透明，所以这一层只在深色主题露面（原型浅色直接 display:none）。
        Column()
          .width('100%')
          .height('100%')
          .radialGradient(this.glowOf())

        if (!this.reduceMotion) {
          ForEach(SPARKS, (spec: SparkSpec, index: number) => {
            SparkGrain({ spec: spec, bandHeight: this.bandHeight })
          }, (spec: SparkSpec, index: number) => 'dock-spark-' + index)
        }
      }
      .width(this.bandWidth)
      .height(this.bandHeight)
      .borderRadius(this.radius)
      .clip(true)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ bottom: this.bottom })
    // 装饰层不吞点击：Stack 里两节点重叠时，顶层节点的子节点被命中就只测顶层（枚举说明·HitTestMode）。
    // None 只关掉自身的响应，改变不了这条限制——实测三项落点全部 Touch test result is empty。
    // 只有 Transparent 会放行兄弟节点，底下的悬浮岛才重新收得到点击。
    .hitTestBehavior(HitTestMode.Transparent)
    .accessibilityLevel('no')
  }
}
