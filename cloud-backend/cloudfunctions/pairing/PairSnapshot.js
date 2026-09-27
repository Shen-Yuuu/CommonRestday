/*
 * 两人份 · CloudDB 对象类型 PairSnapshot 的模型文件。
 *
 * 形态照抄 DevEco「生成对象类型文件」的产物（对照 spike 的 `SpikeProbe.js`）：
 * 五个 `getXxxMap/List` 是 Server SDK 反射字段用的约定口，字段读写靠成对的 getter/setter。
 * DevEco 会在部署前用 `clouddb/objecttype/PairSnapshot.json` 重新生成同名文件，
 * 所以这里的字段集必须与那份 JSON **逐字一致**——不一致就是部署时静默少字段。
 *
 * `ciphertext` 必须是 `Text`：Server SDK 对 `String` 的写入有 200 字符硬上限
 * （DataModelHelper 的 MAX_STRING_LENGTH），几十 KB 的 base64 密文一定超。
 * 复合主键 pairId + ownerUid 是"每人每对一个快照"这条约束的落点。
 */

class PairSnapshot {
    getFieldTypeMap() {
        let fieldTypeMap = new Map();
        fieldTypeMap.set('pairId', 'String');
        fieldTypeMap.set('ownerUid', 'String');
        fieldTypeMap.set('peerUid', 'String');
        fieldTypeMap.set('version', 'Long');
        fieldTypeMap.set('shareLevel', 'Integer');
        fieldTypeMap.set('schemaVersion', 'Integer');
        fieldTypeMap.set('algorithm', 'String');
        fieldTypeMap.set('iv', 'String');
        fieldTypeMap.set('authTag', 'String');
        fieldTypeMap.set('ciphertext', 'Text');
        fieldTypeMap.set('updatedAt', 'Long');
        return fieldTypeMap;
    }

    getClassName() {
        return 'PairSnapshot';
    }

    getPrimaryKeyList() {
        let primaryKeyList = [];
        primaryKeyList.push('pairId');
        primaryKeyList.push('ownerUid');
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

    setOwnerUid(ownerUid) {
        this.ownerUid = ownerUid;
    }

    getOwnerUid() {
        return this.ownerUid;
    }

    setPeerUid(peerUid) {
        this.peerUid = peerUid;
    }

    getPeerUid() {
        return this.peerUid;
    }

    setVersion(version) {
        this.version = version;
    }

    getVersion() {
        return this.version;
    }

    setShareLevel(shareLevel) {
        this.shareLevel = shareLevel;
    }

    getShareLevel() {
        return this.shareLevel;
    }

    setSchemaVersion(schemaVersion) {
        this.schemaVersion = schemaVersion;
    }

    getSchemaVersion() {
        return this.schemaVersion;
    }

    setAlgorithm(algorithm) {
        this.algorithm = algorithm;
    }

    getAlgorithm() {
        return this.algorithm;
    }

    setIv(iv) {
        this.iv = iv;
    }

    getIv() {
        return this.iv;
    }

    setAuthTag(authTag) {
        this.authTag = authTag;
    }

    getAuthTag() {
        return this.authTag;
    }

    setCiphertext(ciphertext) {
        this.ciphertext = ciphertext;
    }

    getCiphertext() {
        return this.ciphertext;
    }

    setUpdatedAt(updatedAt) {
        this.updatedAt = updatedAt;
    }

    getUpdatedAt() {
        return this.updatedAt;
    }
}

module.exports = {PairSnapshot}
