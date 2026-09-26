import { ScheduleCommandResult } from 'feature';
import { appToast } from './AppToast';

/**
 * 日程命令结果的统一提示。
 * 写入失败与"已落库但这一轮没重算"要分开说：后者数据并没丢，说"保存失败"会让人重复提交。
 */
export function toastCommand(r: ScheduleCommandResult, done: string): void {
  if (r.ok) {
    appToast(done);
    return;
  }
  appToast(r.errorCode === 'RECOMPUTE_FAILED' ? done + '，但共同时间暂未刷新' : '保存失败，请重试');
}
