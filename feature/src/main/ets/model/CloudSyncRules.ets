/**
 * 云同步失败之后的三态收敛：失败后暂停自动云请求，直到用户在「我的」手动重试。
 *
 * 整份都是纯函数，**判断与发送/写库分开**：线值兼容旧包的日序，但暂停与否不再依赖本机日切。
 * `ScheduleUseCase` 只负责把 `CloudApiError.retryable` 递进 `outcomeOfFailure`，
 * 以及把 `encodeSyncState` 的串存进偏好、在排推送之前问一句 `pushBlockedToday`。
 *
 * 这里**不排任何"稍后再试一次"的定时器**（协议 §3.3 明文）：本项目不做后台常驻，
 * 静默重试循环等于把免费档的按天配额烧在用户看不见的地方，还会把真同步挤成 `QUOTA_EXHAUSTED`。
 */

/** 三态的线值：偏好里存的就是这三个串之一，空串=这台设备还没试过同步。 */
export const SYNC_STATE_OK = 'SYNCED';
export const SYNC_STATE_RETRY = 'RETRY';
export const SYNC_STATE_BLOCKED = 'BLOCKED';

/**
 * 「不是云错误」这一格的语义码（协议 §7 的解密/解码失败与密钥失配三行都落在这里）。
 * 用它挑文案而不是留空：那三行的处置写死了"提示重新配对"，兜底那句给不出这个指引。
 */
export const SYNC_CODE_LOCAL = 'LOCAL';

/** 一次同步结论：三态 + 落在哪一天（epochDay）+ 语义码。语义码只用来挑文案，不显示给用户。 */
export interface SyncState {
  outcome: string;
  day: number;
  code: string;
}

const SEP = '|';

/** 编码成一个串而不是三个偏好键：这三格永远一起变，分三格就把"只写了一半"做出来了。 */
export function encodeSyncState(outcome: string, day: number, code: string): string {
  return outcome + SEP + day + SEP + code;
}

/**
 * 解码。脏串、缺段、非数字一律回到「已同步」——宁可这条提示不出来，
 * 也不要因为一次偏好写坏就在配对卡里挂一条"同步已降级"的假警报。
 */
export function decodeSyncState(raw: string): SyncState {
  const parts = raw.split(SEP);
  let day = 0;
  if (parts.length >= 2) {
    const n = Number(parts[1]);
    day = Number.isNaN(n) ? 0 : n;
  }
  const code = parts.length >= 3 ? parts[2] : '';
  let outcome = SYNC_STATE_OK;
  if (parts[0] === SYNC_STATE_RETRY || parts[0] === SYNC_STATE_BLOCKED) {
    outcome = parts[0];
  }
  const s: SyncState = { outcome: outcome, day: day, code: code };
  return s;
}

/**
 * 兼容旧调用签名和旧存储格式，但日序不再解除暂停：任何失败都须由用户主动处理。
 */
export function pushBlockedToday(raw: string, today: number): boolean {
  const s = decodeSyncState(raw);
  return s.outcome === SYNC_STATE_BLOCKED || s.outcome === SYNC_STATE_RETRY;
}

/** 只有暂时性故障提供手动重试；凭据/版本类故障需要先按指引修复。 */
export function canManuallyRetry(s: SyncState): boolean {
  return s.outcome === SYNC_STATE_RETRY;
}

/**
 * 失败收敛成哪一态，唯一依据是 `CloudApiError.retryable`。
 * 不是云错误（HUKS 拒绝、解码炸了）一律按不可重试：那是本机或配对凭据的问题，重发同一份只会再失败一次。
 */
export function outcomeOfFailure(retryable: boolean): string {
  return retryable ? SYNC_STATE_RETRY : SYNC_STATE_BLOCKED;
}

/**
 * 合法档位的专用未知值。它故意落在 1–3 之外：任何一处把它折回某一档，
 * 就又是一次伪造读数（批次 AO 之前那个 `catch → 2` 就是这一折产生的）。
 */
export const SHARE_LEVEL_UNKNOWN = 0;

/**
 * 存储里那份共享等级能不能当真实值用：只认 1/2/3，其余（NaN、脏值、越界、未初始化）一律「未知」。
 *
 * 纯判断，不碰偏好——读偏好的那一处负责把异常也换成这个未知值，两处合起来才是完整口径。
 * 为什么不折成 L1 也不折成 L2：折 L2 会把存的是 L3 的用户念小（§8.26 实测到的正是这一形），
 * 折 L1 会反过来把只承诺了 L1 的用户的多推出去；而把这个占位值当设置存回去，
 * 等于替用户选了一个他没选过的隐私档位。未知只能被说成未知。
 */
export function shareLevelFromStore(raw: number): number {
  return raw === 1 || raw === 2 || raw === 3 ? raw : SHARE_LEVEL_UNKNOWN;
}

/**
 * 这台设备要不要在「我的」配对卡挂坏消息；首页和共同时间不再展示云故障条。
 */
export function syncTroubleOf(s: SyncState): boolean {
  return syncStateNoteOf(s) !== '';
}

/** 提示条标题：三态各有各的名字，不只靠颜色区分。已同步与从未试过回空串。 */
export function syncStateTitleOf(s: SyncState): string {
  if (s.outcome === SYNC_STATE_RETRY) {
    return '云同步暂时没成功';
  }
  if (s.outcome === SYNC_STATE_BLOCKED) {
    return '云同步已停止';
  }
  return '';
}

/** 提示条正文：说清 TA 看到的是哪一份以及需要用户主动重试，不承诺自动恢复。 */
export function syncStateNoteOf(s: SyncState): string {
  if (s.outcome === SYNC_STATE_RETRY) {
    if (s.code === 'QUOTA_EXHAUSTED') {
      return '云端提示今日同步次数已用尽；额度恢复后请手动重试。这期间 TA 看到的还是上一次那一份。';
    }
    return '这次云同步未完成，自动同步已暂停；请手动重试。这期间 TA 看到的还是上一次那一份。';
  }
  if (s.outcome !== SYNC_STATE_BLOCKED) {
    return '';
  }
  if (s.code === 'UNAUTHORIZED' || s.code === 'FORBIDDEN' || s.code === 'NOT_FOUND') {
    return '云端不认这个配对了，重新配对后才能继续同步；本机数据不受影响。';
  }
  if (s.code === 'SCHEMA_UNSUPPORTED') {
    return '云端版本和手机上的应用对不上；请更新应用，再解除并重新配对。';
  }
  if (s.code === SYNC_CODE_LOCAL) {
    return '这台手机解不开你们的同步数据了，解除配对再重新配对一次就能恢复；本机数据不受影响。';
  }
  if (s.code === 'CONFLICT_VERSION') {
    return '云端版本与本机版本冲突；请解除并重新配对后再同步，本机数据不受影响。';
  }
  return '这次失败不是网络问题，直接重试也不会有变化；请检查配对或重新配对。本机数据不受影响。';
}
