import { DesignTokens } from '../theme/DesignTokens';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';

/** 状态面板种类：加载中 / 空结果 / 可恢复错误。 */
export enum StatePanelKind {
  LOADING = 'LOADING',
  EMPTY = 'EMPTY',
  ERROR = 'ERROR'
}

/** ResourceStr 既可能是字符串也可能是资源引用，只有空字符串算“没有文案”。 */
function hasLabel(v: ResourceStr): boolean {
  return typeof v === 'string' ? v.length > 0 : true;
}

/**
 * 睡觉的休休：7 分甜把空态当情绪位，用它替掉 ○ 记号，静立不动效（原型 .empty-bunny）。
 * 空态在 StatePanel 和各页自绘卡片里都有，所以单独成件，两处共用同一份几何。
 */
@Component
export struct SleepBunny {
  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Image($r('app.media.mascot_bunny_sleep'))
        .width(76)
        .height(76)
        // 吉祥物是装饰，下面两行文字才是状态说明
        .accessibilityLevel('no')
      Text('Z z…')
        .fontSize(DesignTokens.fontCaption)
        .fontFamily(DesignTokens.fontRound)
        .fontWeight(FontWeight.Bolder)
        .fontColor(DesignTokens.primary)
        // 拟声词不承载信息，念出来只是噪音
        .accessibilityLevel('no')
    }
    .width(76)
    .height(76)
  }
}

/**
 * 统一状态面板：加载、空、错误三种页面级状态共用一个位置与排版。
 * 状态不只靠颜色区分——每种状态有独立符号，且标题/说明始终给出文字；
 * 动作按钮是胶囊主按钮，热区不小于 44vp，支持键盘焦点环与按压反馈。
 * 「降级可用」没有做成一档：页面级只有一块区域可用时说的是整页，而真正需要
 * 一行内提示的地方（云同步三态）走 NoticeBar，见配对协议 §8 第 8 条。
 */
@Component
export struct StatePanel {
  kind: StatePanelKind = StatePanelKind.EMPTY;
  title: ResourceStr = '';
  description: ResourceStr = '';
  actionLabel: ResourceStr = '';
  onAction: () => void = () => {};
  @StorageProp('crd_reduce_motion') reduceMotion: boolean = false;
  // 装饰器实参必须是字面量，取值与 SENIOR_MODE_KEY 保持一致。
  @StorageProp('crd_senior_mode') senior: boolean = false;
  @State private isActionPressed: boolean = false;
  @State private hasActionFocus: boolean = false;

  private markGlyph(): string {
    return this.kind === StatePanelKind.ERROR ? '!' : '○';
  }

  private markFg(): Resource {
    return this.kind === StatePanelKind.ERROR ? DesignTokens.danger : DesignTokens.textTertiary;
  }

  private markBg(): Resource {
    return this.kind === StatePanelKind.ERROR ? DesignTokens.dangerBg : DesignTokens.fillWeak;
  }

  private pressAction(down: boolean): void {
    this.getUIContext().animateTo({
      duration: DesignTokens.motion(this.reduceMotion, DesignTokens.motionPress),
      curve: DesignTokens.curve
    }, () => {
      this.isActionPressed = down;
    });
  }

  build() {
    Column() {
      if (this.kind === StatePanelKind.LOADING) {
        LoadingProgress()
          .width(30)
          .height(30)
          .color(DesignTokens.textTertiary)
          .accessibilityText('正在加载')
      } else if (this.kind === StatePanelKind.EMPTY) {
        SleepBunny()
      } else {
        Text(this.markGlyph())
          .fontSize(DesignTokens.fontBody)
          .fontColor(this.markFg())
          .fontFamily(DesignTokens.fontRound)
          .textAlign(TextAlign.Center)
          .width(40)
          .height(40)
          .backgroundColor(this.markBg())
          .borderRadius(DesignTokens.cardRadius(true))
          // 状态符号 + 底色只是视觉分区，下面的标题才是朗读内容
          .accessibilityLevel('no')
      }
      if (hasLabel(this.title)) {
        Text(this.title)
          .fontSize(DesignTokens.fontBody)
          .fontColor(DesignTokens.textSecondary)
          .fontWeight(FontWeight.Medium)
          .textAlign(TextAlign.Center)
          .margin({ top: DesignTokens.space3 })
      }
      if (hasLabel(this.description)) {
        Text(this.description)
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textTertiary)
          .textAlign(TextAlign.Center)
          .lineHeight(DesignTokens.space5)
          .margin({ top: DesignTokens.space2 })
      }
      if (hasLabel(this.actionLabel)) {
        Button(this.actionLabel)
          .type(ButtonType.Normal)
          .borderRadius(DesignTokens.radiusPill)
          // 不用固定 height：2.0× 字体下按钮要跟着文字长高，长辈模式再抬到 48vp
          .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
          .padding({ left: DesignTokens.space5, right: DesignTokens.space5 })
          .backgroundColor(DesignTokens.primary)
          .fontColor(DesignTokens.heroText)
          .fontSize(DesignTokens.fontCaption)
          .fontWeight(700)
          // 果冻厚底：按下时下沿塌到 1vp、整颗下沉 2vp，不改变占位高度。
          .shadow(DesignTokens.jelly(DesignTokens.primaryDeep,
            this.isActionPressed ? DesignTokens.jellyDepthPressed : DesignTokens.jellyDepth))
          .translate({ y: this.isActionPressed ? DesignTokens.jellySink : 0 })
          .scale(this.isActionPressed
            ? { x: DesignTokens.pressScale, y: DesignTokens.pressScale }
            : { x: 1, y: 1 })
          .border({
            width: 2,
            color: this.hasActionFocus ? DesignTokens.focusRing : Color.Transparent,
            radius: DesignTokens.radiusPill
          })
          .focusable(true)
          .onFocus(() => {
            this.hasActionFocus = true;
          })
          .onBlur(() => {
            this.hasActionFocus = false;
          })
          .onTouch((e: TouchEvent) => {
            if (e.type === TouchType.Down) {
              this.pressAction(true);
            } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
              this.pressAction(false);
            }
          })
          .onClick(() => {
            this.onAction();
          })
          .margin({ top: DesignTokens.space4 })
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({
      top: DesignTokens.space6,
      bottom: DesignTokens.space6,
      left: DesignTokens.space4,
      right: DesignTokens.space4
    })
    .transition(this.reduceMotion
      ? TransitionEffect.IDENTITY
      : TransitionEffect.OPACITY.animation({ duration: DesignTokens.motionFade, curve: DesignTokens.curve }))
  }
}
