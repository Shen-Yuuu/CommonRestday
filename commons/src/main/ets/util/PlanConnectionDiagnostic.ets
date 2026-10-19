export interface PlanConnectionDiagnostic { stage: string; sdkCode: string; }
interface SdkFailureCode { code?: number | string; }

const STAGES: string[] = ['setup', 'auth.context', 'auth.resource', 'auth.init', 'auth.user',
  'auth.signIn', 'auth.identity', 'auth.token', 'auth.recheck', 'key.identity', 'key.partnerProof',
  'key.confirmProof', 'key.hash', 'key.identity.lookup', 'key.identity.generate', 'key.identity.export',
  'key.identity.format', 'key.identity.encode', 'key.agree', 'key.agree.lookup', 'key.agree.format',
  'key.agree.init', 'key.agree.update', 'key.agree.finish', 'key.agree.available', 'key.seal.init', 'key.seal.finish',
  'key.available', 'store.read', 'store.write', 'store.cleanup',
  'state.check', 'cloud.input', 'cloud.call', 'cloud.decode', 'cloud.reply', 'reply.validate',
  'reply.validate.status', 'reply.validate.identity', 'reply.validate.capability', 'reply.validate.revision',
  'reply.validate.expiry', 'reply.validate.binding', 'reply.validate.transition', 'reply.validate.peer',
  'reply.validate.invite', 'reply.validate.proof'];
const CODES: string[] = ['OK', 'BAD_REQUEST', 'FEATURE_DISABLED', 'BUSY', 'STATE_INVALID', 'RESULT_UNKNOWN',
  'SESSION_CHANGED', 'IDENTITY_CHANGED', 'KEY_CHANGED', 'PARTNER_LINK_REQUIRED', 'CLEANUP_REQUIRED',
  'RESUME_REQUIRED', 'NO_PROGRESS', 'FORBIDDEN', 'PROOF_UNAVAILABLE', 'RECOVERY_REQUIRED', 'INVALID_REPLY',
  'KEY_UNAVAILABLE', 'AUTH_REJECTED', 'CAPABILITY_UNAVAILABLE', 'CODE_EXPIRED', 'CODE_TAKEN',
  'CODE_COLLISION', 'PAIR_NOT_READY', 'REQUEST_REUSED', 'VERSION_CONFLICT', 'BACKLOG_FULL',
  'NOT_FOUND', 'CONFIG_MISSING', 'CODE_SPACE_BUSY', 'VERSION_LIMIT'];

/** Only bounded numeric SDK codes are public; messages, stacks and request objects are never copied. */
export function planConnectionSdkCode(error: Object | null): string {
  if (error === null || typeof error !== 'object') return '';
  try {
    const code = (error as SdkFailureCode).code;
    if (typeof code === 'number' && Number.isSafeInteger(code) && Math.abs(code) <= 999999999999) return String(code);
    if (typeof code === 'string' && /^-?\d{1,12}$/.test(code)) return code;
  } catch { /* A throwing accessor cannot break the original failure path. */ }
  return '';
}
export function planConnectionDiagnostic(stage: string, sdkCode: string = ''): PlanConnectionDiagnostic {
  return { stage: STAGES.includes(stage) ? stage : 'setup', sdkCode: /^-?\d{1,12}$/.test(sdkCode) ? sdkCode : '' };
}
export class PlanConnectionFailure extends Error {
  diagnostic: PlanConnectionDiagnostic;
  constructor(stage: string, cause: Object | null, message: string) {
    super(message);
    this.diagnostic = planConnectionDiagnostic(stage, planConnectionSdkCode(cause));
  }
}
export function planConnectionStageLabel(stage: string): string {
  if (stage === 'auth.context') return '认证上下文';
  if (stage === 'auth.resource') return '读取认证配置';
  if (stage === 'auth.init') return '初始化匿名认证';
  if (stage === 'auth.user') return '读取匿名身份';
  if (stage === 'auth.signIn') return '匿名登录';
  if (stage === 'auth.identity') return '检查匿名身份';
  if (stage === 'auth.token') return '获取认证凭据';
  if (stage === 'auth.recheck') return '复核匿名身份';
  if (stage === 'key.identity') return '准备设备密钥';
  if (stage === 'key.hash') return '准备密钥索引';
  if (stage === 'key.identity.lookup') return '检查设备密钥';
  if (stage === 'key.identity.generate') return '生成设备密钥';
  if (stage === 'key.identity.export') return '导出设备公钥';
  if (stage === 'key.identity.format') return '检查设备公钥格式';
  if (stage === 'key.identity.encode') return '编码设备公钥';
  if (stage === 'key.partnerProof') return '准备或检查伴侣凭证';
  if (stage === 'key.confirmProof') return '准备确认凭证';
  if (stage === 'key.agree' || stage === 'key.available') return '建立计划密钥';
  if (stage === 'key.agree.lookup') return '检查协商密钥';
  if (stage === 'key.agree.format') return '准备协商公钥格式';
  if (stage === 'key.agree.init') return '初始化密钥协商';
  if (stage === 'key.agree.update') return '传入协商公钥';
  if (stage === 'key.agree.finish') return '完成密钥协商';
  if (stage === 'key.agree.available') return '检查计划密钥';
  if (stage === 'key.seal.init') return '初始化计划加密';
  if (stage === 'key.seal.finish') return '完成计划加密';
  if (stage === 'store.read' || stage === 'store.write' || stage === 'store.cleanup') return '读写本机连接进度';
  if (stage === 'cloud.input') return '检查云调用参数';
  if (stage === 'cloud.call') return '调用共同计划云服务';
  if (stage === 'cloud.decode') return '解析云端回包';
  if (stage === 'cloud.reply' || stage === 'reply.validate') return '检查云端连接结果';
  if (stage === 'reply.validate.status') return '检查连接状态';
  if (stage === 'reply.validate.identity') return '检查连接身份格式';
  if (stage === 'reply.validate.capability') return '检查连接协议与能力';
  if (stage === 'reply.validate.revision') return '检查连接版本';
  if (stage === 'reply.validate.expiry') return '检查连接有效期';
  if (stage === 'reply.validate.binding') return '核对已保存的连接身份';
  if (stage === 'reply.validate.transition') return '检查连接状态变化';
  if (stage === 'reply.validate.peer') return '检查对方连接信息';
  if (stage === 'reply.validate.invite') return '检查邀请短码格式';
  if (stage === 'reply.validate.proof') return '检查邀请确认凭据格式';
  if (stage === 'state.check') return '检查本机连接状态';
  return '准备共同计划连接';
}
export function planConnectionDetail(diagnostic: PlanConnectionDiagnostic, code: string): string {
  const safe = planConnectionDiagnostic(diagnostic.stage, diagnostic.sdkCode);
  return '失败阶段：' + planConnectionStageLabel(safe.stage) + '（' + safe.stage + '）'
    + '\n错误码：' + (CODES.includes(code) ? code : 'RESULT_UNKNOWN')
    + (safe.sdkCode === '' ? '' : ' · SDK ' + safe.sdkCode);
}
export function planConnectionReport(diagnostic: PlanConnectionDiagnostic, code: string): string {
  const safe = planConnectionDiagnostic(diagnostic.stage, diagnostic.sdkCode);
  const fields: Record<string, string> = { 'tag': 'FORTWO_PLAN_LINK_DIAG', 'build': '2026-10-08-diag3',
    'stage': safe.stage, 'code': CODES.includes(code) ? code : 'RESULT_UNKNOWN', 'sdkCode': safe.sdkCode };
  return JSON.stringify(fields);
}
