import auth from '@hw-agconnect/auth';
import { common } from '@kit.AbilityKit';
import { PlanConnectionFailure } from 'commons';
import { SnapshotCrypto } from './SnapshotCrypto';

export interface AnonymousCredential { uid: string; accessToken: string; }

/** Lazy SDK initialization; attaching a context never logs in or sends a request. */
export class AnonymousIdentity {
  private static context: common.Context | null = null;
  private static ready: boolean = false;
  private static pending: Promise<AnonymousCredential> | null = null;
  static attach(context: common.Context): void { AnonymousIdentity.context = context; }

  /** Local session fence only, never initialization/login/token refresh or cloud authorization. */
  static async currentUid(): Promise<string> {
    if (!AnonymousIdentity.ready) return '';
    try {
      const user = await auth.getCurrentUser();
      if (user === null || !user.isAnonymous()) return '';
      const uid = user.getUid();
      return typeof uid === 'string' && uid.length > 0 && uid.length <= 256 ? uid : '';
    } catch { return ''; }
  }

  static credential(allowCreate: boolean = false): Promise<AnonymousCredential> {
    // Serialize anonymous creation; passive reads may not borrow an in-flight create.
    if (!allowCreate) return AnonymousIdentity.obtain(false);
    if (AnonymousIdentity.pending !== null) return AnonymousIdentity.pending;
    const work = AnonymousIdentity.obtain(true).finally(() => { AnonymousIdentity.pending = null; });
    AnonymousIdentity.pending = work;
    return work;
  }

  private static async obtain(allowCreate: boolean): Promise<AnonymousCredential> {
    let stage = 'auth.context';
    try {
      if (!AnonymousIdentity.ready) {
        const context = AnonymousIdentity.context;
        if (context === null) throw new Error('AUTH_NOT_READY');
        stage = 'auth.resource';
        const bytes = context.resourceManager.getRawFileContentSync('agconnect-services.json');
        stage = 'auth.init';
        auth.init(context, SnapshotCrypto.decodeText(bytes));
        AnonymousIdentity.ready = true;
      }
      stage = 'auth.user';
      let user = await auth.getCurrentUser();
      if (user === null && allowCreate) {
        stage = 'auth.signIn';
        user = (await auth.signInAnonymously()).getUser();
      }
      stage = 'auth.identity';
      if (user === null || !user.isAnonymous()) throw new Error('AUTH_REQUIRED');
      const uid = user.getUid();
      if (typeof uid !== 'string' || uid.length === 0 || uid.length > 256) throw new Error('AUTH_REQUIRED');
      stage = 'auth.token';
      const token = (await user.getToken(true)).getString();
      stage = 'auth.recheck';
      const after = await auth.getCurrentUser();
      if (after === null || !after.isAnonymous() || after.getUid() !== uid
        || typeof token !== 'string' || token.length === 0 || token.length > 16384) throw new Error('AUTH_CHANGED');
      return { uid: uid, accessToken: token };
    } catch (error) {
      throw new PlanConnectionFailure(stage, error as Object, 'AUTH_UNAVAILABLE');
    }
  }
}
