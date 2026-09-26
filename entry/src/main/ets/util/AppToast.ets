import { ComponentContent, OverlayManager, promptAction, UIContext } from '@kit.ArkUI';
import { DesignTokens, MOTION_REDUCE_KEY } from '../theme/DesignTokens';
import { SCREEN_READER_KEY } from '../accessibility/AccessibilityPolicy';

/**
 * 自绘提示条（原型 02 的 `.toast`：radius 999 / card_bg / 2px brand_pink_border / 0 14px 30px 影）。
 *
 * 系统 `promptAction.showToast` 的面由系统画，应用侧改不了描边与底色，所以换成 OverlayManager
 * 上的一层浮层：它的节点在页面层级之上，router 页与 NavDestination 都盖得住，绑定一次全站可用。
 *
 * 两处刻意的让路：
 * - 读屏模式下降回系统 toast。OverlayManager 的节点不会自动播报，换成自绘等于把"保存成功"
 *   这句话从听觉通道里删掉——提示是结果反馈，不是装饰。
 * - 只做入场动效。原型那条 `opacity .3s` 的退场要跑在节点移除之前，而
 *   `removeComponentContent` 之后节点直接脱离组件树，退场 transition 不保证播；
 *   为它引入 animateTo + update 的二次计时，收益只是收起时那 300ms。
 */

/** 内边距与描边：CSS `padding:9px 20px` + `border:2px solid`。 */
const PAD_Y = 9;
const PAD_X = 20;
const BORDER_WIDTH = 2;
/** 距窗口底：CSS `bottom:96px`。底栏浮岛占掉 52+10，这条落在岛上方一点的留白里。 */
const BOTTOM_VP = 96;
/** 入场位移：CSS `translateY(8px)` → `.on{translateY(0)}`。 */
const RISE_VP = 8;
/** 投影：CSS `0 14px 30px var(--shadow_card)`，radius/offsetY 与 cardShadow() 同一口径。 */
const SHADOW_RADIUS = 30;
const SHADOW_Y = 14;
/** 停留时长：对齐系统 toast 的 SHORT，入场 400ms 不计入。 */
const HOLD_MS = 1700;
const ENTER_MS = 400;

@Builder
function toastFace(message: ResourceStr) {
  // 根节点铺满窗口只为把药丸推到底部：整层命中测试关掉，提示条不拦任何点击
  Column() {
    Text(message)
      .fontSize(DesignTokens.fontCaption)
      .fontWeight(FontWeight.Bold)
      .fontColor(DesignTokens.textPrimary)
      .textAlign(TextAlign.Center)
      .maxLines(3)
      .padding({ top: PAD_Y, bottom: PAD_Y, left: PAD_X, right: PAD_X })
      .borderRadius(DesignTokens.radiusPill)
      .backgroundColor(DesignTokens.card)
      .borderWidth(BORDER_WIDTH)
      .borderColor(DesignTokens.primaryBorder)
      .shadow({ radius: SHADOW_RADIUS, color: DesignTokens.shadowSoft, offsetX: 0, offsetY: SHADOW_Y })
      .transition(TransitionEffect.OPACITY
        .combine(TransitionEffect.translate({ y: RISE_VP }))
        .animation({
          duration: DesignTokens.motion(AppStorage.get<boolean>(MOTION_REDUCE_KEY) === true, ENTER_MS),
          curve: DesignTokens.curve
        }))
  }
  .width('100%')
  .height('100%')
  .justifyContent(FlexAlign.End)
  .padding({ bottom: BOTTOM_VP })
  .hitTestBehavior(HitTestMode.None)
}

const WRAPPED_TOAST: WrappedBuilder<[ResourceStr]> = wrapBuilder(toastFace);

/** 壳层挂载时绑定一次：UIContext 是窗口级的，Tab 页、栈目的地与 router 页共用同一个。 */
let hostContext: UIContext | null = null;
let current: ComponentContent<ResourceStr> | null = null;
let dismissTimer: number = -1;

/** 由入口页在 aboutToAppear 绑定；没绑上时 appToast 退到系统 toast，不会静默丢提示。 */
export function bindToastHost(ctx: UIContext): void {
  hostContext = ctx;
}

function dismissNow(): void {
  if (dismissTimer >= 0) {
    clearTimeout(dismissTimer);
    dismissTimer = -1;
  }
  const stale: ComponentContent<ResourceStr> | null = current;
  current = null;
  if (stale !== null && hostContext !== null) {
    hostContext.getOverlayManager().removeComponentContent(stale);
    stale.dispose();
  }
}

/**
 * 弹一条提示。文案可以是字面量也可以是资源引用（隐私弹窗那条用 $r）。
 * 连着触发时旧的立刻撤下、新的顶上——原型也只有一个 .toast 节点在换文案。
 */
export function appToast(message: ResourceStr): void {
  const ctx: UIContext | null = hostContext;
  const screenReader: boolean = AppStorage.get<boolean>(SCREEN_READER_KEY) === true;
  if (ctx === null || screenReader) {
    promptAction.showToast({ message: message });
    return;
  }
  dismissNow();
  const content: ComponentContent<ResourceStr> =
    new ComponentContent<ResourceStr>(ctx, WRAPPED_TOAST, message);
  current = content;
  const overlay: OverlayManager = ctx.getOverlayManager();
  overlay.addComponentContent(content);
  dismissTimer = setTimeout(() => {
    dismissTimer = -1;
    dismissNow();
  }, HOLD_MS);
}
