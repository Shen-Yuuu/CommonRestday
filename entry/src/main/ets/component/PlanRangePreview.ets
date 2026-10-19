import { DesignTokens } from '../theme/DesignTokens';
import { LocalTween } from '../util/LocalTween';
import { lerpRatio, rangeRatio } from '../util/VisualMotionMath';

/** 只动画预览条，不动画表单或 sheet 尺寸。再次调节从当前帧接向最新目标。 */
@Component
export struct PlanRangePreview {
  @Prop @Watch('resetWindow') winStart: number = 0;
  @Prop @Watch('resetWindow') winEnd: number = 0;
  @Prop @Watch('updateRange') planStart: number = 0;
  @Prop @Watch('updateRange') planEnd: number = 0;
  @StorageProp('crd_reduce_motion') @Watch('snapRange') reduceMotion: boolean = false;
  @StorageProp('crd_app_foreground') @Watch('onForegroundChanged') foreground: boolean = true;
  @State private startRatio: number = 0;
  @State private endRatio: number = 0;
  private tween: LocalTween = new LocalTween();
  private mounted: boolean = false;

  aboutToAppear(): void { this.mounted = true; this.snapRange(); }
  aboutToDisappear(): void { this.mounted = false; this.tween.cancel(); }
  resetWindow(): void { if (this.mounted) { this.snapRange(); } }
  onForegroundChanged(): void { if (!this.foreground) { this.snapRange(); } }

  snapRange(): void {
    this.tween.cancel();
    this.startRatio = rangeRatio(this.winStart, this.winEnd, this.planStart);
    this.endRatio = Math.max(this.startRatio, rangeRatio(this.winStart, this.winEnd, this.planEnd));
  }

  updateRange(): void {
    if (!this.mounted) { return; }
    const fromStart = this.startRatio;
    const fromEnd = this.endRatio;
    const toStart = rangeRatio(this.winStart, this.winEnd, this.planStart);
    const toEnd = Math.max(toStart, rangeRatio(this.winStart, this.winEnd, this.planEnd));
    this.tween.play(this.getUIContext(), 0, 1,
      DesignTokens.motion(this.reduceMotion || !this.foreground, 180), (progress: number) => {
        this.startRatio = lerpRatio(fromStart, toStart, progress);
        this.endRatio = lerpRatio(fromEnd, toEnd, progress);
      });
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      Row().width('100%').height(18).borderRadius(9).backgroundColor(DesignTokens.primaryBorder)
      Row().width(Math.max(0, this.endRatio - this.startRatio) * 100 + '%')
        .height(18).borderRadius(9).backgroundColor(DesignTokens.primary)
        .margin({ left: this.startRatio * 100 + '%' })
    }
    .width('100%').height(18).clip(true).accessibilityLevel('no').hitTestBehavior(HitTestMode.None)
  }
}
