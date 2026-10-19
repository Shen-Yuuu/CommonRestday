// Generated declarations; same fields as CloudDB object definitions.
export class PairPlanSyncState {
  getClassName(): string;
  getFieldTypeMap(): Map<string, string>;
  getPrimaryKeyList(): string[];
  getIndexList(): string[];
  getEncryptedFieldList(): string[];
  getId(): string;
  setId(value: string): void;
  getPairId(): string;
  setPairId(value: string): void;
  getSequence(): number;
  setSequence(value: number): void;
  getPlanCount(): number;
  setPlanCount(value: number): void;
  getRequestCount(): number;
  setRequestCount(value: number): void;
  getEventCount(): number;
  setEventCount(value: number): void;
  getCreatorAck(): number;
  setCreatorAck(value: number): void;
  getRecipientAck(): number;
  setRecipientAck(value: number): void;
}
export class PairPlanChange {
  getClassName(): string;
  getFieldTypeMap(): Map<string, string>;
  getPrimaryKeyList(): string[];
  getIndexList(): string[];
  getEncryptedFieldList(): string[];
  getId(): string;
  setId(value: string): void;
  getPairId(): string;
  setPairId(value: string): void;
  getSequence(): number;
  setSequence(value: number): void;
  getPlanId(): string;
  setPlanId(value: string): void;
  getStateVersion(): number;
  setStateVersion(value: number): void;
  getRecordJson(): string;
  setRecordJson(value: string): void;
  getCreatedAt(): number;
  setCreatedAt(value: number): void;
}
export class PairPlanArchive {
  getClassName(): string;
  getFieldTypeMap(): Map<string, string>;
  getPrimaryKeyList(): string[];
  getIndexList(): string[];
  getEncryptedFieldList(): string[];
  getId(): string;
  setId(value: string): void;
  getPairId(): string;
  setPairId(value: string): void;
  getPlanId(): string;
  setPlanId(value: string): void;
  getStateVersion(): number;
  setStateVersion(value: number): void;
  getRecordJson(): string;
  setRecordJson(value: string): void;
  getArchivedAt(): number;
  setArchivedAt(value: number): void;
}
export class PairPlanArchiveVote {
  getClassName(): string;
  getFieldTypeMap(): Map<string, string>;
  getPrimaryKeyList(): string[];
  getIndexList(): string[];
  getEncryptedFieldList(): string[];
  getId(): string;
  setId(value: string): void;
  getPairId(): string;
  setPairId(value: string): void;
  getPlanId(): string;
  setPlanId(value: string): void;
  getStateVersion(): number;
  setStateVersion(value: number): void;
  getActorUid(): string;
  setActorUid(value: string): void;
  getCreatedAt(): number;
  setCreatedAt(value: number): void;
}
export class PairPlanReceiptArchive {
  getClassName(): string;
  getFieldTypeMap(): Map<string, string>;
  getPrimaryKeyList(): string[];
  getIndexList(): string[];
  getEncryptedFieldList(): string[];
  getId(): string;
  setId(value: string): void;
  getPairId(): string;
  setPairId(value: string): void;
  getActorUid(): string;
  setActorUid(value: string): void;
  getDigest(): string;
  setDigest(value: string): void;
  getResponseCompressed(): string;
  setResponseCompressed(value: string): void;
  getCreatedAt(): number;
  setCreatedAt(value: number): void;
  getArchivedAt(): number;
  setArchivedAt(value: number): void;
}
export class PairPlanEventArchive {
  getClassName(): string;
  getFieldTypeMap(): Map<string, string>;
  getPrimaryKeyList(): string[];
  getIndexList(): string[];
  getEncryptedFieldList(): string[];
  getId(): string;
  setId(value: string): void;
  getPairId(): string;
  setPairId(value: string): void;
  getRecordJson(): string;
  setRecordJson(value: string): void;
  getArchivedAt(): number;
  setArchivedAt(value: number): void;
}
export class PairPlanWake {
  getClassName(): string;
  getFieldTypeMap(): Map<string, string>;
  getPrimaryKeyList(): string[];
  getIndexList(): string[];
  getEncryptedFieldList(): string[];
  getId(): string;
  setId(value: string): void;
  getPairId(): string;
  setPairId(value: string): void;
  getEventId(): string;
  setEventId(value: string): void;
  getCreatedAt(): number;
  setCreatedAt(value: number): void;
  getProof(): string;
  setProof(value: string): void;
}
