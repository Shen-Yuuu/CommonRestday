import { describe, expect, it, beforeAll, afterAll } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { MIN_PER_DAY, todayEpochDay } from 'domain';
import {
  Db, MigrationRunner, PAIRED, PAIR_NONE, SCHEMA_VERSION, SCHEMA_VERSION_KEY,
  ScheduleRepo, SettingsStore, PlanRow
} from 'data';
import { CalendarState } from 'feature';

/**
 * 升级与恢复的设备侧验收（阶段 6 Task 6.1）。
 *
 * 与离线用例（entry/src/test/DbMigrationTest.ets）的分工：那边用内存替身钉住"该发哪些语句、
 * 失败留在哪一格"这些决策；这里证明这些语句打在真实 RDB / 真实 Preferences 上，
 * 效果确实是"设备本地的事实在换机后作废，用户数据一条不丢"。
 *
 * 覆盖的场景与对应的不可伪造证据：
 * - 全新安装 / 存量升级：生效结构版本 == 本包目标版本（列是否补齐由离线用例与 DDL 同源保证）；
 * - 刚从别的设备恢复：日历投影降级、事件 id 清空、提醒句柄归 -1、云端声明回到仅本地
 *   （含阶段 6R.1 新增的"待清理"那一格：来源设备的句柄绝不能被这台机器的启动清扫认领）；
 * - 普通启动：同样这批计划行原样不动（不误伤）；
 * - 结构版本比本包高：整包不写库，也不把别人的版本号改小；
 * - 恢复后配对：清 key、清 pairId、状态回 NONE 这三步在真机 Preferences 上确实落得住
 *   （密钥残留由测试直接经 Preferences 种下——阶段 6R.2 已删掉生产写入口，见 seedLegacyPairKey）。
 *
 * 两处刻意不在自动化里做：
 * - 备份框架真正跑一次"备份 → 恢复到另一台设备"要两台机器（或本机备份到 PC 再恢复），
 *   列在 docs/testing-checklist.md 的手工项里；这里改成"写标记 + 重开库"，
 *   走的正是 onRestore 置位后产品第一次启动会经过的同一条消费路径。
 * - 迁移中途失败只能靠注入 SQL 异常模拟，真机没有那个开关，由离线用例覆盖。
 *
 * 测试数据用一个可辨识的 id，跑完以 CANCELLED 留在库里（listActivePlans 不再返回它）。
 */

const FIXTURE_ID = 'plan_restore_test';
/** 假的来源设备日历事件 id：恢复清理后必须变成空串。 */
const STALE_EVENT_ID = 'restored-foreign-event';
/** 假的来源设备提醒句柄：恢复清理后必须变成 -1。 */
const STALE_REMINDER_ID: number = 777;

/** 造一行"看起来刚从别的设备恢复过来"的计划。 */
function staleRow(calendarState: string, syncState: string, reminderId: number): PlanRow {
  const noon: number = todayEpochDay() * MIN_PER_DAY + 12 * 60;
  const row: PlanRow = {
    id: FIXTURE_ID, title: '恢复验收计划', kind: 'MEAL', status: 'OK',
    createdBy: 'ME', windowRef: '', conflictHint: '',
    start: noon, end: noon + 30,
    myEventId: STALE_EVENT_ID, reminderId: reminderId, updatedAt: Date.now(),
    calendarState: calendarState, syncState: syncState
  };
  return row;
}

async function fixtureRow(): Promise<PlanRow | null> {
  const rows: PlanRow[] = await ScheduleRepo.listActivePlans();
  for (let i = 0; i < rows.length; i++) {
    if (rows[i].id === FIXTURE_ID) {
      return rows[i];
    }
  }
  return null;
}

/** 每次现取，避免把 Context 存在闭包变量里（也省掉"是否已赋值"的麻烦）。 */
function appCtx(): common.Context {
  return abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
}

/**
 * 沙箱里那份真实的 crd_settings。store 名与键名必须与 SettingsStore 一致（data 层没有
 * 对外暴露这两个常量，也没有测试专用的写入口）——对不上就等于没在验收生产路径。
 */
const PREFS_STORE = 'crd_settings';
/** 旧原型把"邀请码 SHA-256"当长期密钥写进来的那个键。 */
const LEGACY_PAIR_KEY = 'pair_key';

/**
 * 把长期密钥残留"种"进沙箱：阶段 6R.2 删掉了生产写入口（`savePairKey` + `deriveKeyHex`），
 * 但"换机恢复前，明文 Preferences 里可能留着上一版留下的密钥"这条输入事实仍然成立，
 * 而清理它的 `clearPairKey()` 是生产代码。所以残留由测试自己经 Preferences 造出来，
 * 断言的仍是那条真实落盘的清理链路——而不是把密钥断言删掉来迁就"没有写入口"。
 */
async function seedLegacyPairKey(value: string): Promise<void> {
  const prefs: preferences.Preferences = await preferences.getPreferences(appCtx(), PREFS_STORE);
  await prefs.put(LEGACY_PAIR_KEY, value);
  await prefs.flush();
}

/**
 * 模拟"恢复后第一次冷启动"：重开库，让 Db.init 里的 MigrationRunner
 * 消费 sync_meta 上的待清理标记。不另起一套清理实现，验收的就是生产路径本身。
 */
async function relaunch(): Promise<void> {
  Db.reset();
  await Db.init(appCtx());
}

export default function upgradeMigrationTest() {
  describe('UpgradeMigrationTest', () => {
    beforeAll(async () => {
      await Db.init(appCtx());
      await SettingsStore.init(appCtx());
    })

    afterAll(async () => {
      const row = await fixtureRow();
      if (row != null) {
        row.status = 'CANCELLED';
        await ScheduleRepo.upsertPlan(row);
      }
    })

    /** 全新安装与存量升级最后都收敛到同一个生效版本，且重复 init 无副作用。 */
    it('opened_db_matches_the_target_schema', 0, async () => {
      expect(Db.version()).assertEqual(SCHEMA_VERSION);
      expect(await ScheduleRepo.getMeta(SCHEMA_VERSION_KEY)).assertEqual(String(SCHEMA_VERSION));
      await relaunch();
      expect(Db.version()).assertEqual(SCHEMA_VERSION);
    });

    /** 恢复标记：只在本机成立的三类事实一起作废，用户数据本身一条不少。 */
    it('restore_marker_demotes_stale_device_facts', 0, async () => {
      await ScheduleRepo.upsertPlan(staleRow(CalendarState.MANAGED_WRITTEN, 'SYNCED', STALE_REMINDER_ID));
      await ScheduleRepo.setMeta(MigrationRunner.RESTORE_PENDING_KEY, MigrationRunner.RESTORE_PENDING_ON);

      await relaunch();

      const row = await fixtureRow();
      expect(row != null).assertTrue();
      const r: PlanRow = row as PlanRow;
      expect(r.calendarState).assertEqual(CalendarState.LOCAL_ONLY);
      expect(r.myEventId).assertEqual('');
      expect(r.reminderId).assertEqual(-1);
      expect(r.syncState).assertEqual('LOCAL_ONLY');
      // 标题/时间属于用户数据，恢复后要原样还在
      expect(r.title).assertEqual('恢复验收计划');
      expect(r.end - r.start).assertEqual(30);
      // 标记随清理一起摘掉：下次启动不会再来一遍
      expect(await ScheduleRepo.getMeta(MigrationRunner.RESTORE_PENDING_KEY)).assertEqual('');
    });

    /** 等待确认中的计划同样要降级：换机后没人还在那台设备上等确认页。 */
    it('pending_confirmation_is_demoted_with_the_rest', 0, async () => {
      await ScheduleRepo.upsertPlan(staleRow(CalendarState.PENDING, 'PENDING', -1));
      await ScheduleRepo.setMeta(MigrationRunner.RESTORE_PENDING_KEY, MigrationRunner.RESTORE_PENDING_ON);

      await relaunch();

      const r: PlanRow = await fixtureRow() as PlanRow;
      expect(r.calendarState).assertEqual(CalendarState.LOCAL_ONLY);
      expect(r.syncState).assertEqual('LOCAL_ONLY');
    });

    /**
     * "旧日程删不动"那一格（CLEANUP_PENDING）更要跟着换机作废：这些句柄属于来源设备，
     * 留下 id 会让这台机器上的启动清扫拿着别人的编号去删日历。
     * 断言用清扫自己的那份读模型——它空了，才是真的没东西可清。
     */
    it('cleanup_pending_handles_are_voided_before_the_sweep_sees_them', 0, async () => {
      await ScheduleRepo.upsertPlan(staleRow(CalendarState.CLEANUP_PENDING, 'LOCAL_ONLY', STALE_REMINDER_ID));
      await ScheduleRepo.setMeta(MigrationRunner.RESTORE_PENDING_KEY, MigrationRunner.RESTORE_PENDING_ON);

      await relaunch();

      const r: PlanRow = await fixtureRow() as PlanRow;
      expect(r.calendarState).assertEqual(CalendarState.LOCAL_ONLY);
      expect(r.myEventId).assertEqual('');
      expect(r.reminderId).assertEqual(-1);
      const orphans: PlanRow[] = await ScheduleRepo.listOrphanProjectionPlans();
      for (let i = 0; i < orphans.length; i++) {
        expect(orphans[i].id != FIXTURE_ID).assertTrue();
      }
      const carriers: PlanRow[] = await ScheduleRepo.listPlansCarryingHandles();
      for (let i = 0; i < carriers.length; i++) {
        expect(carriers[i].id != FIXTURE_ID).assertTrue();
      }
    });

    /** 普通启动（没有恢复标记）绝不改动画历状态：否则每次冷启都在把用户已写进日历的计划打回"仅本地"。 */
    it('ordinary_launch_touches_nothing', 0, async () => {
      await ScheduleRepo.upsertPlan(staleRow(CalendarState.MANAGED_WRITTEN, 'SYNCED', STALE_REMINDER_ID));
      expect(await ScheduleRepo.getMeta(MigrationRunner.RESTORE_PENDING_KEY)).assertEqual('');

      await relaunch();

      const r: PlanRow = await fixtureRow() as PlanRow;
      expect(r.calendarState).assertEqual(CalendarState.MANAGED_WRITTEN);
      expect(r.myEventId).assertEqual(STALE_EVENT_ID);
      expect(r.reminderId).assertEqual(STALE_REMINDER_ID);
      expect(r.syncState).assertEqual('SYNCED');
    });

    /**
     * 恢复后无法解密时必须回到"重新配对"：onRestore 用的这三步在真机 Preferences 上要真落得住，
     * 否则换机后会留着一个声称 PAIRED 的状态，界面上就是谎报同步成功。
     */
    it('pairing_reset_lands_on_real_preferences', 0, async () => {
      const hadState: string = SettingsStore.getPairState();
      const hadUid: string = SettingsStore.getPartnerUid();
      const hadVer: number = SettingsStore.getPartnerSnapVer();
      const hadKey: string = await SettingsStore.getPairKey();
      try {
        await seedLegacyPairKey('not-a-real-huks-handle');
        await SettingsStore.savePairId('pair-from-the-old-device');
        await SettingsStore.setPairState(PAIRED, 'uid-of-the-old-partner');
        expect(SettingsStore.getPairState()).assertEqual(PAIRED);
        // 残留确实经过了真实的 Preferences 落盘，不是被读逻辑吞掉了
        expect(await SettingsStore.getPairKey()).assertEqual('not-a-real-huks-handle');

        // 与 EntryBackupAbility.onRestore 同一组调用
        await SettingsStore.clearPairKey();
        await SettingsStore.savePairId('');
        await SettingsStore.setPartnerSnapVer(0);
        await SettingsStore.setPairState(PAIR_NONE, '');

        expect(SettingsStore.getPairState()).assertEqual(PAIR_NONE);
        expect(await SettingsStore.getPairKey()).assertEqual('');
        expect(SettingsStore.getPairId()).assertEqual('');
        expect(SettingsStore.getPartnerSnapVer()).assertEqual(0);
        expect(SettingsStore.getPartnerUid()).assertEqual('');
      } finally {
        // 还回测试机上原有的配对事实（setPairState 顺带清掉的"已提示重新配对"除外：
        // 那只是一次性通知标记，多提示一次比把用户自己的状态改丢要轻）
        await SettingsStore.setPairState(hadState, hadUid);
        await SettingsStore.setPartnerSnapVer(hadVer);
        if (hadKey !== '') {
          await seedLegacyPairKey(hadKey);
        }
      }
    });

    /**
     * 结构版本比本包高（从更新的装机恢复回来、或回滚安装了旧包）：
     * 本包既不动结构也不动 stamp，否则以后真到升级那一步就永远不跑了。
     */
    it('newer_schema_is_never_rewritten', 0, async () => {
      const marker: string = '99';
      try {
        await ScheduleRepo.setMeta(SCHEMA_VERSION_KEY, marker);
        await relaunch();
        expect(Db.version()).assertEqual(99);
        expect(await ScheduleRepo.getMeta(SCHEMA_VERSION_KEY)).assertEqual(marker);
      } finally {
        await ScheduleRepo.setMeta(SCHEMA_VERSION_KEY, String(SCHEMA_VERSION));
        await relaunch();
        expect(Db.version()).assertEqual(SCHEMA_VERSION);
      }
    });
  })
}
