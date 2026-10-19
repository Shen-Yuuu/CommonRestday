import { DesignTokens } from '../theme/DesignTokens';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';
import { LocalTween } from '../util/LocalTween';

/** 同步结果留在点击位置，等待指示只在真实请求期间存在。 */
@Component
export struct SyncFeedbackButton {
  @Prop @Watch('onFeedbackChanged') busy: boolean = false;
  @Prop @Watch('onFeedbackChanged') result: string = '';
  @Prop disabled: boolean = false;
  onRetry: () => void = () => {};
  @StorageProp('crd_senior_mode') senior: boolean = false;
  @State private contentAlpha: number = 1;
  private tween: LocalTween = new LocalTween();
  private mounted: boolean = false;

  aboutToAppear(): void {
    this.mounted = true;
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.tween.cancel();
  }

  onFeedbackChanged(): void {
    if (!this.mounted) {
      return;
    }
    this.contentAlpha = 0.45;
    const reduce: boolean = AppStorage.get<boolean>('crd_reduce_motion') ?? false;
    this.tween.play(this.getUIContext(), 0.45, 1, DesignTokens.motion(reduce, 160),
      (alpha: number) => { this.contentAlpha = alpha; });
  }

  build() {
    Button() {
      Row({ space: 8 }) {
        if (this.busy) {
          LoadingProgress().width(18).height(18).color(DesignTokens.textAccent)
            .accessibilityLevel('no')
        }
        Text(this.busy ? '同步中…' : (this.result !== '' ? this.result : '手动重试'))
          .fontSize(DesignTokens.fontCaption).fontWeight(600).fontColor(DesignTokens.textAccent)
      }.justifyContent(FlexAlign.Center).opacity(this.contentAlpha)
    }
    .width('100%').constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
    .backgroundColor(DesignTokens.primaryBg).stateEffect(false)
    .enabled(!this.disabled && !this.busy)
    .accessibilityText(this.busy ? '同步中，请稍候' : (this.result || '手动重试云同步'))
    .onClick(() => this.onRetry())
  }
}
