import { KeyCode } from '@kit.InputKit';
import { DesignTokens } from '../theme/DesignTokens';
import { GlassStyle } from './GlassSurface';
import { GlassStrength } from '../theme/MaterialPolicy';

/**
 * 温暖编辑感卡片：默认错角 8/21/21/21，偶数卡把切角换到右上。
 * Hero 变体是深莓底 + 暖白字 + 右下光晕，只给最重要的一个结果，不铺满整页。
 * glass=true 时这张卡走玻璃表面（首屏唯一主结果）：材质路径把底色/描边/阴影让给系统，
 * 实色路径仍用深莓近实色底，文字对比不随材质可用性变化。
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
  /** 玻璃表面：只有需要「浮在内容之上」的前景卡开启。 */
  glass: boolean = false;
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

  private surfaceFill(): ResourceColor {
    if (!this.glass) {
      return this.hero ? DesignTokens.hero : DesignTokens.card;
    }
    return GlassStyle.fill(DesignTokens.hero);
  }

  /** 焦点环优先级高于表面描边：键盘用户任何时候都要能看出这张卡被选中。 */
  private surfaceBorderWidth(): number {
    if (this.hasFocus) {
      return 2;
    }
    return this.glass ? GlassStyle.borderWidth() : 0;
  }

  private surfaceBorderColor(): ResourceColor {
    if (this.hasFocus) {
      return DesignTokens.focusRing;
    }
    return this.glass ? DesignTokens.glassBorder : Color.Transparent;
  }

  private surfaceShadow(): ShadowOptions {
    if (!this.glass) {
      return {
        radius: this.hero ? 38 : 32,
        color: DesignTokens.shadowSoft,
        offsetX: 0,
        offsetY: this.hero ? 18 : 13
      };
    }
    return GlassStyle.shadow();
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
          .accessibilityLevel('no')
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
    .systemMaterial(this.glass
      ? GlassStyle.material(GlassStrength.SOFT)
      : undefined)
    .backgroundColor(this.surfaceFill())
    .borderRadius(DesignTokens.cardRadius(this.cutTopLeft))
    .shadow(this.surfaceShadow())
    // 焦点环常驻透明边，避免聚焦时布局跳动。
    .border({
      width: this.surfaceBorderWidth(),
      color: this.surfaceBorderColor(),
      radius: DesignTokens.cardRadius(this.cutTopLeft)
    })
    .scale(this.isPressed
      ? { x: DesignTokens.pressScale, y: DesignTokens.pressScale }
      : { x: 1, y: 1 })
    // 容器卡必须把 focusable 留成 undefined 而不是 false：显式 false 会连卡内子树的
    // TextInput 一起吃掉点击落焦（实测输入法弹不出来，子级再声明 true 也救不回来）。
    .focusable(this.tappable ? true : undefined)
    // 可点卡读成一个整体（日期/时长/标签不被拆成三段）；容器卡必须分组关掉，
    // 否则卡内的按钮与开关在读屏里就没有独立落点了。
    .accessibilityGroup(this.tappable)
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
