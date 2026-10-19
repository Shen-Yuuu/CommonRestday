/** Safe on-screen diagnostics: no IDs, titles, dates, tokens, error messages or response bodies. */
export interface SharedPlanDiagnostic {
  stage: string;
  code: string;
  sdkCode: string;
  diagnosticId: string;
}
interface DiagnosticSdkCode { sdkCode: string; }
interface DiagnosticError { code?: number | string; diagnostic?: DiagnosticSdkCode; }
const STAGES: string[] = ['context.session', 'context.key', 'context.identity', 'context.capabilities',
  'context.binding', 'context.proof', 'send.identity', 'send.wire.read', 'send.encrypt', 'send.wire.save',
  'send.wire.validate', 'send.rpc', 'send.decode', 'resolve.identity', 'resolve.wire', 'resolve.rpc', 'resolve.decode'];
const CODES: string[] = ['OK', 'RESULT_UNKNOWN', 'BAD_RECORD', 'BAD_REQUEST', 'BAD_CONTENT', 'BAD_ENVELOPE',
  'SECURE_SESSION_REQUIRED', 'SESSION_CHANGED', 'SESSION_REVOKED', 'PAIR_NOT_ACTIVE', 'PAIR_NOT_READY',
  'FEATURE_DISABLED', 'CAPABILITY_UNAVAILABLE', 'FORBIDDEN', 'AUTH_REJECTED', 'CONFIG_MISSING',
  'VERSION_CONFLICT', 'STATE_CONFLICT', 'NOT_FOUND', 'REQUEST_NOT_COMMITTED', 'REQUEST_REUSED',
  'EXPIRED', 'INVITE_EXPIRED', 'BACKLOG_FULL', 'CLEANUP_REQUIRED', 'CLEANUP_PENDING', 'VERSION_LIMIT',
  'BAD_COUNTER', 'STORAGE_NOT_READY', 'REQUEST_CLOSED'];
export function sharedPlanDiagnostic(stage: string, code: string, error: Object | null = null,
  diagnosticId: string = ''): SharedPlanDiagnostic {
  let sdk = '';
  try {
    if (error !== null) {
      const value = error as DiagnosticError;
      const candidate = value.diagnostic?.sdkCode ?? value.code;
      if ((typeof candidate === 'string' || typeof candidate === 'number') && /^-?\d{1,12}$/.test(String(candidate))) {
        sdk = String(candidate);
      }
    }
  } catch { /* Invalid SDK accessors must not replace the original failure. */ }
  return { stage: STAGES.includes(stage) ? stage : 'send.rpc', code: CODES.includes(code) ? code : 'RESULT_UNKNOWN',
    sdkCode: sdk, diagnosticId: /^[a-f0-9]{8}-[a-f0-9-]{27}$/i.test(diagnosticId) ? diagnosticId : '' };
}
export function sharedPlanDiagnosticText(value: SharedPlanDiagnostic | null): string {
  if (value === null || value.code === 'OK' || value.code === 'REQUEST_NOT_COMMITTED' || value.code === 'REQUEST_CLOSED') return '';
  const sdkError: DiagnosticError = { code: value.sdkCode };
  const safe = sharedPlanDiagnostic(value.stage, value.code, sdkError, value.diagnosticId);
  const label = safe.stage.includes('encrypt') ? '加密计划'
    : safe.stage.includes('wire.save') ? '保存发送凭据'
    : safe.stage.includes('wire') ? '读取发送凭据'
    : safe.stage.includes('decode') ? '检查云端结果'
    : safe.stage.includes('rpc') ? '调用计划云服务'
    : safe.stage.includes('proof') ? '验证伴侣凭证'
    : safe.stage.includes('key') ? '检查计划密钥' : '检查计划连接';
  return '失败阶段：' + label + '（' + safe.stage + '）\n错误码：' + safe.code
    + (safe.sdkCode === '' ? '' : ' · SDK ' + safe.sdkCode)
    + (safe.diagnosticId === '' ? '' : '\n云端诊断编号：' + safe.diagnosticId)
    + '\n诊断版本：2026-10-17-plan1';
}
