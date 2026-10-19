import { AnimatorResult, UIContext } from '@kit.ArkUI';

/** 单个组件的有限帧动画。取消前摘掉旧实例，迟到的帧/结束回调不再落地。 */
export class LocalTween {
  private animator: AnimatorResult | undefined = undefined;

  cancel(): void {
    const old = this.animator;
    this.animator = undefined;
    if (old !== undefined) {
      old.cancel();
    }
  }

  play(context: UIContext, from: number, to: number, duration: number,
    onFrame: (value: number) => void, onFinish: () => void = () => {}): void {
    this.cancel();
    if (duration <= 0 || from === to) {
      onFrame(to);
      onFinish();
      return;
    }
    const anim = context.createAnimator({
      duration: duration, easing: 'ease-out', delay: 0, fill: 'forwards',
      iterations: 1, direction: 'normal', begin: from, end: to
    });
    this.animator = anim;
    anim.onFrame = (value: number) => {
      if (this.animator === anim) {
        onFrame(value);
      }
    };
    anim.onFinish = () => {
      if (this.animator === anim) {
        this.animator = undefined;
        onFrame(to);
        onFinish();
      }
    };
    anim.play();
  }
}
