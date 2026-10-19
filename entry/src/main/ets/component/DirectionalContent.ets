import { LocalTween } from '../util/LocalTween';
import { DesignTokens } from '../theme/DesignTokens';

/** 单一内容先退后进。逐帧值留在叶节点，页头与真实滚动位置不参与动画。 */
@Component
export struct DirectionalContent {
  @Prop @Watch('switchToTarget') target: number = 0;
  onCommit: (target: number) => void = () => {};
  @BuilderParam content: () => void = this.placeholder;
  @StorageProp('crd_reduce_motion') @Watch('settle') reduceMotion: boolean = false;
  @StorageProp('crd_app_foreground') @Watch('onForegroundChanged') foreground: boolean = true;
  @State private slideRatio: number = 0;
  @State private moving: boolean = false;
  private visibleIndex: number = 0;
  private mounted: boolean = false;
  private widthVp: number = 24;
  private tween: LocalTween = new LocalTween();

  @Builder placeholder(): void {}

  aboutToAppear(): void {
    this.mounted = true;
    this.visibleIndex = this.target;
    this.onCommit(this.target);
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.tween.cancel();
  }

  onForegroundChanged(): void {
    if (!this.foreground) {
      this.settle();
    }
  }

  settle(): void {
    if (!this.mounted) {
      return;
    }
    this.tween.cancel();
    const target = this.target;
    if (this.visibleIndex !== target) {
      this.visibleIndex = target;
      this.onCommit(target);
    }
    this.slideRatio = 0;
    this.moving = false;
  }

  switchToTarget(): void {
    if (!this.mounted) {
      return;
    }
    if (this.reduceMotion || !this.foreground || this.visibleIndex === this.target) {
      this.settle();
      return;
    }
    const target = this.target;
    const direction: number = target > this.visibleIndex ? 1 : -1;
    this.moving = true;
    this.tween.play(this.getUIContext(), this.slideRatio, -direction, 110,
      (value: number) => { this.slideRatio = value; }, () => {
        if (!this.mounted || this.target !== target) {
          return;
        }
        this.visibleIndex = target;
        this.onCommit(target);
        this.slideRatio = direction;
        this.tween.play(this.getUIContext(), direction, 0, 110,
          (value: number) => { this.slideRatio = value; }, () => { this.moving = false; });
      });
  }

  build() {
    Stack() {
      Column() { this.content() }
        .width('100%').height('100%')
        .translate({ x: this.slideRatio * this.widthVp })
        .opacity(1 - Math.abs(this.slideRatio) * 0.3)
        .hitTestBehavior(this.moving ? HitTestMode.None : HitTestMode.Default)
    }
    .width('100%').height('100%').clip(true)
    .onAreaChange((_old: Area, area: Area) => { this.widthVp = Math.max(24, Number(area.width)); })
  }
}
