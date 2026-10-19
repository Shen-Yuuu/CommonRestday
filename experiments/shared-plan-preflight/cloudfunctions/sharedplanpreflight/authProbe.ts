import { createHash } from 'crypto';

/** Structural port checked against the installed Server SDK by the isolated test runner. */
export interface VerifiedAccessToken {
  getAud(): string | undefined;
  getSub(): string | undefined;
  getExp(): number | undefined;
}

export type TokenVerifier = (accessToken: string) => Promise<VerifiedAccessToken>;

export interface IdentityProbeResult {
  code: 'OK' | 'CONFIG_MISSING' | 'BAD_REQUEST' | 'AUTH_REJECTED';
  authenticated: boolean;
  subjectFingerprint: string;
  sharedPlanReady: false;
  message: string;
}

function rejected(code: 'CONFIG_MISSING' | 'BAD_REQUEST' | 'AUTH_REJECTED'): IdentityProbeResult {
  const message = code === 'CONFIG_MISSING' ? '隔离探针尚未配置可信项目'
    : code === 'BAD_REQUEST' ? '请提供认证服务签发的访问令牌'
      : '认证未通过';
  return { code, authenticated: false, subjectFingerprint: '', sharedPlanReady: false, message };
}

/** This does not bind a pairing member, touch CloudDB, or enable shared-plan writes. */
export async function inspectVerifiedToken(
  accessToken: string,
  expectedProjectId: string,
  verify: TokenVerifier
): Promise<IdentityProbeResult> {
  if (typeof expectedProjectId !== 'string' || expectedProjectId.trim().length === 0) {
    return rejected('CONFIG_MISSING');
  }
  if (typeof accessToken !== 'string' || accessToken.trim().length === 0 || accessToken.length > 16384) {
    return rejected('BAD_REQUEST');
  }
  try {
    // Never replace this verifier with merely decoding the JWT payload.
    const verified = await verify(accessToken);
    const projectId = verified.getAud();
    const subject = verified.getSub();
    const expiresAt = verified.getExp();
    if (projectId !== expectedProjectId.trim() || typeof subject !== 'string' || subject.trim().length === 0
      || typeof expiresAt !== 'number' || !Number.isFinite(expiresAt) || expiresAt <= Date.now() / 1000) {
      return rejected('AUTH_REJECTED');
    }
    // Comparable only within this isolated probe. No raw UID, token, claims or SDK error is returned.
    const subjectFingerprint = createHash('sha256').update(JSON.stringify([projectId, subject])).digest('hex').slice(0, 16);
    return {
      code: 'OK', authenticated: true, subjectFingerprint, sharedPlanReady: false,
      message: '身份探针通过；配对绑定、事务和推送仍需分别验证'
    };
  } catch {
    return rejected('AUTH_REJECTED');
  }
}
