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
}
