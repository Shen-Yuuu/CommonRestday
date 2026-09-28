/**
 * 云同步失败之后的三态收敛（协议 §3.4 末行「UI 只消费已同步/待重试/已降级」+ §7 末行「当天不再重排」）。
 *
 * 整份都是纯函数，**判断与发送/写库分开**：设备侧改不了系统钟（`hdc shell` 无 root，
 * `date -s` 回 `Operation not permitted`），于是"当天不再重排"这种按日期的分支在真机上属于撞运气，
 * 权威覆盖只能离线断言——同 `ProfileSettingsService.heartbeatDue`、`greetingOf` 的口径。
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
 * 今天还排不排得动一次推送，两条规则各对应 §3.4 的一行：
 * - 可重试（超时/配额）→ **只有当天**排不动，换日后第一次真实保存自然再试；
 * - 不可重试（语义拒绝、本机密钥/解码失败）→ 一直排不动，直到某一次**拉**成功把它清回「已同步」。
 *
 * 换日的判据是 `epochDay` 相等而不是时间差：配额按天恢复，跨了日切就该放出去试一次。
 * 时钟被往回拨时 `day !== today`，结果是"多试一次"，与心跳那条同一取向。
 */
export function pushBlockedToday(raw: string, today: number): boolean {
  const s = decodeSyncState(raw);
  if (s.outcome === SYNC_STATE_BLOCKED) {
    return true;
  }
  return s.outcome === SYNC_STATE_RETRY && s.day === today;
}

/**
 * 失败收敛成哪一态，唯一依据是 `CloudApiError.retryable`。
 * 不是云错误（HUKS 拒绝、解码炸了）一律按不可重试：那是本机或配对凭据的问题，重发同一份只会再失败一次。
 */
export function outcomeOfFailure(retryable: boolean): string {
  return retryable ? SYNC_STATE_RETRY : SYNC_STATE_BLOCKED;
}

/**
 * 这台设备要不要在页面上挂那一句坏消息：三态里只剩两格坏值才算。
 * 三处读它的页面（首页、共同时间、「我的」配对卡）判据必须一模一样——
 * 同一件事在两个页面两种说法，正是最终验收 R1 点过的那类问题。
 * 开关（`FeatureFlags.cloudPairing`）与"这一页要不要让位给别的提示"留给各页自己判断。
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

/** 提示条正文：说清"现在 TA 看到的是哪一份"以及"下一次什么时候再试"，不给承诺不了的日期。 */
export function syncStateNoteOf(s: SyncState): string {
  if (s.outcome === SYNC_STATE_RETRY) {
    if (s.code === 'QUOTA_EXHAUSTED') {
      return '今天的同步次数用完了，明天会自动恢复；这期间 TA 看到的还是上一次那一份。';
    }
    return '暂时连不上云端，今天不再重试；明天改班表时会自动再试一次。';
  }
  if (s.outcome !== SYNC_STATE_BLOCKED) {
    return '';
  }
  if (s.code === 'UNAUTHORIZED' || s.code === 'FORBIDDEN' || s.code === 'NOT_FOUND') {
    return '云端不认这个配对了，重新配对后才能继续同步；本机数据不受影响。';
  }
  if (s.code === 'SCHEMA_UNSUPPORTED') {
    return '云端版本和手机上的应用对不上，更新应用后才能继续同步。';
  }
  if (s.code === SYNC_CODE_LOCAL) {
    return '这台手机解不开你们的同步数据了，解除配对再重新配对一次就能恢复；本机数据不受影响。';
  }
  return '这次失败不是网络问题，重试也不会有变化。这期间共同时间只用这台手机上的数据算。';
}
