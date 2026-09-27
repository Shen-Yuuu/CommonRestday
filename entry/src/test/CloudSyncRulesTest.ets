import { describe, it, expect } from '@ohos/hypium';
import {
  decodeSyncState, encodeSyncState, outcomeOfFailure, pushBlockedToday, SYNC_CODE_LOCAL,
  SYNC_STATE_BLOCKED, SYNC_STATE_OK, SYNC_STATE_RETRY, SyncState, syncStateNoteOf, syncStateTitleOf
} from 'feature';

/**
 * 云同步三态的判定口径（协议 §3.4 末行 + §7 末行）。
 *
 * 这一格必须离线断言而不是等设备：`pushBlockedToday` 比的是本机日切，而设备侧改不了系统钟
 * （`hdc shell` 无 root，`date -s` 回 `Operation not permitted`），真机上"今天已经失败过一次"
 * 这一种形状要等自然日切，撞不上就是没测到——同 `heartbeatDue`、`greetingOf` 的口径。
 */
export default function cloudSyncRulesTest() {
  describe('cloudSyncRules', () => {

    /** 三态的线值会落进偏好：改了就是改了存储格式，历史包读回来会变脏值，所以钉住字面量。 */
    it('wire_values_are_the_stored_contract', 0, () => {
      expect(SYNC_STATE_OK).assertEqual('SYNCED');
      expect(SYNC_STATE_RETRY).assertEqual('RETRY');
      expect(SYNC_STATE_BLOCKED).assertEqual('BLOCKED');
      // 语义码那一段也会落库，`LOCAL` 是本机失败的固定代号（不是云端给的）
      expect(SYNC_CODE_LOCAL).assertEqual('LOCAL');
    });

    it('encode_decode_round_trip_keeps_all_three_fields', 0, () => {
      const s = decodeSyncState(encodeSyncState(SYNC_STATE_RETRY, 20453, 'QUOTA_EXHAUSTED'));
      expect(s.outcome).assertEqual(SYNC_STATE_RETRY);
      expect(s.day).assertEqual(20453);
      expect(s.code).assertEqual('QUOTA_EXHAUSTED');
      // 语义码可以为空（非云错误，例如解密炸了），但分隔符不能少，否则解码会串段
      const bare = decodeSyncState(encodeSyncState(SYNC_STATE_BLOCKED, 20453, ''));
      expect(bare.outcome).assertEqual(SYNC_STATE_BLOCKED);
      expect(bare.code).assertEqual('');
    });

    it('empty_and_dirty_strings_fail_open_to_synced', 0, () => {
      // 空串=这台设备还没试过同步；脏值=偏好被写坏。两者都不许挂出"同步已降级"的假警报
      expect(decodeSyncState('').outcome).assertEqual(SYNC_STATE_OK);
      expect(decodeSyncState('|20453|NETWORK').outcome).assertEqual(SYNC_STATE_OK);
      expect(decodeSyncState('MAYBE|20453|NETWORK').outcome).assertEqual(SYNC_STATE_OK);
      expect(decodeSyncState('RETRY').outcome).assertEqual(SYNC_STATE_RETRY);
      // 日段不是数字就当没有日期：脏日不许让"当天不再重排"永远生效
      expect(decodeSyncState('RETRY|abc|NETWORK').day).assertEqual(0);
      expect(decodeSyncState('RETRY|abc|NETWORK').code).assertEqual('NETWORK');
    });

    it('retryable_only_blocks_the_day_it_failed', 0, () => {
      const today = 20453;
      expect(pushBlockedToday(encodeSyncState(SYNC_STATE_RETRY, today, 'NETWORK'), today)).assertTrue();
      // 换日之后的第一次真实保存自然再试（协议 §3.3：不排退避重试，靠触发时机带起）
      expect(pushBlockedToday(encodeSyncState(SYNC_STATE_RETRY, today - 1, 'NETWORK'), today)).assertFalse();
      // 时钟被往回拨时 stateDay > today，结果是"多试一次"，与心跳那条同一取向
      expect(pushBlockedToday(encodeSyncState(SYNC_STATE_RETRY, today + 1, 'NETWORK'), today)).assertFalse();
    });

    it('non_retryable_blocks_until_a_pull_proves_otherwise', 0, () => {
      // 「已降级」不排任何重试：换日也不放开，只有某次拉成功把结论清回「已同步」才恢复
      expect(pushBlockedToday(encodeSyncState(SYNC_STATE_BLOCKED, 20400, 'FORBIDDEN'), 20453)).assertTrue();
      expect(pushBlockedToday('', 20453)).assertFalse();
      expect(pushBlockedToday(encodeSyncState(SYNC_STATE_OK, 20453, ''), 20453)).assertFalse();
    });

    it('failure_outcome_follows_retryable_only', 0, () => {
      expect(outcomeOfFailure(true)).assertEqual(SYNC_STATE_RETRY);
      // 不是 CloudApiError 的（HUKS 拒绝、解码炸了）按不可重试：重发同一份只会再失败一次
      expect(outcomeOfFailure(false)).assertEqual(SYNC_STATE_BLOCKED);
    });

    it('copy_distinguishes_the_three_states', 0, () => {
      const quota: SyncState = decodeSyncState(encodeSyncState(SYNC_STATE_RETRY, 20453, 'QUOTA_EXHAUSTED'));
      const net: SyncState = decodeSyncState(encodeSyncState(SYNC_STATE_RETRY, 20453, 'NETWORK'));
      const gone: SyncState = decodeSyncState(encodeSyncState(SYNC_STATE_BLOCKED, 20453, 'NOT_FOUND'));
      const clean: SyncState = decodeSyncState(encodeSyncState(SYNC_STATE_OK, 20453, ''));
      expect(syncStateTitleOf(clean)).assertEqual('');
      expect(syncStateNoteOf(clean)).assertEqual('');
      // 两种失败各有各的名字，不只靠颜色区分
      expect(syncStateTitleOf(quota) === syncStateTitleOf(gone)).assertFalse();
      expect(syncStateNoteOf(quota).indexOf('明天') >= 0).assertTrue();
      expect(syncStateNoteOf(net).indexOf('明天') >= 0).assertTrue();
      expect(syncStateNoteOf(gone).indexOf('重新配对') >= 0).assertTrue();
      // 本机那一格（HUKS 拒绝、解密/解码炸了，协议 §7 的解密/解码/密钥失配三行）也要指到"重新配一次"，
      // 兜底那句只说"不是网络问题"，用户读完不知道该做什么
      const local: SyncState = decodeSyncState(encodeSyncState(SYNC_STATE_BLOCKED, 20453, SYNC_CODE_LOCAL));
      expect(syncStateNoteOf(local).indexOf('重新配对') >= 0).assertTrue();
      expect(syncStateNoteOf(local) === syncStateNoteOf(gone)).assertFalse();
      // 配额用尽那句必须点名"次数"，否则用户会以为是网络坏了而反复重连
      expect(syncStateNoteOf(quota).indexOf('次数') >= 0).assertTrue();
      // 待重试与已停止是两句话：同一句措辞等于把"明天会自动恢复"承诺给一个不会自愈的态
      expect(syncStateNoteOf(quota) === syncStateNoteOf(net)).assertFalse();
      expect(syncStateNoteOf(net) === syncStateNoteOf(gone)).assertFalse();
    });
  });
}
