/**
 * 「待补删的云侧配对」那一份账的编解码（批次 AP·Task 1）。
 *
 * 为什么这一格住在 domain 而不是 `SettingsStore` 里：`pending_cloud_unpair` 在批次 U·U5 那一版存的是
 * **一个对象**（`{"pairId":"…","uid":"…"}`），批次 AO 把它改成了数组，而读侧只按数组解析——于是从
 * 那一版直接升上来的设备，云上那份密文在新版本眼里当场归零：不补删、不报数、界面一句都不提。
 * 用户什么都没做，账就自己没了。
 *
 * 修它只能把解码并成**一个实现**：设备侧一份、离线桩一份的话，桩跑绿证明不了真机绿（同 D-57
 * `clampHorizonDays`、D-61 `clipSpan` 的并轨方向）。domain 是唯一没有 `@kit` 依赖、又能同时被
 * 设备侧与离线转译层编进去的层，所以这里只做「串 ↔ 队列」，那一格偏好的读写仍归 data 层。
 */

/**
 * 一条待补删凭据。只有这三个字段是故意的：`pairing.unpair` 认的是会话行里的
 * `creatorUid`/`joinerUid`（协议 §4.5），删除**不需要任何密钥材料**。别的一概不存——
 * HUKS 别名、对方快照、任何明文忙碌时段都不属于「把云上那行删掉」这件事，
 * 把它们留在一次「清空我的全部数据」之后就是漏披露。
 *
 * `dead` 为真表示云端已经给了**终局判定**（不是那个会话的成员、参数不合法、版本对不上）——
 * 再敲一百次门也是同一句，于是它退出补删队列，只留着向用户如实报「云上还剩一份删不掉」。
 * 这一位是批次 AO 加的：终局之前只在日志里留了一行，用户看不见自己还剩这么个东西。
 */
export interface PendingCloudUnpair {
  pairId: string;
  uid: string;
  dead: boolean;
}

/**
 * 读整条队列。两种历史形状都认：
 *
 * - **数组**（批次 AO 起）：逐条取，缺 `pairId` 或 `uid` 的那一条按「没有这一条」跳过；
 * - **单对象**（批次 U·U5 那一版）：读成一条 `dead = false`。那一版只在「清空全部数据」没删动时
 *   写过它，当时的语义就是「还欠着、也还值得再敲」，所以缺的那一位落在可重试那一支——
 *   把它当「非数组脏值」丢掉，就等于替用户把一笔删得动的账判成从没发生过。
 *
 * 脏串、`null`、空对象、解析或取值中途炸开一律回空队列：宁可这条提示不出来，
 * 也不要一次偏好写坏就在页面上挂假警报（与 `decodeSyncState` 同一取向）。
 */
export function decodeCloudDebts(text: string): PendingCloudUnpair[] {
  const out: PendingCloudUnpair[] = [];
  if (text === '') {
    return out;
  }
  try {
    const parsed: Object = JSON.parse(text);
    if (parsed == null) {
      return out;
    }
    const rows: Array<Record<string, Object>> = Array.isArray(parsed)
      ? parsed as Array<Record<string, Object>>
      : [parsed as Record<string, Object>];
    for (let i = 0; i < rows.length; i++) {
      const o = rows[i];
      if (o == null) {
        continue;
      }
      const pairId = o['pairId'] == null ? '' : String(o['pairId']);
      const uid = o['uid'] == null ? '' : String(o['uid']);
      if (pairId === '' || uid === '') {
        continue;
      }
      const rec: PendingCloudUnpair = { pairId: pairId, uid: uid, dead: String(o['dead']) === '1' };
      out.push(rec);
    }
  } catch (e) {
    return [];
  }
  return out;
}

/**
 * 写整份队列成一个串；空队列写空串（这几条永远一起变，分成几格就把「只写了一半」做出来了）。
 *
 * `dead` 存 **1/0 而不是布尔**：`JSON.stringify(true)` 出来是 `true`，而读侧认的是 `1`；
 * 用布尔写就用布尔读，两边各认一种字面量，就是「登记了却读不出」的那一格。
 * 写入端只产数组形状——单对象那一种只属于读侧的兼容，新账不许再往旧形状写。
 */
export function encodeCloudDebts(list: PendingCloudUnpair[]): string {
  if (list.length === 0) {
    return '';
  }
  const rows: Array<Record<string, Object>> = [];
  for (let i = 0; i < list.length; i++) {
    const o: Record<string, Object> = {
      'pairId': list[i].pairId, 'uid': list[i].uid, 'dead': list[i].dead ? 1 : 0
    };
    rows.push(o);
  }
  return JSON.stringify(rows);
}
