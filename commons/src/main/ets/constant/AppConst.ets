/** 应用级常量。 */
export class AppConst {
  static readonly APP_NAME: string = '同休日';
  static readonly TAG_PREFIX: string = 'CRD.';
  /** 引擎默认计算视界（天）。 */
  static readonly HORIZON_DAYS: number = 120;
  /** 邀请码有效期（毫秒，24h）。 */
  static readonly PAIRING_TTL_MS: number = 24 * 60 * 60 * 1000;
  /** 卡片定时刷新（毫秒，6h）。 */
  static readonly FORM_UPDATE_MS: number = 6 * 60 * 60 * 1000;
  /**
   * 《隐私政策》全文 URL（AGC 托管页）。
   * 占位空串 = 尚未上线：入口点击时 toast 提示，不跳转；URL 就绪后填入即生效。
   */
  static readonly PRIVACY_POLICY_URL: string = '';
}
