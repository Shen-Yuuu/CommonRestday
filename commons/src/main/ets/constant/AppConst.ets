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
   * 《隐私政策》在线版地址（商店提审材料与托管页用）。
   *
   * 阶段 6R.4 起应用内的全文不再依赖它：首发包没有联网权限，全文随包出厂
   * （entry/component/PrivacyPolicySheet），空串时也只是不显示那一行链接，
   * 不再 toast「即将上线」把用户挡在全文外面。
   */
  static readonly PRIVACY_POLICY_URL: string = '';
}
