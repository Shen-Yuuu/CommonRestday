import { SettingsStore } from 'data';
import { SHARE_LEVEL_UNKNOWN, shareLevelFromStore } from '../model/CloudSyncRules';

/**
 * 共享等级的**唯一读取口**（批次 AO·AO4）：偏好未初始化、脏值、越界一律是「未知」，不折成任何一档。
 *
 * 三条路都读不出档位，而旧的三处读法各猜了一个答案：
 * - 引擎侧 `SettingsStore.getShareLevel()` 直取，能把 NaN 原样喂进快照生成；
 * - 「我的」页那个读取口在异常时伪造 L2，于是实际存着 L3 的手机念成 L2；
 * - 页面初值再写死一个 2，回填之前的那一帧也念 L2。
 * 折成 L1 还是反向误导（把共享得最少说成用户的决定），折成 L3 更是直接把隐私档位念大——
 * 所以这里只出「知道是几档」与「不知道」两种结果，剩下两档（伪造与保存）由调用方各自封口。
 *
 * 单独立一个文件是为了让**引擎和界面走同一句**：这条口径若在两侧各写一遍，
 * 就会重演 D-59 那一族病（同一个数两个读法）。`usecase` 而不是 `model`，因为它要读偏好。
 */
export class ShareLevelReader {
  static read(): number {
    try {
      return shareLevelFromStore(SettingsStore.getShareLevel());
    } catch (e) {
      return SHARE_LEVEL_UNKNOWN;
    }
  }
}
