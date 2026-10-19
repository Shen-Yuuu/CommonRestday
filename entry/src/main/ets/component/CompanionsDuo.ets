import { AnimatorResult } from '@kit.ArkUI';
import { companionSlotWidth, companionSquishFrame, companionSquishSpec, nextCompanionCombo } from '../util/CompanionMotion';
import { CompanionScene } from './CompanionScene';

/** Only blinking and the existing touch feedback. No continuous ambient animation. */
@Component
export struct CompanionsDuo {
  @Prop @Watch('onPlaybackChanged') active: boolean = true;
  @Prop availableWidth: number = 0;
  @StorageProp('crd_app_foreground') @Watch('onPlaybackChanged') foreground: boolean = false;
  @StorageProp('crd_root_page_visible') @Watch('onPlaybackChanged') rootVisible: boolean = true;
  @StorageProp('crd_reduce_motion') @Watch('onPlaybackChanged') reduceMotion: boolean = false;
  @State private bunnyClosed: boolean = false;
  @State private bearClosed: boolean = false;
  @State private squishX: number = 1;
  @State private squishY: number = 1;
  @State private squishAngle: number = 0;
  private mounted: boolean = false;
  private visible: boolean = true;
  private combo: number = 0;
  private lastTap: number = 0;
  private touchHandled: boolean = false;
  private bunnyTimer: number = -1;
  private bearTimer: number = -1;
  private blinkEpoch: number = 0;
  private squishAnimator: AnimatorResult | undefined = undefined;

  private canInteract(): boolean {
    return this.mounted && this.active && this.foreground && this.rootVisible && this.visible;
  }

  private stopBlinking(): void {
    this.blinkEpoch++;
    if (this.bunnyTimer >= 0) clearTimeout(this.bunnyTimer);
    if (this.bearTimer >= 0) clearTimeout(this.bearTimer);
    this.bunnyTimer = -1; this.bearTimer = -1;
    this.bunnyClosed = false; this.bearClosed = false;
  }

  private scheduleBlink(bear: boolean, close: boolean): void {
    if (!this.canInteract() || this.reduceMotion || this.squishAnimator !== undefined) return;
    const epoch = this.blinkEpoch;
    const delay = close ? (bear ? 7000 : 5000) + Math.random() * 3000 : 150;
    const timer = setTimeout(() => {
      if (epoch !== this.blinkEpoch || !this.canInteract() || this.reduceMotion
        || this.squishAnimator !== undefined) return;
      if (bear) { this.bearTimer = -1; this.bearClosed = close; }
      else { this.bunnyTimer = -1; this.bunnyClosed = close; }
      this.scheduleBlink(bear, !close);
    }, delay);
    if (bear) this.bearTimer = timer; else this.bunnyTimer = timer;
  }

  private startBlinking(): void {
    if (!this.canInteract() || this.reduceMotion || this.squishAnimator !== undefined) return;
    if (this.bunnyTimer < 0) this.scheduleBlink(false, true);
    if (this.bearTimer < 0) this.scheduleBlink(true, true);
  }

  private stopAll(): void {
    this.stopBlinking();
    const old = this.squishAnimator;
    this.squishAnimator = undefined;
    if (old !== undefined) old.cancel();
    this.squishX = 1; this.squishY = 1; this.squishAngle = 0;
    this.combo = 0; this.lastTap = 0; this.touchHandled = false;
  }

  private squish(): void {
    if (!this.canInteract()) return;
    this.stopBlinking();
    const now = Date.now();
    this.combo = nextCompanionCombo(this.combo, this.lastTap, now);
    this.lastTap = now;
    const spec = companionSquishSpec(this.combo, this.reduceMotion, Math.random(), Math.random(), Math.random());
    const fromX = this.squishX, fromY = this.squishY, fromAngle = this.squishAngle;
    const old = this.squishAnimator;
    this.squishAnimator = undefined;
    if (old !== undefined) old.cancel();
    const anim = this.getUIContext().createAnimator({
      duration: spec.duration, easing: 'linear', delay: 0, fill: 'forwards',
      iterations: 1, direction: 'normal', begin: 0, end: spec.duration
    });
    this.squishAnimator = anim;
    anim.onFrame = (elapsed: number) => {
      if (this.squishAnimator !== anim || !this.canInteract()) return;
      const pose = companionSquishFrame(spec, elapsed, fromX, fromY, fromAngle);
      this.squishX = pose.x; this.squishY = pose.y; this.squishAngle = pose.angle;
    };
    anim.onFinish = () => {
      if (this.squishAnimator !== anim) return;
      this.squishAnimator = undefined;
      this.squishX = 1; this.squishY = 1; this.squishAngle = 0;
      this.startBlinking();
    };
    anim.play();
  }

  private handleTouch(type: TouchType, source: SourceType): void {
    if (type === TouchType.Cancel) { this.stopAll(); this.startBlinking(); return; }
    if (source === SourceType.TouchScreen && type === TouchType.Down && this.canInteract()) {
      this.touchHandled = true; this.squish();
    }
  }

  private activateClick(source: SourceType): void {
    if (source !== SourceType.TouchScreen || !this.touchHandled) this.squish();
    this.touchHandled = false;
  }

  onPlaybackChanged(): void {
    if (!this.canInteract() || this.reduceMotion) this.stopAll();
    this.startBlinking();
  }

  aboutToAppear(): void { this.mounted = true; this.onPlaybackChanged(); }
  aboutToDisappear(): void { this.mounted = false; this.stopAll(); }

  build() {
    Button({ type: ButtonType.Normal, stateEffect: false }) {
      Stack({ alignContent: Alignment.TopStart }) {
        CompanionScene({ bearClosed: this.bearClosed, bunnyClosed: this.bunnyClosed,
          sceneWidth: companionSlotWidth(this.availableWidth) })
      }
      .width(companionSlotWidth(this.availableWidth)).height(44).clip(true)
      .scale({ x: this.squishX, y: this.squishY, centerX: '50%', centerY: '100%' })
      .rotate({ angle: this.squishAngle, centerX: '50%', centerY: '100%' })
      .hitTestBehavior(HitTestMode.None)
    }
    .width(companionSlotWidth(this.availableWidth)).height(44)
    // Move the entire viewport, not the art inside its clip: ears/paws stay intact.
    .offset({ y: 3 })
    .padding(0).backgroundColor(Color.Transparent).borderRadius(0).clip(true)
    .accessibilityText('布布和休休')
    .accessibilityDescription('轻点捏一下，仅播放装饰动画，不影响日程')
    .onTouch((event: TouchEvent) => {
      event.stopPropagation(); this.handleTouch(event.type, event.source);
    })
    .onClick((event: ClickEvent) => { this.activateClick(event.source); })
    .onVisibleAreaChange([0, 1], (isVisible: boolean) => {
      if (this.visible === isVisible) return;
      this.visible = isVisible; this.onPlaybackChanged();
    })
  }
}
