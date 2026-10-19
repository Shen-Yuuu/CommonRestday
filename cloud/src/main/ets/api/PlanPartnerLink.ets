import { PairKeyStore } from './PairKeyStore';
import { EncryptedPayload } from './SnapshotCrypto';

const AAD = 'FORTWO_PLAN_PARTNER_LINK_V1';
interface LinkContent { version: number; legacyPairId: string; publicKey: string; flowId: string; }

/** Possession proof for the existing schedule-pair key. It does not replace SDK authentication. */
export class PlanPartnerLink {
  static async create(pairId: string, publicKey: string, flowId: string): Promise<string> {
    if (pairId === '' || !await PairKeyStore.hasPairKey(pairId)) throw new Error('Schedule pairing required');
    const content: LinkContent = { version: 1, legacyPairId: pairId, publicKey: publicKey, flowId: flowId };
    return JSON.stringify(await PairKeyStore.seal(pairId, AAD, JSON.stringify(content)));
  }
  static async verify(pairId: string, publicKey: string, raw: string): Promise<boolean> {
    try {
      if (pairId === '' || typeof raw !== 'string' || raw.length === 0 || raw.length > 4096) return false;
      const text = await PairKeyStore.open(pairId, AAD, JSON.parse(raw) as EncryptedPayload);
      if (text === null || text.length > 2048) return false;
      const content = JSON.parse(text) as LinkContent;
      return content !== null && content.version === 1 && content.legacyPairId === pairId
        && content.publicKey === publicKey && typeof content.flowId === 'string'
        && /^[A-Za-z0-9_-]{1,128}$/.test(content.flowId);
    } catch { return false; }
  }
}
