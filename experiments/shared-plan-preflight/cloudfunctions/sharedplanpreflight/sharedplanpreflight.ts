import { cloud, Region } from '@hw-agconnect/cloud-server';
import { IdentityProbeResult, inspectVerifiedToken } from './authProbe';
import { CasProbeResult, probeTransactionRace } from './casProbe';
import { PlanCasProbe } from './PlanCasProbe';

async function verify(accessToken: string): Promise<IdentityProbeResult> {
  return inspectVerifiedToken(accessToken, process.env.FORTWO_AUTH_PROJECT_ID || '', async token => {
    const auth = cloud.createInstance(undefined, 'fortwo-plan-preflight', Region.REGION_CN).auth();
    return auth.verifyAccessToken({ accessToken: token, checkRevoked: true });
  });
}

export class SharedPlanPreflight {
  /** Public cloud-object methods must also work when extracted and invoked without this. */
  async verifyIdentity(accessToken: string): Promise<IdentityProbeResult> {
    return verify(accessToken);
  }

  async runRace(accessToken: string): Promise<CasProbeResult> {
    const identity = await verify(accessToken);
    if (!identity.authenticated || process.env.FORTWO_ENABLE_CAS_PROBE !== 'true') {
      return { code: identity.authenticated ? 'PROBE_DISABLED' : identity.code, probeId: '', legs: [],
        finalVersion: 0, finalState: '', overlapObserved: false, sharedPlanReady: false,
        message: identity.authenticated ? '隔离事务探针尚未启用' : identity.message };
    }
    try {
      const collection = cloud.createInstance(undefined, 'fortwo-plan-preflight', Region.REGION_CN)
        .database({ zoneName: 'FortwoPlanProbe' }).collection(PlanCasProbe);
      return await probeTransactionRace(collection);
    } catch {
      return { code: 'DB_UNAVAILABLE', probeId: '', legs: [], finalVersion: 0, finalState: '',
        overlapObserved: false, sharedPlanReady: false, message: '隔离云数据库尚未就绪' };
    }
  }
}
