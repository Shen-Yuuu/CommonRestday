import { accessibility } from '@kit.AccessibilityKit';
import { Logger } from 'commons';
import { MOTION_REDUCE_KEY, DesignTokens } from '../theme/DesignTokens';

const TAG = 'AccessibilityPolicy';

/**
 * 长辈模式状态键（accessibility.isSeniorModeEnabled，API 26.0.0）。
 * 组件侧只能写字面量：装饰器入参不接受常量，@StorageProp('crd_senior_mode') 与此保持一致。
 */
export const SENIOR_MODE_KEY: string = 'crd_senior_mode';
/** 屏幕朗读状态键（accessibility.isScreenReaderOpenSync，API 18）。 */
export const SCREEN_READER_KEY: string = 'crd_screen_reader';

/** 长辈模式下的主操作热区（vp）。普通档沿用令牌 hit_min，这一档是 docs/06 §3.10 C 的产品目标。 */
const SENIOR_HIT_VP: number = 48;

// SDK 在 on*/off* 的 NOTE 里点名：注册监听必须用命名函数，匿名函数每次调用都新建底层对象，
// 会造成内存泄漏；且必须在对象生命周期结束前 off，否则可能崩溃。所以下面三个都是模块级具名函数。
function onSeniorStateChange(enabled: boolean): void {
  AppStorage.setOrCreate<boolean>(SENIOR_MODE_KEY, enabled);
}

function onScreenReaderChange(enabled: boolean): void {
  AppStorage.setOrCreate<boolean>(SCREEN_READER_KEY, enabled);
}

function onAnimationReduceChange(enabled: boolean): void {
  AppStorage.setOrCreate<boolean>(MOTION_REDUCE_KEY, enabled);
}

/**
 * 系统无障碍状态的唯一读取方：把长辈模式、屏幕朗读、减少动态效果三件事写进 AppStorage，
 * 页面与组件只订阅结果，不各自调系统接口（也避免每个组件都注册一次监听）。
 * 三件事都有现成系统接口（26.0.0 / 18 / 23），本文件注册监听并即时同步。
 */
export class AccessibilityPolicy {
  private static listening: boolean = false;

  /** 挂载：先取一次当前值，再注册监听。任何一条系统探测失败都只降级，不影响界面可用。 */
  static attach(): void {
    try {
      AppStorage.setOrCreate<boolean>(SCREEN_READER_KEY, accessibility.isScreenReaderOpenSync());
    } catch (e) {
      Logger.warn(TAG, 'screen reader probe failed: ' + (e as Error).message);
    }
    try {
      AppStorage.setOrCreate<boolean>(MOTION_REDUCE_KEY, accessibility.isAnimationReduceEnabledSync());
    } catch (e) {
      Logger.warn(TAG, 'animation reduce probe failed: ' + (e as Error).message);
    }
    accessibility.isSeniorModeEnabled().then((enabled: boolean) => {
      AppStorage.setOrCreate<boolean>(SENIOR_MODE_KEY, enabled);
    }).catch((e: Error) => {
      Logger.warn(TAG, 'senior mode unavailable: ' + e.message);
    });

    if (AccessibilityPolicy.listening) {
      return;
    }
    try {
      accessibility.onSeniorModeStateChange(onSeniorStateChange);
      accessibility.on('screenReaderStateChange', onScreenReaderChange);
      accessibility.onAnimationReduceStateChange(onAnimationReduceChange);
      AccessibilityPolicy.listening = true;
    } catch (e) {
      Logger.warn(TAG, 'a11y listener unavailable, static snapshot only: ' + (e as Error).message);
    }
  }

  /** 卸载：与 attach 一一配对，三个监听都必须 off，漏掉就是 SDK 警告的泄漏/崩溃。 */
  static detach(): void {
    if (!AccessibilityPolicy.listening) {
      return;
    }
    try {
      accessibility.offSeniorModeStateChange(onSeniorStateChange);
      accessibility.off('screenReaderStateChange', onScreenReaderChange);
      accessibility.offAnimationReduceStateChange(onAnimationReduceChange);
    } catch (e) {
      Logger.warn(TAG, 'a11y listener off failed: ' + (e as Error).message);
    }
    AccessibilityPolicy.listening = false;
  }

  /** 主操作热区：长辈模式 48vp，其余沿用 44vp 令牌。 */
  static minHit(senior: boolean): Length {
    return senior ? SENIOR_HIT_VP : DesignTokens.hitMin;
  }
}
