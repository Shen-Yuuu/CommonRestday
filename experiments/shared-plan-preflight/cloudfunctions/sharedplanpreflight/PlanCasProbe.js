/** Matches clouddb/objecttype/PlanCasProbe.json; contains no pairing or plan contents. */
class PlanCasProbe {
  constructor() { this.id = ''; this.version = 0; this.state = ''; this.createdAt = 0; }
  getClassName() { return 'PlanCasProbe'; }
  getFieldTypeMap() { return new Map([['id', 'String'], ['version', 'Integer'], ['state', 'String'], ['createdAt', 'Long']]); }
  getPrimaryKeyList() { return ['id']; }
  getIndexList() { return []; }
  getEncryptedFieldList() { return []; }
  getId() { return this.id; }
  setId(value) { this.id = value; }
  getVersion() { return this.version; }
  setVersion(value) { this.version = value; }
  getState() { return this.state; }
  setState(value) { this.state = value; }
  getCreatedAt() { return this.createdAt; }
  setCreatedAt(value) { this.createdAt = value; }
}
module.exports = { PlanCasProbe };
