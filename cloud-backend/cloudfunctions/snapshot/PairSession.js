/*
 * 两人份 · CloudDB 对象类型 PairSession 的模型文件。
 *
 * 形态照抄 DevEco「生成对象类型文件」的产物（对照 spike 的 `SpikeProbe.js`）：
 * 五个 `getXxxMap/List` 是 Server SDK 反射字段用的约定口，字段读写靠成对的 getter/setter。
 * DevEco 会在部署前用 `clouddb/objecttype/PairSession.json` 重新生成同名文件，
 * 所以这里的字段集必须与那份 JSON **逐字一致**——不一致就是部署时静默少字段。
 * 云对象目录里必须有它：部署包只含自己那个目录，模型不能从别处 require。
 */

class PairSession {
    getFieldTypeMap() {
        let fieldTypeMap = new Map();
        fieldTypeMap.set('pairId', 'String');
        fieldTypeMap.set('status', 'String');
        fieldTypeMap.set('code', 'String');
        fieldTypeMap.set('creatorUid', 'String');
        fieldTypeMap.set('creatorPublicKey', 'String');
        fieldTypeMap.set('joinerUid', 'String');
        fieldTypeMap.set('joinerPublicKey', 'String');
        fieldTypeMap.set('confirmToken', 'String');
        fieldTypeMap.set('schemaVersion', 'Integer');
        fieldTypeMap.set('createdAt', 'Long');
        fieldTypeMap.set('updatedAt', 'Long');
        fieldTypeMap.set('expiresAt', 'Long');
        return fieldTypeMap;
    }

    getClassName() {
        return 'PairSession';
    }

    getPrimaryKeyList() {
        let primaryKeyList = [];
        primaryKeyList.push('pairId');
        return primaryKeyList;
    }

    /*
     * Server SDK 只把这个口当作"模型是否合法"的探测（Utils.js 只 typeof 检查），
     * 真正的索引由 clouddb/objecttype/*.json 在建表时下发，所以这里保持生成器的空数组。
     */
    getIndexList() {
        let indexList = [];
        return indexList;
    }

    getEncryptedFieldList() {
        let encryptedFieldList = [];
        return encryptedFieldList;
    }

    setPairId(pairId) {
        this.pairId = pairId;
    }

    getPairId() {
        return this.pairId;
    }

    setStatus(status) {
        this.status = status;
    }

    getStatus() {
        return this.status;
    }

    setCode(code) {
        this.code = code;
    }

    getCode() {
        return this.code;
    }

    setCreatorUid(creatorUid) {
        this.creatorUid = creatorUid;
    }

    getCreatorUid() {
        return this.creatorUid;
    }

    setCreatorPublicKey(creatorPublicKey) {
        this.creatorPublicKey = creatorPublicKey;
    }

    getCreatorPublicKey() {
        return this.creatorPublicKey;
    }

    setJoinerUid(joinerUid) {
        this.joinerUid = joinerUid;
    }

    getJoinerUid() {
        return this.joinerUid;
    }

    setJoinerPublicKey(joinerPublicKey) {
        this.joinerPublicKey = joinerPublicKey;
    }

    getJoinerPublicKey() {
        return this.joinerPublicKey;
    }

    setConfirmToken(confirmToken) {
        this.confirmToken = confirmToken;
    }

    getConfirmToken() {
        return this.confirmToken;
    }

    setSchemaVersion(schemaVersion) {
        this.schemaVersion = schemaVersion;
    }

    getSchemaVersion() {
        return this.schemaVersion;
    }

    setCreatedAt(createdAt) {
        this.createdAt = createdAt;
    }

    getCreatedAt() {
        return this.createdAt;
    }

    setUpdatedAt(updatedAt) {
        this.updatedAt = updatedAt;
    }

    getUpdatedAt() {
        return this.updatedAt;
    }

    setExpiresAt(expiresAt) {
        this.expiresAt = expiresAt;
    }

    getExpiresAt() {
        return this.expiresAt;
    }
}

module.exports = {PairSession}
