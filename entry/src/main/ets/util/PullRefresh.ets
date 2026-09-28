import { Logger } from 'commons';
import { ScheduleUseCase } from 'feature';

const TAG = 'PullRefresh';

/**
 * 五个页面共用的那一次下拉：重算视界（已配对时顺带把对方最新快照拉下来），再由重算广播带动各页重读。
 *
 * 失败一定要吞在这里：调用方紧接着要把转圈落回地面，而"停在转圈里"比"读到上一次的结果"更糟——
 * 转圈不停用户没有任何再试的入口，下拉第二次就是了。
 */
export async function syncOnPull(): Promise<void> {
  try {
    await ScheduleUseCase.pullToRefresh();
  } catch (e) {
    Logger.warn(TAG, 'pull refresh failed: ' + (e as Error).message);
  }
}
