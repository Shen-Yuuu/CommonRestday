import { PairKeyStore } from './PairKeyStore';
import { SecurePlanKeyStore } from './SecurePlanKeyStore';
import { EncryptedPayload, SnapshotCrypto } from './SnapshotCrypto';

export interface PairingBridgeOffer {
  pairId: string; publicKey: string; inviteCode: string; expiresAt: number;
}
interface BridgeContent extends PairingBridgeOffer {
  version: number; legacyPairId: string; sender: string; recipient: string;
}
function aad(pair: string): string { return 'FORTWO_UNIFIED_PAIRING_V1|' + pair; }
function valid(value: PairingBridgeOffer): boolean {
  return value !== null && /^sp-[a-f0-9]{32}$/.test(value.pairId)
    && /^B[A-Za-z0-9+/]{86}=$/.test(value.publicKey) && /^\d{6}$/.test(value.inviteCode)
    && Number.isSafeInteger(value.expiresAt) && value.expiresAt > Date.now()
    && value.expiresAt <= Date.now() + 86400000;
}
/** Locator is not authorization. Actual partner possession is proved by random-nonce GCM. */
export class PlanPairingBridge {
  static route(legacyPairId: string): Promise<string> { return SecurePlanKeyStore.pairingRoute(legacyPairId); }
  static async seal(pair: string, sender: string, recipient: string, offer: PairingBridgeOffer): Promise<string> {
    if (!valid(offer) || sender === '' || recipient === '' || sender === recipient) throw new Error('PAIR_OFFER_INVALID');
    const content: BridgeContent = { version: 1, legacyPairId: pair, sender: sender, recipient: recipient,
      pairId: offer.pairId, publicKey: offer.publicKey, inviteCode: offer.inviteCode, expiresAt: offer.expiresAt };
    return JSON.stringify(await PairKeyStore.seal(pair, aad(pair), JSON.stringify(content)));
  }
  static async open(pair: string, sender: string, recipient: string, raw: string): Promise<PairingBridgeOffer | null> {
    try {
      if (typeof raw !== 'string' || raw.length === 0 || raw.length > 4096) return null;
      const plain = await PairKeyStore.open(pair, aad(pair), JSON.parse(raw) as EncryptedPayload);
      if (plain === null || plain.length > 2048) return null;
      const value = JSON.parse(plain) as BridgeContent;
      if (!valid(value) || value.version !== 1 || value.legacyPairId !== pair
        || value.sender !== sender || value.recipient !== recipient || sender === recipient) return null;
      return { pairId: value.pairId, publicKey: value.publicKey, inviteCode: value.inviteCode, expiresAt: value.expiresAt };
    } catch { return null; }
  }
}
