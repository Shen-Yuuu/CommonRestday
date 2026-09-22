import { KeyCode } from '@kit.InputKit';
import { DesignTokens } from '../theme/DesignTokens';

/**
 * 温暖编辑感卡片：默认错角 8/21/21/21，偶数卡把切角换到右上。
 * Hero 变体是深莓底 + 暖白字 + 右下光晕，只给最重要的一个结果，不铺满整页。
 * 深浅色随资源自动切换；按压只做缩放，开启减少动效时时长归零。
 */
@Component
export struct EditorialCard {
  /** 深莓 Hero 变体（文字需用 DesignTokens.heroText）。 */
  hero: boolean = false;
  /** 切角在左上（true）还是右上（false）。 */
  cutTopLeft: boolean = true;
  /** 是否可点：决定是否响应按压、焦点与键盘回车。 */
  tappable: boolean = false;
  onTapCard: () => void = () => {};
  // 装饰器实参必须是字面量，取值与 MOTION_REDUCE_KEY 保持一致。
  @StorageProp('crd_reduce_motion') reduceMotion: boolean = false;
  @BuilderParam content: () => void = this.placeholder;
  @State private isPressed: boolean = false;
  @State private hasFocus: boolean = false;

  @Builder
  placeholder(): void {
  }

  private innerPadding(): Resource {
    return this.hero ? DesignTokens.space5 : DesignTokens.space4;
  }

  private press(down: boolean): void {
    if (!this.tappable) {
      return;
    }
    this.getUIContext().animateTo({ duration: DesignTokens.motion(this.reduceMotion, DesignTokens.motionPress),
      curve: DesignTokens.curve }, () => {
      this.isPressed = down;
    });
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      if (this.hero) {
        Circle()
          .width(148)
          .height(148)
          .fill(DesignTokens.heroGlow)
          .translate({ x: 34, y: 55 })
      }
      Column() {
        this.content()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(this.innerPadding())
    }
    .width('100%')
    .clip(true)
    .backgroundColor(this.hero ? DesignTokens.hero : DesignTokens.card)
    .borderRadius(DesignTokens.cardRadius(this.cutTopLeft))
    .shadow({
      radius: this.hero ? 38 : 32,
      color: DesignTokens.shadowSoft,
      offsetX: 0,
      offsetY: this.hero ? 18 : 13
    })
    // 焦点环常驻 2vp 透明边，避免聚焦时布局跳动。
    .border({
      width: 2,
      color: this.hasFocus ? DesignTokens.focusRing : Color.Transparent,
      radius: DesignTokens.cardRadius(this.cutTopLeft)
    })
    .scale(this.isPressed
      ? { x: DesignTokens.pressScale, y: DesignTokens.pressScale }
      : { x: 1, y: 1 })
    .focusable(this.tappable)
    .onFocus(() => {
      this.hasFocus = true;
    })
    .onBlur(() => {
      this.hasFocus = false;
    })
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.press(true);
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        this.press(false);
      }
    })
    .onKeyEvent((e: KeyEvent) => {
      if (this.tappable && e.type === KeyType.Down
        && (e.keyCode === KeyCode.KEYCODE_ENTER || e.keyCode === KeyCode.KEYCODE_DPAD_CENTER)) {
        this.onTapCard();
      }
    })
    .onClick(() => {
      if (this.tappable) {
        this.onTapCard();
      }
    })
    .transition(this.reduceMotion
      ? TransitionEffect.IDENTITY
      : TransitionEffect.OPACITY
        .combine(TransitionEffect.translate({ y: DesignTokens.enterOffset }))
        .animation({ duration: DesignTokens.motionItem, curve: DesignTokens.curve }))
  }
}
