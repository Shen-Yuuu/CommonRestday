import { KeyCode } from '@kit.InputKit';
import { DesignTokens } from '../theme/DesignTokens';
import { GlassStyle } from './GlassSurface';
import { GlassStrength } from '../theme/MaterialPolicy';

/**
 * Q糖卡片：默认错角 10/26/26/26，偶数卡把切角换到右上，读起来像一张贴歪的贴纸。
 * Hero 变体是粉→珊瑚斜向渐变 + 暖白字 + 右下气泡，只给最重要的一个结果，不铺满整页。
 * glass=true 时这张卡走玻璃表面：材质路径把描边/阴影让给系统，渐变仍画在表面之上，
 * 所以 hero 的读法不随材质可用性变化。
 * 深浅色随资源自动切换；按压只做缩放，开启减少动效时时长归零。
 */
@Component
export struct EditorialCard {
  /** 粉渐变 Hero 变体（文字需用 DesignTokens.heroText）。 */
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

  /**
   * Hero 光晕画在内容层上，而不是当 Stack 的子节点。
   * 圆形子节点会参与 Stack 测量：148vp 的圆把矮卡（「我的」身份卡）顶成 148vp 高，
   * 而 Stack 是 BottomEnd 对齐，于是内容沉底、卡顶空出一条约 43vp 的无内容带。
   * 渐变跟随内容盒尺寸，卡片高度重新由内容决定；非 hero 卡退化成全透明。
   */
  private glowOf(): RadialGradientOptions {
    if (!this.hero) {
      return {
        center: [0, 0],
        radius: 0,
        colors: [[Color.Transparent, 0], [Color.Transparent, 1]]
      };
    }
    // 圆心按首页 Hero（338×161vp）反解：原来那颗 148vp 圆盘 BottomEnd 对齐后再 translate(34,55)，
    // 圆心落在卡片局部 (298,142)，即内容盒的 88%/88%（内容盒就是卡片盒，padding 在盒内）。
    // 0.9 之后才淡出，保留旧圆盘那道硬边扇形。
    return {
      center: ['88%', '88%'],
      radius: 74,
      colors: [[DesignTokens.heroGlow, 0], [DesignTokens.heroGlow, 0.9], [Color.Transparent, 1]]
    };
  }

  private surfaceFill(): ResourceColor {
    if (!this.glass) {
      return this.hero ? DesignTokens.hero : DesignTokens.card;
    }
    return GlassStyle.fill(DesignTokens.hero);
  }

  /** hero 走三段斜向渐变；正文卡给一条全透明渐变，等于不画任何东西。 */
  private surfaceGradient(): LinearGradientOptions {
    if (!this.hero) {
      return { angle: 135, colors: [[Color.Transparent, 0], [Color.Transparent, 1]] };
    }
    return {
      angle: 135,
      colors: [[DesignTokens.sunsetFrom, 0], [DesignTokens.primary, 0.48], [DesignTokens.sunsetTo, 1]]
    };
  }

  private surfaceRadius(): BorderRadiuses {
    return this.hero ? DesignTokens.heroRadius() : DesignTokens.cardRadius(this.cutTopLeft);
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
        radius: this.hero ? DesignTokens.heroShadowRadius : DesignTokens.cardShadowRadius,
        color: DesignTokens.shadowSoft,
        offsetX: 0,
        offsetY: this.hero ? DesignTokens.heroShadowOffsetY : DesignTokens.cardShadowOffsetY
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
      Column() {
        this.content()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(this.innerPadding())
      .radialGradient(this.glowOf())
    }
    .width('100%')
    .clip(true)
    .systemMaterial(this.glass
      ? GlassStyle.material(GlassStrength.SOFT)
      : undefined)
    .backgroundColor(this.surfaceFill())
    .linearGradient(this.surfaceGradient())
    .borderRadius(this.surfaceRadius())
    .shadow(this.surfaceShadow())
    // 焦点环常驻透明边，避免聚焦时布局跳动。
    .border({
      width: this.surfaceBorderWidth(),
      color: this.surfaceBorderColor(),
      radius: this.surfaceRadius()
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
