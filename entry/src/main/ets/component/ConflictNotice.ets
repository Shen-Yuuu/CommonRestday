import { DesignTokens } from '../theme/DesignTokens';

/**
 * 计划冲突提示条：只在真有冲突时出现，点进去到共同时间的计划分段处理。
 * 首页只给"几条 + 是谁的时间变了"（reason 来自读模型，已按对方隐私等级降维），
 * 具体哪条计划、能不能改期由计划分段展示，这里不复制结论文案。
 */
@Component
export struct ConflictNotice {
  @Prop conflictCount: number = 0;
  /** 冲突归因摘要（'你的日程有变' / '对方时间发生变化' …）；'' = 读模型没给归因。 */
  @Prop reason: string = '';
  onTap: () => void = () => {};
  @StorageProp('crd_reduce_motion') reduceMotion: boolean = false;
  @State private isPressed: boolean = false;
  @State private hasFocus: boolean = false;

  private press(down: boolean): void {
    this.getUIContext().animateTo({
      duration: DesignTokens.motion(this.reduceMotion, DesignTokens.motionPress),
      curve: DesignTokens.curve
    }, () => {
      this.isPressed = down;
    });
  }

  build() {
    Row({ space: DesignTokens.space2 }) {
      Text('!')
        .fontSize(DesignTokens.fontCaption)
        .fontFamily(DesignTokens.fontSerif)
        .fontWeight(600)
        .fontColor(DesignTokens.danger)
        .textAlign(TextAlign.Center)
        .width(DesignTokens.space5)
        .height(DesignTokens.space5)
        .borderRadius(DesignTokens.radiusCardCut)
        .backgroundColor(DesignTokens.card)
      Column({ space: 2 }) {
        Text(this.conflictCount + ' 个计划的时间需要处理')
          .fontSize(DesignTokens.fontCaption)
          .fontWeight(600)
          .fontColor(DesignTokens.danger)
        Text(this.reason !== '' ? this.reason + ' · 去共同时间的计划分段处理' : '去共同时间的计划分段处理')
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textTertiary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('›')
        .fontSize(DesignTokens.fontBody)
        .fontColor(DesignTokens.textTertiary)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding(DesignTokens.space3)
    .constraintSize({ minHeight: DesignTokens.hitMin })
    .backgroundColor(DesignTokens.dangerBg)
    .borderRadius(DesignTokens.cardRadius(false))
    .border({
      width: this.hasFocus ? 2 : 1,
      color: this.hasFocus ? DesignTokens.focusRing : DesignTokens.dangerBorder,
      radius: DesignTokens.cardRadius(false)
    })
    .shadow({ radius: 32, color: DesignTokens.shadowSoft, offsetX: 0, offsetY: 13 })
    .scale(this.isPressed
      ? { x: DesignTokens.pressScale, y: DesignTokens.pressScale }
      : { x: 1, y: 1 })
    .focusable(true)
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
    .onClick(() => {
      this.onTap();
    })
    .transition(this.reduceMotion
      ? TransitionEffect.IDENTITY
      : TransitionEffect.OPACITY
        .combine(TransitionEffect.translate({ y: DesignTokens.enterOffset }))
        .animation({ duration: DesignTokens.motionItem, curve: DesignTokens.curve }))
  }
}
