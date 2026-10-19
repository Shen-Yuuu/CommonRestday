import { dispatch, serviceJwt } from './push';
import { randomUUID, timingSafeEqual } from 'crypto';
import { installPushAccountEnvironment, readPushAccount } from './push-account';

interface WorkerContext { env?: Record<string, string>; }
interface WorkerLogger { info(message: string): void; }
type InputShape = 'direct' | 'string' | 'data' | 'userData' | 'user_event' | 'invalid' | 'unsupported';
interface TaskInput { secret: string; shape: InputShape; }

function taskInput(event: unknown): TaskInput {
  const object = (value: unknown): Record<string, unknown> => {
    if (typeof value === 'string') {
      if (Buffer.byteLength(value, 'utf8') > 4096) throw new Error();
      value = JSON.parse(value);
    }
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error();
    return value as Record<string, unknown>;
  };
  try {
    let value = object(event); let shape: InputShape = typeof event === 'string' ? 'string' : 'direct';
    const wrappers = ['data', 'userData', 'user_event'] as const;
    const present = wrappers.filter(name => Object.prototype.hasOwnProperty.call(value, name));
    if (present.length > 1 || (present.length && Object.prototype.hasOwnProperty.call(value, 'dispatchSecret'))) {
      throw new Error();
    }
    if (present.length === 1) {
      shape = present[0]; value = object(value[present[0]]);
      if (wrappers.some(name => Object.prototype.hasOwnProperty.call(value, name))) throw new Error();
    }
    return typeof value.dispatchSecret === 'string' ? { secret: value.dispatchSecret, shape }
      : { secret: '', shape: 'unsupported' };
  } catch { return { secret: '', shape: 'invalid' }; }
}

/** AGC traditional Node.js functions require callback(object), not a returned Promise. TIMER only. */
export function handler(event: unknown, context: WorkerContext, callback: (result: Object) => void,
  logger?: WorkerLogger): void {
  const runtime = globalThis as typeof globalThis & { logger?: WorkerLogger };
  const sink = typeof logger?.info === 'function' ? logger : runtime.logger;
  const started = Date.now(); const invocationId = randomUUID(); const input = taskInput(event);
  const log = (stage: string, code: string, providerAccepted = 0): void => {
    // Only fixed fields: never event bodies/keys, environment values, tokens or raw errors.
    const safe = JSON.stringify({ tag: 'FORTWO_PLAN_PUSH', build: '2026-10-10-worker-diag1', invocationId,
      stage, code, inputShape: input.shape, providerAccepted, elapsedMs: Math.max(0, Date.now() - started),
      sharedPlanEnabled: process.env.FORTWO_ENABLE_SHARED_PLAN_V1 === 'true',
      pushEnabled: process.env.FORTWO_ENABLE_PLAN_PUSH === 'true' });
    try {
      if (typeof sink?.info === 'function') sink.info(safe);
      else console.info(safe); // Local tests / runtimes without AGC's logger.
    } catch { /* A broken logger must not alter task authentication or business results. */ }
  };
  if (context?.env) installPushAccountEnvironment(context.env);
  for (const name of ['FORTWO_AUTH_PROJECT_ID', 'FORTWO_SHARED_PLAN_ZONE', 'FORTWO_ENABLE_SHARED_PLAN_V1',
    'FORTWO_ENABLE_PLAN_PUSH', 'FORTWO_PLAN_DISPATCH_SECRET',
    'PROJECT_CREDENTIAL', 'AGC_CONFIG']) {
    const value = context?.env?.[name];
    if (typeof value === 'string') process.env[name] = value;
  }
  log('start', 'START');
  // Event compatibility never bypasses the secret guard. Deploy TIMER only, not app/HTTP triggers.
  const supplied = input.secret;
  const expected = process.env.FORTWO_PLAN_DISPATCH_SECRET ?? '';
  if (!/^[A-Za-z0-9_-]{32,128}$/.test(expected) || !/^[A-Za-z0-9_-]{32,128}$/.test(supplied)
    || supplied.length !== expected.length
    || !timingSafeEqual(Buffer.from(supplied), Buffer.from(expected))) {
    log('auth', 'DISPATCH_REJECTED');
    callback({ code: 'DISPATCH_REJECTED', providerAccepted: 0 }); return;
  }
  log('auth', 'AUTHORIZED');
  if (process.env.FORTWO_ENABLE_SHARED_PLAN_V1 === 'true' && process.env.FORTWO_ENABLE_PLAN_PUSH === 'true') {
    try {
      const account = readPushAccount();
      if (account.project_id !== process.env.FORTWO_AUTH_PROJECT_ID) throw new Error('PUSH_PROJECT_MISMATCH');
      serviceJwt(account); // Local key validation, no request and no token logging.
      log('config', 'VALIDATED');
    } catch (error) {
      const code = error instanceof Error && error.message === 'PUSH_PROJECT_MISMATCH' ? 'PUSH_PROJECT_MISMATCH' : 'PUSH_CONFIG_INVALID';
      log('config', code);
      callback({ code, providerAccepted: 0 }); return;
    }
  }
  log('dispatch', 'START');
  Promise.resolve().then(() => dispatch()).then(sent => {
    log('finish', 'OK', sent);
    callback({ code: 'OK', providerAccepted: sent });
  }, () => {
    log('finish', 'PUSH_DEFERRED');
    callback({ code: 'PUSH_DEFERRED', providerAccepted: 0 });
  });
}
