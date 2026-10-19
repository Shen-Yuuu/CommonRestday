// Reflection fields must match the deployed schema; Long getters normalize SDK 1.0.5 decimal strings.
// Return NaN for malformed/unsafe values so existing fail-closed counter checks still reject them.
function safeLong(value) {
  const decoded = typeof value === 'number' ? value
    : typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value) ? Number(value) : NaN;
  return Number.isSafeInteger(decoded) && decoded >= 0 ? decoded : NaN;
}
class PairPlanSyncState {
  constructor() { this.id = ''; this.pairId = ''; this.sequence = 0; this.planCount = 0; this.requestCount = 0; this.eventCount = 0; this.creatorAck = 0; this.recipientAck = 0; }
  getClassName() { return 'PairPlanSyncState'; }
  getFieldTypeMap() { return new Map([["id","String"],["pairId","String"],["sequence","Long"],["planCount","Integer"],["requestCount","Integer"],["eventCount","Integer"],["creatorAck","Long"],["recipientAck","Long"]]); }
  getPrimaryKeyList() { return ['id']; }
  getIndexList() { return ["pairId"]; }
  getEncryptedFieldList() { return []; }
  getId() { return this.id; }
  setId(value) { this.id = value; }
  getPairId() { return this.pairId; }
  setPairId(value) { this.pairId = value; }
  getSequence() { return safeLong(this.sequence); }
  setSequence(value) { this.sequence = value; }
  getPlanCount() { return this.planCount; }
  setPlanCount(value) { this.planCount = value; }
  getRequestCount() { return this.requestCount; }
  setRequestCount(value) { this.requestCount = value; }
  getEventCount() { return this.eventCount; }
  setEventCount(value) { this.eventCount = value; }
  getCreatorAck() { return safeLong(this.creatorAck); }
  setCreatorAck(value) { this.creatorAck = value; }
  getRecipientAck() { return safeLong(this.recipientAck); }
  setRecipientAck(value) { this.recipientAck = value; }
}
class PairPlanChange {
  constructor() { this.id = ''; this.pairId = ''; this.sequence = 0; this.planId = ''; this.stateVersion = 0; this.recordJson = ''; this.createdAt = 0; }
  getClassName() { return 'PairPlanChange'; }
  getFieldTypeMap() { return new Map([["id","String"],["pairId","String"],["sequence","Long"],["planId","String"],["stateVersion","Integer"],["recordJson","Text"],["createdAt","Long"]]); }
  getPrimaryKeyList() { return ['id']; }
  getIndexList() { return ["pairId","pairId,sequence"]; }
  getEncryptedFieldList() { return []; }
  getId() { return this.id; }
  setId(value) { this.id = value; }
  getPairId() { return this.pairId; }
  setPairId(value) { this.pairId = value; }
  getSequence() { return safeLong(this.sequence); }
  setSequence(value) { this.sequence = value; }
  getPlanId() { return this.planId; }
  setPlanId(value) { this.planId = value; }
  getStateVersion() { return this.stateVersion; }
  setStateVersion(value) { this.stateVersion = value; }
  getRecordJson() { return this.recordJson; }
  setRecordJson(value) { this.recordJson = value; }
  getCreatedAt() { return safeLong(this.createdAt); }
  setCreatedAt(value) { this.createdAt = value; }
}
class PairPlanArchive {
  constructor() { this.id = ''; this.pairId = ''; this.planId = ''; this.stateVersion = 0; this.recordJson = ''; this.archivedAt = 0; }
  getClassName() { return 'PairPlanArchive'; }
  getFieldTypeMap() { return new Map([["id","String"],["pairId","String"],["planId","String"],["stateVersion","Integer"],["recordJson","Text"],["archivedAt","Long"]]); }
  getPrimaryKeyList() { return ['id']; }
  getIndexList() { return ["pairId"]; }
  getEncryptedFieldList() { return []; }
  getId() { return this.id; }
  setId(value) { this.id = value; }
  getPairId() { return this.pairId; }
  setPairId(value) { this.pairId = value; }
  getPlanId() { return this.planId; }
  setPlanId(value) { this.planId = value; }
  getStateVersion() { return this.stateVersion; }
  setStateVersion(value) { this.stateVersion = value; }
  getRecordJson() { return this.recordJson; }
  setRecordJson(value) { this.recordJson = value; }
  getArchivedAt() { return safeLong(this.archivedAt); }
  setArchivedAt(value) { this.archivedAt = value; }
}
class PairPlanArchiveVote {
  constructor() { this.id = ''; this.pairId = ''; this.planId = ''; this.stateVersion = 0; this.actorUid = ''; this.createdAt = 0; }
  getClassName() { return 'PairPlanArchiveVote'; }
  getFieldTypeMap() { return new Map([["id","String"],["pairId","String"],["planId","String"],["stateVersion","Integer"],["actorUid","String"],["createdAt","Long"]]); }
  getPrimaryKeyList() { return ['id']; }
  getIndexList() { return ["pairId","pairId,planId,stateVersion"]; }
  getEncryptedFieldList() { return []; }
  getId() { return this.id; }
  setId(value) { this.id = value; }
  getPairId() { return this.pairId; }
  setPairId(value) { this.pairId = value; }
  getPlanId() { return this.planId; }
  setPlanId(value) { this.planId = value; }
  getStateVersion() { return this.stateVersion; }
  setStateVersion(value) { this.stateVersion = value; }
  getActorUid() { return this.actorUid; }
  setActorUid(value) { this.actorUid = value; }
  getCreatedAt() { return safeLong(this.createdAt); }
  setCreatedAt(value) { this.createdAt = value; }
}
class PairPlanReceiptArchive {
  constructor() { this.id = ''; this.pairId = ''; this.actorUid = ''; this.digest = ''; this.responseCompressed = ''; this.createdAt = 0; this.archivedAt = 0; }
  getClassName() { return 'PairPlanReceiptArchive'; }
  getFieldTypeMap() { return new Map([["id","String"],["pairId","String"],["actorUid","String"],["digest","String"],["responseCompressed","Text"],["createdAt","Long"],["archivedAt","Long"]]); }
  getPrimaryKeyList() { return ['id']; }
  getIndexList() { return ["pairId"]; }
  getEncryptedFieldList() { return []; }
  getId() { return this.id; }
  setId(value) { this.id = value; }
  getPairId() { return this.pairId; }
  setPairId(value) { this.pairId = value; }
  getActorUid() { return this.actorUid; }
  setActorUid(value) { this.actorUid = value; }
  getDigest() { return this.digest; }
  setDigest(value) { this.digest = value; }
  getResponseCompressed() { return this.responseCompressed; }
  setResponseCompressed(value) { this.responseCompressed = value; }
  getCreatedAt() { return safeLong(this.createdAt); }
  setCreatedAt(value) { this.createdAt = value; }
  getArchivedAt() { return safeLong(this.archivedAt); }
  setArchivedAt(value) { this.archivedAt = value; }
}
class PairPlanEventArchive {
  constructor() { this.id = ''; this.pairId = ''; this.recordJson = ''; this.archivedAt = 0; }
  getClassName() { return 'PairPlanEventArchive'; }
  getFieldTypeMap() { return new Map([["id","String"],["pairId","String"],["recordJson","Text"],["archivedAt","Long"]]); }
  getPrimaryKeyList() { return ['id']; }
  getIndexList() { return ["pairId"]; }
  getEncryptedFieldList() { return []; }
  getId() { return this.id; }
  setId(value) { this.id = value; }
  getPairId() { return this.pairId; }
  setPairId(value) { this.pairId = value; }
  getRecordJson() { return this.recordJson; }
  setRecordJson(value) { this.recordJson = value; }
  getArchivedAt() { return safeLong(this.archivedAt); }
  setArchivedAt(value) { this.archivedAt = value; }
}
class PairPlanWake {
  constructor() { this.id = ''; this.pairId = ''; this.eventId = ''; this.createdAt = 0; this.proof = ''; }
  getClassName() { return 'PairPlanWake'; }
  getFieldTypeMap() { return new Map([["id","String"],["pairId","String"],["eventId","String"],["createdAt","Long"],["proof","String"]]); }
  getPrimaryKeyList() { return ['id']; }
  getIndexList() { return ["pairId"]; }
  getEncryptedFieldList() { return []; }
  getId() { return this.id; }
  setId(value) { this.id = value; }
  getPairId() { return this.pairId; }
  setPairId(value) { this.pairId = value; }
  getEventId() { return this.eventId; }
  setEventId(value) { this.eventId = value; }
  getCreatedAt() { return safeLong(this.createdAt); }
  setCreatedAt(value) { this.createdAt = value; }
  getProof() { return this.proof; }
  setProof(value) { this.proof = value; }
}
module.exports = { PairPlanSyncState, PairPlanChange, PairPlanArchive, PairPlanArchiveVote, PairPlanReceiptArchive, PairPlanEventArchive, PairPlanWake };
