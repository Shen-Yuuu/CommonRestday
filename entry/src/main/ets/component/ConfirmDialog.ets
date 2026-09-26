import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';
import { DesignTokens } from '../theme/DesignTokens';

/**
 * 确认框的面（原型 02 的 `.dlgwrap` + `.dlg` + `.dlg-peek`）。
 *
 * 为什么自绘：`showAlertDialog` 的面、按钮、遮罩色都不交给应用——`AlertDialogParamWithButtons`
 * 只有 maskRect（遮罩范围）没有 maskColor（遮罩颜色），原型的 `.dlgwrap{rgba(74,36,54,.48)}`
 * 与果冻双按钮在它里面没有落点。换成 `PromptAction.openCustomDialog(ComponentContent)` 后
 * 走的是 `BaseDialogOptions`，遮罩色/居中/遮罩与返回键的回调全都给（见 util/AppConfirm.ets）。
 *
 * 这里只画面，不掌管生命周期：节点由 ComponentContent 托管，所以不是 @CustomDialog，
 * 也不自带 controller——开合、dispose、读屏回退全在 askConfirm 那一侧。
 * 开合走的是 `ctx.getPromptAction()` 拿到的 `PromptAction#openCustomDialog`，不在 UIContext 上。
 */

/** 卡片内边距：CSS `.dlg{padding:24px 20px}`。 */
const PAD_X: number = 20;
const PAD_Y: number = 24;
/**
 * 探头布布：CSS `.dlg-peek{width:86px}` 配 viewBox 0 0 120 78 算出 86×56，
 * `position:absolute;top:-50px` 是相对**卡面上沿**外溢 50vp，所以只有下沿 6vp（两只前爪）压在卡面上。
 * ArkUI 没有 absolute，负 margin 从 padding 内沿（PAD_Y）起算，外溢量要再加一档 PAD_Y；
 * 图占的排版高度因此变成 6−24=−18vp，首行文字的顶距要补回 PAD_Y−6=18vp 才落回 CSS 的 24vp。
 */
const PEEK_W: number = 86;
const PEEK_H: number = 56;
/** 露在卡面上沿之外的量：CSS `top:-50px`。 */
const PEEK_OUT: number = 50;
const PEEK_MARGIN: number = -(PEEK_OUT + PAD_Y);
/** 布布下沿压进卡面的那 6vp 要从首行顶距里扣掉。 */
const FIRST_TEXT_TOP: number = PAD_Y - (PEEK_H - PEEK_OUT);
/** 按钮行间距与上边距：CSS `.row.gap10.mt16`。 */
const BTN_GAP: number = 10;
/** 消息行距：CSS `line-height:1.7` 落在最小档 13fp 上。 */
const MESSAGE_LINE: number = 22;
/** 投影：CSS `0 26px 55px var(--shadow_card)`，与 cardShadow() 同一口径（CSS 的 blur 直接当 radius）。 */
const SHADOW_RADIUS: number = 55;
const SHADOW_Y: number = 26;
/** 卡片宽：CSS 是 `.dlgwrap{padding:26px}` + `.dlg{width:100%}`，在这块 373.7vp 宽的屏上等于 86%。 */
const CARD_WIDTH: string = '86%';
/** 宽窗收口：手机上是死代码（321vp < 360），只挡平板/折叠展开把确认框拉成一条横幅。 */
const CARD_MAX_WIDTH: number = 360;
/** 描边档：CSS `.btn.ghost{border:1.5px solid var(--brand_pink_border)}`。 */
const GHOST_BORDER: number = 1.5;
/** 入场：原型 `.dlg` 没写动效，给一档轻缩放，跟全 App 的果冻手感对齐。 */
const ENTER_SCALE: number = 0.94;
const ENTER_MS: number = 260;

/** askConfirm 传进面的参数：文案 + 确认侧语气 + 落点回调。 */
export interface ConfirmDialogParams {
  /** 标题；无标题的四处（删除循环模板、删除班次×2、解除配对）传空串，面就不画标题行。 */
  title: ResourceStr;
  message: ResourceStr;
  /** 左：描边「放弃」那一侧。 */
  cancelText: ResourceStr;
  /** 右：实心「执行」那一侧。 */
  confirmText: ResourceStr;
  /** 确认侧走红（不可逆的删除/清空/解绑），false 走品牌粉。 */
  danger: boolean;
  /** true=确认侧；false=取消侧，点遮罩与返回键也算这一侧。 */
  onPick: (affirm: boolean) => void;
}

function hasLabel(v: ResourceStr): boolean {
  return typeof v === 'string' ? v.length > 0 : true;
}

/** 默认入场曲线：组件不读 AppStorage，动效开关在 askConfirm 侧算好后传进 options。 */
export function confirmEnterTransition(reduceMotion: boolean): TransitionEffect {
  return TransitionEffect.OPACITY
    .combine(TransitionEffect.scale({ x: ENTER_SCALE, y: ENTER_SCALE }))
    .animation({
      duration: DesignTokens.motion(reduceMotion, ENTER_MS),
      curve: DesignTokens.curve
    });
}

@Component
struct ConfirmDialogFace {
  title: ResourceStr = '';
  message: ResourceStr = '';
  cancelText: ResourceStr = '';
  confirmText: ResourceStr = '';
  danger: boolean = false;
  onPick: (affirm: boolean) => void = (): void => {
  };
  @State private pressedCancel: boolean = false;
  @State private pressedConfirm: boolean = false;
  // 装饰器实参必须是字面量，取值与 SENIOR_MODE_KEY 保持一致。
  @StorageProp('crd_senior_mode') senior: boolean = false;

  /** 确认侧的厚底：红档配 danger_deep，粉档配 brand_pink_deep（CSS `.btn` / `.btn.red`）。 */
  private deepColor(): Resource {
    return this.danger ? DesignTokens.dangerDeep : DesignTokens.primaryDeep;
  }

  build() {
    Column() {
      // 负 margin 把整张图抬起 74vp：卡片不 clip，所以耳朵和半张脸在卡面上沿之外，两只前爪搭在沿上。
      Image($r('app.media.mascot_peek'))
        .width(PEEK_W)
        .height(PEEK_H)
        .margin({ top: PEEK_MARGIN })
        .accessibilityLevel('no')

      if (hasLabel(this.title)) {
        Text(this.title)
          .fontSize(DesignTokens.fontBody)
          .fontWeight(FontWeight.Bold)
          .fontColor(DesignTokens.textPrimary)
          .textAlign(TextAlign.Center)
          .margin({ top: FIRST_TEXT_TOP })
      }
      if (hasLabel(this.message)) {
        Text(this.message)
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textSecondary)
          .lineHeight(MESSAGE_LINE)
          .textAlign(TextAlign.Center)
          .margin({ top: hasLabel(this.title) ? DesignTokens.space2 : FIRST_TEXT_TOP })
      }

      Row({ space: BTN_GAP }) {
        Button(this.cancelText)
          .layoutWeight(1)
          .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
          .backgroundColor(DesignTokens.card)
          .fontColor(DesignTokens.primary)
          .fontSize(DesignTokens.fontCaption)
          .fontWeight(700)
          .borderWidth(GHOST_BORDER)
          .borderColor(DesignTokens.primaryBorder)
          // 按下：下沿从 3vp 塌到 1vp、整颗下沉 2vp，占位高度不变（同 StatePanel 的主按钮）
          .shadow(DesignTokens.jelly(DesignTokens.borderWeak,
            this.pressedCancel ? DesignTokens.jellyDepthPressed : DesignTokens.jellyDepth))
          .translate({ y: this.pressedCancel ? DesignTokens.jellySink : 0 })
          .scale(this.pressedCancel
            ? { x: DesignTokens.pressScale, y: DesignTokens.pressScale }
            : { x: 1, y: 1 })
          .onTouch((e: TouchEvent) => {
            if (e.type === TouchType.Down) {
              this.pressedCancel = true;
            } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
              this.pressedCancel = false;
            }
          })
          .onClick(() => this.onPick(false))
        Button(this.confirmText)
          .layoutWeight(1)
          .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
          .backgroundColor(this.danger ? DesignTokens.danger : DesignTokens.primary)
          .fontColor(DesignTokens.heroText)
          .fontSize(DesignTokens.fontCaption)
          .fontWeight(700)
          .shadow(DesignTokens.jelly(this.deepColor(),
            this.pressedConfirm ? DesignTokens.jellyDepthPressed : DesignTokens.jellyDepth))
          .translate({ y: this.pressedConfirm ? DesignTokens.jellySink : 0 })
          .scale(this.pressedConfirm
            ? { x: DesignTokens.pressScale, y: DesignTokens.pressScale }
            : { x: 1, y: 1 })
          .onTouch((e: TouchEvent) => {
            if (e.type === TouchType.Down) {
              this.pressedConfirm = true;
            } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
              this.pressedConfirm = false;
            }
          })
          .onClick(() => this.onPick(true))
      }
      .width('100%')
      .margin({ top: DesignTokens.space4 })
    }
    .width(CARD_WIDTH)
    .constraintSize({ maxWidth: CARD_MAX_WIDTH })
    .padding({ left: PAD_X, right: PAD_X, top: PAD_Y, bottom: PAD_Y })
    .alignItems(HorizontalAlign.Center)
    .borderRadius(DesignTokens.radiusCard)
    .backgroundColor(DesignTokens.card)
    .shadow({ radius: SHADOW_RADIUS, color: DesignTokens.shadowSoft, offsetX: 0, offsetY: SHADOW_Y })
  }
}

@Builder
function confirmFace(p: ConfirmDialogParams) {
  ConfirmDialogFace({
    title: p.title,
    message: p.message,
    cancelText: p.cancelText,
    confirmText: p.confirmText,
    danger: p.danger,
    onPick: p.onPick
  })
}

/** 交给 ComponentContent 的面：askConfirm 每次开框都 new 一个 ComponentContent。 */
export const CONFIRM_DIALOG: WrappedBuilder<[ConfirmDialogParams]> = wrapBuilder(confirmFace);
