/** 应用级常量。 */
export class AppConst {
  static readonly APP_NAME: string = '两人份';
  static readonly TAG_PREFIX: string = 'CRD.';
  /** 引擎默认计算视界（天）。 */
  static readonly HORIZON_DAYS: number = 120;
  /** 邀请码有效期（毫秒，24h）。 */
  static readonly PAIRING_TTL_MS: number = 24 * 60 * 60 * 1000;
  /** 卡片定时刷新（毫秒，6h）。 */
  static readonly FORM_UPDATE_MS: number = 6 * 60 * 60 * 1000;
  /**
   * AGC 托管的《隐私政策》地址；应用内保留离线全文，并提供托管版入口。
   */
  static readonly PRIVACY_POLICY_URL: string = 'https://agreement-drcn.hispace.dbankcloud.cn/index.html?lang=zh&agreementId=2050723336664704960';
}
