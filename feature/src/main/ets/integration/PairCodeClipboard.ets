import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { Logger } from 'commons';

/** 只复制用户可口述的六位短码；不接收一次性确认凭据或配对链接。 */
export class PairCodeClipboard {
  static async copy(code: string): Promise<string> {
    if (!/^\d{6}$/.test(code)) {
      return '没有可复制的配对码';
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, code);
      await pasteboard.getSystemPasteboard().setData(data);
      return '配对码已复制';
    } catch (e) {
      Logger.warn('PairCodeClipboard', 'clipboard copy failed: ' + (e as BusinessError).code);
      return '复制失败，请手动记下配对码';
    }
  }
}
