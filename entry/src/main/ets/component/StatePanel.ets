import { DesignTokens } from '../theme/DesignTokens';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';

/** 状态面板种类：加载中 / 空结果 / 可恢复错误 / 降级可用。 */
export enum StatePanelKind {
  LOADING = 'LOADING',
  EMPTY = 'EMPTY',
  ERROR = 'ERROR',
  DEGRADED = 'DEGRADED'
}

/** ResourceStr 既可能是字符串也可能是资源引用，只有空字符串算“没有文案”。 */
function hasLabel(v: ResourceStr): boolean {
  return typeof v === 'string' ? v.length > 0 : true;
}

/**
 * 统一状态面板：加载、空、错误、降级四种页面级状态共用一个位置与排版。
 * 状态不只靠颜色区分——每种状态有独立符号，且标题/说明始终给出文字；
 * 动作按钮是胶囊主按钮，热区不小于 44vp，支持键盘焦点环与按压反馈。
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
    if (this.kind === StatePanelKind.ERROR) {
      return '!';
    }
    if (this.kind === StatePanelKind.DEGRADED) {
      return '↻';
    }
    return '○';
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
      } else {
        Text(this.markGlyph())
          .fontSize(DesignTokens.fontBody(this.senior))
          .fontColor(this.markFg())
          .fontFamily(DesignTokens.fontSerif)
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
          .fontSize(DesignTokens.fontBody(this.senior))
          .fontColor(DesignTokens.textSecondary)
          .fontWeight(FontWeight.Medium)
          .textAlign(TextAlign.Center)
          .margin({ top: DesignTokens.space3 })
      }
      if (hasLabel(this.description)) {
        Text(this.description)
          .fontSize(DesignTokens.fontCaption(this.senior))
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
          .fontSize(DesignTokens.fontCaption(this.senior))
          .fontWeight(600)
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
