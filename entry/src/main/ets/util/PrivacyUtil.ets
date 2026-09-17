import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppConst, Logger } from 'commons';

const TAG = 'PrivacyUtil';

/**
 * 打开《隐私政策》全文（AppConst.PRIVACY_POLICY_URL，AGC 托管页）：
 * - URL 为占位空串（全文未上线）→ toast 提示，不跳转；
 * - openLink 失败（无浏览器等）→ 同样 toast 提示，不崩溃。
 * emptyHint 由调用方传入资源文案（隐私弹窗与"我的"页共用）。
 */
export function openPrivacyPolicy(context: common.UIAbilityContext, emptyHint: ResourceStr): void {
  const url = AppConst.PRIVACY_POLICY_URL;
  if (url === '') {
    promptAction.showToast({ message: emptyHint });
    return;
  }
  context.openLink(url).catch((e: Error) => {
    Logger.warn(TAG, 'openLink failed: ' + e.message);
    promptAction.showToast({ message: emptyHint });
  });
}
