import { client, Rejection, zoneName } from './identity';
import { PairMemberBinding } from './models';
import { validId } from './protocol';

function validRoute(route: string): boolean { return typeof route === 'string' && /^[a-f0-9]{64}$/.test(route); }
function validOffer(raw: string): boolean {
  if (typeof raw !== 'string' || raw.length === 0 || raw.length > 4096) return false;
  try {
    const value = JSON.parse(raw);
    const b64 = (s: string, size = 0) => typeof s === 'string' && /^[A-Za-z0-9+/]+={0,2}$/.test(s)
      && Buffer.from(s, 'base64').toString('base64') === s && (size ? Buffer.from(s, 'base64').length === size : s.length <= 3072);
    return value !== null && Object.keys(value).sort().join(',') === 'algorithm,authTag,ciphertext,iv'
      && value.algorithm === 'AES-256-GCM' && b64(value.iv, 12) && b64(value.authTag, 16) && b64(value.ciphertext);
  } catch { return false; }
}

/** Route is a locator, never identity/membership proof. Only encrypted offers are discoverable. */
export async function publishLink(who: string, pairId: string, route: string, offer: string) {
  if (!validId(pairId) || !validRoute(route) || !validOffer(offer)) throw new Rejection('BAD_REQUEST');
  const db = client().database({ zoneName: zoneName() }).collection(PairMemberBinding);
  const committed = await db.runTransaction({ async apply(tx) {
    const rows = await tx.executeQuery(db.query().equalTo('id', pairId));
    if (rows.length !== 1) throw new Rejection('NOT_FOUND');
    const row = Object.assign(new PairMemberBinding(), rows[0]);
    if (row.getCreatorSubject() !== who) throw new Rejection('FORBIDDEN');
    if (row.getStatus() === 'REVOKED') throw new Rejection('SESSION_REVOKED');
    if (!['WAITING', 'PENDING_CONFIRM'].includes(row.getStatus())) throw new Rejection('STATE_CONFLICT');
    if (row.getExpiresAt() <= Date.now()) throw new Rejection('CODE_EXPIRED');
    if (!row.getCreatorLink()) throw new Rejection('PARTNER_LINK_REQUIRED');
    if ((row.getBootstrapRoute() && row.getBootstrapRoute() !== route)
      || (row.getBootstrapOffer() && row.getBootstrapOffer() !== offer)) throw new Rejection('REQUEST_REUSED');
    if (row.getBootstrapOffer() === offer) return true;
    if (row.getRevision() >= 2147483646) throw new Rejection('VERSION_LIMIT');
    row.setBootstrapRoute(route); row.setBootstrapOffer(offer);
    row.setRevision(row.getRevision() + 1); row.setUpdatedAt(Date.now());
    tx.executeUpsert([row]); return true;
  } });
  if (!committed) throw new Rejection('VERSION_CONFLICT');
  return { code: 'OK' };
}

export async function discoverLink(_who: string, route: string) {
  if (!validRoute(route)) throw new Rejection('BAD_REQUEST');
  const db = client().database({ zoneName: zoneName() }).collection(PairMemberBinding);
  const rows = await db.query().equalTo('bootstrapRoute', route).limit(6).get();
  if (rows.length > 5) throw new Rejection('CODE_COLLISION');
  const offers: { pairId: string; publicKey: string; offer: string }[] = [];
  for (const found of rows) {
    // Re-read so a just-confirmed/revoked snapshot cannot expose a stale invitation.
    const current = await db.query().equalTo('id', found.getId()).get();
    if (current.length !== 1) continue;
    const row = current[0];
    if (row.getBootstrapRoute() === route && ['WAITING', 'PENDING_CONFIRM'].includes(row.getStatus())
      && row.getExpiresAt() > Date.now() && validOffer(row.getBootstrapOffer())) {
      offers.push({ pairId: row.getId(), publicKey: row.getCreatorKey(), offer: row.getBootstrapOffer() });
    }
  }
  return { code: 'OK', offers };
}
