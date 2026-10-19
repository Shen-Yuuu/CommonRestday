import { cloud, Region } from '@hw-agconnect/cloud-server';
import { createHash, randomUUID } from 'crypto';

export class Rejection extends Error {
  constructor(readonly code: string) {
    super(code);
    // CloudDev's generated tsconfig defaults to ES5: built-in Error loses the subclass prototype.
    Object.setPrototypeOf(this, Rejection.prototype);
  }
}

export function digest(parts: Object[]): string {
  return createHash('sha256').update(JSON.stringify(parts)).digest('hex');
}

export function client() {
  return cloud.createInstance(undefined, 'fortwo-dateplan-v1', Region.REGION_CN);
}

/** Gateway signature is not user identity. Never use a request body's UID here. */
export async function actor(accessToken: string, diagnostic: DiagnosticContext = { stage: 'auth' }): Promise<string> {
  diagnostic.stage = 'auth.featureGate';
  if (process.env.FORTWO_ENABLE_SHARED_PLAN_V1 !== 'true') throw new Rejection('FEATURE_DISABLED');
  diagnostic.stage = 'auth.projectConfig';
  const project = process.env.FORTWO_AUTH_PROJECT_ID?.trim();
  if (!project) throw new Rejection('CONFIG_MISSING');
  diagnostic.stage = 'auth.tokenInput';
  if (typeof accessToken !== 'string' || !accessToken.trim() || accessToken.length > 16384) {
    throw new Rejection('AUTH_REJECTED');
  }
  try {
    diagnostic.stage = 'auth.sdkVerify';
    const claims = await client().auth().verifyAccessToken({ accessToken, checkRevoked: true });
    const sub = claims.getSub(); const exp = claims.getExp();
    diagnostic.stage = 'auth.audience';
    if (claims.getAud() !== project) throw new Rejection('AUTH_REJECTED');
    diagnostic.stage = 'auth.subject';
    if (typeof sub !== 'string' || !sub.trim()) throw new Rejection('AUTH_REJECTED');
    diagnostic.stage = 'auth.expiry';
    if (typeof exp !== 'number' || !Number.isFinite(exp) || exp <= Date.now() / 1000) throw new Rejection('AUTH_REJECTED');
    diagnostic.stage = 'auth.accepted';
    return 'm-' + digest([project, sub]);
  } catch { throw new Rejection('AUTH_REJECTED'); }
}

export function zoneName(): string {
  const zone = process.env.FORTWO_SHARED_PLAN_ZONE;
  // No default production zone and no client-controlled routing.
  if (!zone || !/^[A-Za-z][A-Za-z0-9]{0,49}$/.test(zone)) throw new Rejection('CONFIG_MISSING');
  return zone;
}

export interface DiagnosticContext { stage: string; }

/** Never log raw errors: SDK messages/stacks can contain credentials or payloads. */
export function diagnose(error: unknown, operation: string, stage: string, code: string): string {
  const diagnosticId = randomUUID();
  const value = error instanceof Error ? error : undefined;
  const numeric = error && typeof error === 'object' ? error as { code?: unknown; errno?: unknown } : undefined;
  const frames = (value?.stack ?? '').split('\n').slice(1)
    .map(line => line.match(/\b(identity|service|protocol|dateplan)\.(?:js|ts):(\d+):(\d+)\)?\s*$/))
    .filter((match): match is RegExpMatchArray => match !== null)
    .slice(0, 6).map(match => `${match[1]}:${match[2]}:${match[3]}`);
  const message = value?.message ?? '';
  const category = error instanceof Rejection ? 'BUSINESS_REJECTION'
    : value instanceof TypeError ? 'TYPE_ERROR'
    : /transaction|commit|rollback/i.test(message) ? 'TRANSACTION_ERROR'
    : /database|clouddb|collection|query|schema/i.test(message) ? 'DATABASE_ERROR'
    : /timeout|network|socket|connect/i.test(message) ? 'NETWORK_ERROR' : 'UNCLASSIFIED_ERROR';
  const safe = JSON.stringify({ tag: 'FORTWO_DATEPLAN_DIAG', build: '2026-10-17-counter1', diagnosticId,
    operation: /^[a-zA-Z]{1,24}$/.test(operation) ? operation : 'unknown',
    stage: /^[a-zA-Z0-9_.]{1,64}$/.test(stage) ? stage : 'unknown', code, category, frames,
    sdkCode: typeof numeric?.code === 'number' && Number.isSafeInteger(numeric.code) ? numeric.code : null,
    errno: typeof numeric?.errno === 'number' && Number.isSafeInteger(numeric.errno) ? numeric.errno : null });
  try {
    const runtime = globalThis as typeof globalThis & { logger?: { error(message: string): void } };
    if (runtime.logger?.error) runtime.logger.error(safe);
    else console.error(safe);
  } catch { /* Logging must never alter the business result or trigger another mutation. */ }
  return diagnosticId;
}

export async function guarded(work: (context: DiagnosticContext) => Promise<Record<string, Object>>,
  operation = 'unknown'): Promise<Record<string, Object>> {
  const context: DiagnosticContext = { stage: 'handler' };
  try { return await work(context); }
  catch (error) {
    const code = error instanceof Rejection ? error.code : 'RESULT_UNKNOWN';
    const diagnosticId = diagnose(error, operation, context.stage, code);
    return { code, retryable: code === 'RESULT_UNKNOWN' || code === 'VERSION_CONFLICT',
      diagnosticId, message: (code === 'RESULT_UNKNOWN' ? '结果尚未确认，请按原请求重试或刷新' : code)
        + '；诊断编号：' + diagnosticId };
  }
}
