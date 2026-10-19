import { cloudFunction } from '@kit.CloudFoundationKit';
import { CLOUD_TIMEOUT_MS } from './CloudApi';
import { PlanConnectionFailure, Logger } from 'commons';

/** Independent object: no legacy UID argument and no destructive automatic retry. */
export class DatePlanCloudApi {
  static calls: number = 0;
  static async invoke(method: string, token: string, params: Object[]): Promise<string> {
    if (['createPair', 'joinPair', 'confirmPair', 'pairStatus', 'capabilities', 'read', 'mutate',
      'unpair', 'registerPush', 'requestStatus', 'closeRequest', 'cleanupCreate', 'readChanges', 'acknowledge', 'publishLink', 'discoverLink'].indexOf(method) < 0 || token.length === 0 || token.length > 16384) {
      throw new PlanConnectionFailure('cloud.input', null, 'BAD_REQUEST');
    }
    DatePlanCloudApi.calls++;
    const started = Date.now();
    let returned = false;
    let stage = 'cloud.call';
    try {
      const args: Object[] = [token];
      for (const item of params) args.push(item);
      const result = await cloudFunction.call({ name: 'dateplan', version: '$latest',
        data: { 'method': method, 'params': args }, timeout: CLOUD_TIMEOUT_MS });
      stage = 'cloud.decode';
      const text = typeof result.result === 'string' ? result.result : JSON.stringify(result.result);
      if (text.length > 1048576) throw new Error('BAD_RECORD');
      returned = true;
      return text;
    } catch (error) { throw new PlanConnectionFailure(stage, error as Object, 'CLOUD_RESULT_UNKNOWN'); }
    finally {
      // Fixed method + duration only. No arguments, identities, response text, or SDK errors.
      try { Logger.info('DatePlanCloudApi', JSON.stringify({ tag: 'FORTWO_PLAN_RPC_TIMING',
        method: method, elapsedMs: Math.max(0, Date.now() - started), returned: returned })); } catch { /* Diagnostic only. */ }
    }
  }
}
