import { hilog } from '@kit.PerformanceAnalysisKit';

/** 统一日志封装（domain 层禁用，仅 feature/data/cloud/entry 使用）。 */
export class Logger {
  private static DOMAIN: number = 0x0000;

  static info(tag: string, msg: string): void {
    hilog.info(Logger.DOMAIN, tag, '%{public}s', msg);
  }

  static warn(tag: string, msg: string): void {
    hilog.warn(Logger.DOMAIN, tag, '%{public}s', msg);
  }

  static error(tag: string, msg: string): void {
    hilog.error(Logger.DOMAIN, tag, '%{public}s', msg);
  }

  static debug(tag: string, msg: string): void {
    hilog.debug(Logger.DOMAIN, tag, '%{public}s', msg);
  }

  /**
   * 预算采样日志：设备侧用 `hdc shell hilog | grep PERF` 取 P50/P95。
   * 走 info 而不是 debug，是因为 debug 级在 release 包默认被过滤，验收时取不到数；
   * 前缀固定 "PERF" 而不是用 tag 区分，方便一行 grep 把所有标签的采样捞全。
   */
  static perf(tag: string, msg: string): void {
    hilog.info(Logger.DOMAIN, tag, 'PERF %{public}s', msg);
  }
}
