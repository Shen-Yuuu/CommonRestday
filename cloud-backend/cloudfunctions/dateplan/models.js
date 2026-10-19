// Reflection models and additional-models must match all deployed CloudDB definitions exactly.
class PairMemberBinding {
  constructor() { this.id = ''; this.creatorSubject = ''; this.recipientSubject = ''; this.creatorKey = ''; this.recipientKey = ''; this.recipientJoinDigest = ''; this.creatorLink = ''; this.recipientLink = ''; this.status = ''; this.inviteCode = ''; this.confirmHash = ''; this.createDigest = ''; this.revision = 0; this.protocolVersion = 0; this.projectionVersion = 0; this.createdAt = 0; this.updatedAt = 0; this.expiresAt = 0; this.storageVersion = 1; this.cleanupPending = false; this.bootstrapRoute = ''; this.bootstrapOffer = ''; }
  getClassName() { return 'PairMemberBinding'; }
  getBootstrapRoute() { return this.bootstrapRoute || ''; }
  setBootstrapRoute(value) { this.bootstrapRoute = value; }
  getBootstrapOffer() { return this.bootstrapOffer || ''; }
  setBootstrapOffer(value) { this.bootstrapOffer = value; }
  getCleanupPending() { return this.cleanupPending; }
  setCleanupPending(value) { this.cleanupPending = value; }
  getStorageVersion() { return this.storageVersion; }
  setStorageVersion(value) { this.storageVersion = value; }
  getFieldTypeMap() { return new Map([["id","String"],["creatorSubject","String"],["recipientSubject","String"],["creatorKey","String"],["recipientKey","String"],["recipientJoinDigest","String"],["creatorLink","Text"],["recipientLink","Text"],["status","String"],["inviteCode","String"],["confirmHash","String"],["createDigest","String"],["revision","Integer"],["protocolVersion","Integer"],["projectionVersion","Integer"],["createdAt","Long"],["updatedAt","Long"],["expiresAt","Long"],["storageVersion","Integer"],["cleanupPending","Boolean"],["bootstrapRoute","String"],["bootstrapOffer","Text"]]); }
  getPrimaryKeyList() { return ['id']; }
  getIndexList() { return ['bootstrapRoute']; }
  getEncryptedFieldList() { return []; }
  getId() { return this.id; }
  setId(value) { this.id = value; }
  getCreatorSubject() { return this.creatorSubject; }
  setCreatorSubject(value) { this.creatorSubject = value; }
  getRecipientSubject() { return this.recipientSubject; }
  setRecipientSubject(value) { this.recipientSubject = value; }
  getCreatorKey() { return this.creatorKey; }
  setCreatorKey(value) { this.creatorKey = value; }
  getRecipientKey() { return this.recipientKey; }
  setRecipientKey(value) { this.recipientKey = value; }
  getRecipientJoinDigest() { return this.recipientJoinDigest; }
  setRecipientJoinDigest(value) { this.recipientJoinDigest = value; }
  getCreatorLink() { return this.creatorLink; }
  setCreatorLink(value) { this.creatorLink = value; }
  getRecipientLink() { return this.recipientLink; }
  setRecipientLink(value) { this.recipientLink = value; }
  getStatus() { return this.status; }
  setStatus(value) { this.status = value; }
  getInviteCode() { return this.inviteCode; }
  setInviteCode(value) { this.inviteCode = value; }
  getConfirmHash() { return this.confirmHash; }
  setConfirmHash(value) { this.confirmHash = value; }
  getCreateDigest() { return this.createDigest; }
  setCreateDigest(value) { this.createDigest = value; }
  getRevision() { return this.revision; }
  setRevision(value) { this.revision = value; }
  getProtocolVersion() { return this.protocolVersion; }
  setProtocolVersion(value) { this.protocolVersion = value; }
  getProjectionVersion() { return this.projectionVersion; }
  setProjectionVersion(value) { this.projectionVersion = value; }
  getCreatedAt() { return this.createdAt; }
  setCreatedAt(value) { this.createdAt = value; }
  getUpdatedAt() { return this.updatedAt; }
  setUpdatedAt(value) { this.updatedAt = value; }
  getExpiresAt() { return this.expiresAt; }
  setExpiresAt(value) { this.expiresAt = value; }
}
class PairDatePlan {
  constructor() { this.id = ''; this.pairId = ''; this.planId = ''; this.proposerUid = ''; this.recipientUid = ''; this.state = ''; this.stateVersion = 0; this.contentRevision = 0; this.acceptedRevision = 0; this.pendingAuthorUid = ''; this.pendingEnvelope = ''; this.acceptedEnvelope = ''; this.createdAt = 0; this.updatedAt = 0; this.pendingExpiresAt = 0; }
  getClassName() { return 'PairDatePlan'; }
  getFieldTypeMap() { return new Map([["id","String"],["pairId","String"],["planId","String"],["proposerUid","String"],["recipientUid","String"],["state","String"],["stateVersion","Integer"],["contentRevision","Integer"],["acceptedRevision","Integer"],["pendingAuthorUid","String"],["pendingEnvelope","Text"],["acceptedEnvelope","Text"],["createdAt","Long"],["updatedAt","Long"],["pendingExpiresAt","Long"]]); }
  getPrimaryKeyList() { return ['id']; }
  getIndexList() { return ['pairId,pendingExpiresAt']; }
  getEncryptedFieldList() { return []; }
  getId() { return this.id; }
  setId(value) { this.id = value; }
  getPairId() { return this.pairId; }
  setPairId(value) { this.pairId = value; }
  getPlanId() { return this.planId; }
  setPlanId(value) { this.planId = value; }
  getProposerUid() { return this.proposerUid; }
  setProposerUid(value) { this.proposerUid = value; }
  getRecipientUid() { return this.recipientUid; }
  setRecipientUid(value) { this.recipientUid = value; }
  getState() { return this.state; }
  setState(value) { this.state = value; }
  getStateVersion() { return this.stateVersion; }
  setStateVersion(value) { this.stateVersion = value; }
  getContentRevision() { return this.contentRevision; }
  setContentRevision(value) { this.contentRevision = value; }
  getAcceptedRevision() { return this.acceptedRevision; }
  setAcceptedRevision(value) { this.acceptedRevision = value; }
  getPendingAuthorUid() { return this.pendingAuthorUid; }
  setPendingAuthorUid(value) { this.pendingAuthorUid = value; }
  getPendingEnvelope() { return this.pendingEnvelope; }
  setPendingEnvelope(value) { this.pendingEnvelope = value; }
  getAcceptedEnvelope() { return this.acceptedEnvelope; }
  setAcceptedEnvelope(value) { this.acceptedEnvelope = value; }
  getCreatedAt() { return this.createdAt; }
  setCreatedAt(value) { this.createdAt = value; }
  getUpdatedAt() { return this.updatedAt; }
  setUpdatedAt(value) { this.updatedAt = value; }
  getPendingExpiresAt() { return this.pendingExpiresAt; }
  setPendingExpiresAt(value) { this.pendingExpiresAt = value; }
}
class PairPlanRequest {
  constructor() { this.id = ''; this.pairId = ''; this.actorUid = ''; this.digest = ''; this.response = ''; this.createdAt = 0; this.expiresAt = 0; }
  getClassName() { return 'PairPlanRequest'; }
  getFieldTypeMap() { return new Map([["id","String"],["pairId","String"],["actorUid","String"],["digest","String"],["response","Text"],["createdAt","Long"],["expiresAt","Long"]]); }
  getPrimaryKeyList() { return ['id']; }
  getIndexList() { return ['pairId,createdAt']; }
  getEncryptedFieldList() { return []; }
  getId() { return this.id; }
  setId(value) { this.id = value; }
  getPairId() { return this.pairId; }
  setPairId(value) { this.pairId = value; }
  getActorUid() { return this.actorUid; }
  setActorUid(value) { this.actorUid = value; }
  getDigest() { return this.digest; }
  setDigest(value) { this.digest = value; }
  getResponse() { return this.response; }
  setResponse(value) { this.response = value; }
  getCreatedAt() { return this.createdAt; }
  setCreatedAt(value) { this.createdAt = value; }
  getExpiresAt() { return this.expiresAt; }
  setExpiresAt(value) { this.expiresAt = value; }
}
class PairPlanOutbox {
  constructor() { this.id = ''; this.pairId = ''; this.planId = ''; this.targetUid = ''; this.kind = ''; this.stateVersion = 0; this.status = ''; this.createdAt = 0; this.expiresAt = 0; }
  getClassName() { return 'PairPlanOutbox'; }
  getFieldTypeMap() { return new Map([["id","String"],["pairId","String"],["planId","String"],["targetUid","String"],["kind","String"],["stateVersion","Integer"],["status","String"],["createdAt","Long"],["expiresAt","Long"]]); }
  getPrimaryKeyList() { return ['id']; }
  getIndexList() { return ['pairId,planId', 'status']; }
  getEncryptedFieldList() { return []; }
  getId() { return this.id; }
  setId(value) { this.id = value; }
  getPairId() { return this.pairId; }
  setPairId(value) { this.pairId = value; }
  getPlanId() { return this.planId; }
  setPlanId(value) { this.planId = value; }
  getTargetUid() { return this.targetUid; }
  setTargetUid(value) { this.targetUid = value; }
  getKind() { return this.kind; }
  setKind(value) { this.kind = value; }
  getStateVersion() { return this.stateVersion; }
  setStateVersion(value) { this.stateVersion = value; }
  getStatus() { return this.status; }
  setStatus(value) { this.status = value; }
  getCreatedAt() { return this.createdAt; }
  setCreatedAt(value) { this.createdAt = value; }
  getExpiresAt() { return this.expiresAt; }
  setExpiresAt(value) { this.expiresAt = value; }
}
class PairPushTarget {
  constructor() { this.id = ''; this.pairId = ''; this.memberUid = ''; this.token = ''; this.enabled = false; this.updatedAt = 0; }
  getClassName() { return 'PairPushTarget'; }
  getFieldTypeMap() { return new Map([["id","String"],["pairId","String"],["memberUid","String"],["token","Text"],["enabled","Boolean"],["updatedAt","Long"]]); }
  getPrimaryKeyList() { return ['id']; }
  getIndexList() { return []; }
  getEncryptedFieldList() { return []; }
  getId() { return this.id; }
  setId(value) { this.id = value; }
  getPairId() { return this.pairId; }
  setPairId(value) { this.pairId = value; }
  getMemberUid() { return this.memberUid; }
  setMemberUid(value) { this.memberUid = value; }
  getToken() { return this.token; }
  setToken(value) { this.token = value; }
  getEnabled() { return this.enabled; }
  setEnabled(value) { this.enabled = value; }
  getUpdatedAt() { return this.updatedAt; }
  setUpdatedAt(value) { this.updatedAt = value; }
}
module.exports = { PairMemberBinding, PairDatePlan, PairPlanRequest, PairPlanOutbox, PairPushTarget,
  ...require('./additional-models') };
