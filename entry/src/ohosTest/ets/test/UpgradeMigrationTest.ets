import { describe, expect, it, beforeAll, afterAll } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { CycleTemplate, MIN_PER_DAY, OWNER_ME, OWNER_PARTNER, PendingCloudUnpair, ShiftType,
  todayEpochDay } from 'domain';
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
 * - 班表三表的主键确实是 (owner, id)：同一个 id 在"我"和 TA 两侧各自成立、互不覆写（批次 K-5）；
 * - 恢复后配对：清 key、清 pairId、状态回 NONE 这三步在真机 Preferences 上确实落得住
 *   （密钥残留由测试直接经 Preferences 种下——阶段 6R.2 已删掉生产写入口，见 seedLegacyPairKey）；
 * - 待补删欠账的三种历史形状（单对象／数组／脏串）种进沙箱里那份 crd_settings 后，由生产读路径
 *   原样读回（批次 AP·Task 1 的设备侧半边——离线那一格读的是内存替身，证明不了真机）。
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

/** 某侧同名班次类型的条数：主键验收只关心"这一侧有没有、有几条"。 */
async function countNamed(owner: string, name: string): Promise<number> {
  const rows: ShiftType[] = await ScheduleRepo.listShiftTypes(owner);
  let n: number = 0;
  for (let i = 0; i < rows.length; i++) {
    if (rows[i].name === name) {
      n++;
    }
  }
  return n;
}

/** 还原某侧的循环模板：原来没有就删掉验收行，原来有就按原样写回。 */
async function restoreTemplate(owner: string, saved: CycleTemplate | null): Promise<void> {
  if (saved != null) {
    await ScheduleRepo.saveTemplate(saved, owner);
  } else {
    await ScheduleRepo.deleteTemplate(owner);
  }
}

/**
 * 沙箱里那份真实的 crd_settings。store 名与键名必须与 SettingsStore 一致（data 层没有
 * 对外暴露这两个常量，也没有测试专用的写入口）——对不上就等于没在验收生产路径。
 */
const PREFS_STORE = 'crd_settings';
/** 旧原型把"邀请码 SHA-256"当长期密钥写进来的那个键。 */
const LEGACY_PAIR_KEY = 'pair_key';
/** 「待补删的云侧配对」那一格（批次 AP·Task 1 要兼容的旧形状种在这里）。 */
const DEBT_KEY = 'pending_cloud_unpair';

/**
 * 直接经真实 Preferences 种/读一格文本：`getPreferences` 按 (context, 名) 返回同一个实例，
 * 所以这里写进去的值，生产侧 `SettingsStore` 的读路径看得见——不是内存替身，是沙箱里那份。
 */
async function seedRawPreference(key: string, value: string): Promise<void> {
  const prefs: preferences.Preferences = await preferences.getPreferences(appCtx(), PREFS_STORE);
  await prefs.put(key, value);
  await prefs.flush();
}

async function readRawPreference(key: string): Promise<string> {
  const prefs: preferences.Preferences = await preferences.getPreferences(appCtx(), PREFS_STORE);
  return prefs.getSync(key, '') as string;
}

/**
 * 把长期密钥残留"种"进沙箱：阶段 6R.2 删掉了生产写入口（`savePairKey` + `deriveKeyHex`），
 * 但"换机恢复前，明文 Preferences 里可能留着上一版留下的密钥"这条输入事实仍然成立，
 * 而清理它的 `clearPairKey()` 是生产代码。所以残留由测试自己经 Preferences 造出来，
 * 断言的仍是那条真实落盘的清理链路——而不是把密钥断言删掉来迁就"没有写入口"。
 */
async function seedLegacyPairKey(value: string): Promise<void> {
  await seedRawPreference(LEGACY_PAIR_KEY, value);
}

/**
 * 读回那份残留：生产侧的 `SettingsStore.getPairKey()` 已随 HUKS 托管改造删掉了
 * （本应用不再有任何读密钥材料的路径），所以"确实落过盘 / 确实清掉了"这两条断言
 * 改由测试自己经 Preferences 读。读的仍是上面 seed 写进去的那块存储，没有换成内存替身。
 */
async function readLegacyPairKey(): Promise<string> {
  return readRawPreference(LEGACY_PAIR_KEY);
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

    /**
     * (owner, id) 主键的设备侧验收：同一个 id 在"我"和 TA 两侧各自成立，互不覆写。
     * 这里是批次 K-5 的回归位——旧结构下 cycle_template.id 是全局主键，代录侧存 'main'
     * 直接撞 UNIQUE（hilog：write failed … UNIQUE constraint failed: cycle_template.id），
     * 而 shift_type 的种子 id 两侧同名，INSERT OR REPLACE 会把"我"的那一行整行改写成对方。
     * 离线替身只能证明"发了哪些语句"，真库上撞不撞主键只有这里说了算。
     */
    it('same_id_coexists_for_both_owners', 0, async () => {
      // saveTemplate 先按 owner 删再插，所以动任何一侧前都要把现场记下来、跑完原样还原
      const savedMine: CycleTemplate | null = await ScheduleRepo.getTemplate(OWNER_ME);
      const savedTheirs: CycleTemplate | null = await ScheduleRepo.getTemplate(OWNER_PARTNER);
      const tpl: CycleTemplate = { id: 'keytest', name: '主键验收', seq: ['day'],
        anchorEpochDay: todayEpochDay(), weekdaysMask: 31 };
      const other: CycleTemplate = { id: 'keytest', name: '伴侣侧同名', seq: ['late'],
        anchorEpochDay: todayEpochDay() + 1, weekdaysMask: 96 };
      await ScheduleRepo.saveTemplate(tpl, OWNER_ME);
      await ScheduleRepo.saveTemplate(other, OWNER_PARTNER);
      const mine = await ScheduleRepo.getTemplate(OWNER_ME);
      const theirs = await ScheduleRepo.getTemplate(OWNER_PARTNER);
      expect(mine != null).assertTrue();
      expect(theirs != null).assertTrue();
      expect((mine as CycleTemplate).name).assertEqual('主键验收');
      expect((theirs as CycleTemplate).name).assertEqual('伴侣侧同名');
      expect((theirs as CycleTemplate).anchorEpochDay).assertEqual(todayEpochDay() + 1);
      expect((mine as CycleTemplate).weekdaysMask).assertEqual(31);
      expect((theirs as CycleTemplate).weekdaysMask).assertEqual(96);

      const st: ShiftType = { id: 'keytest', name: '验收班次', color: '#E8833A',
        startMin: 540, endMin: 1080, crossDay: false, commuteInMin: 0, commuteOutMin: 0,
        recoveryMin: 0, nightMode: 0, allowActivity: false, kind: 'WORK' };
      await ScheduleRepo.upsertShiftType(st, OWNER_ME);
      await ScheduleRepo.upsertShiftType(st, OWNER_PARTNER);
      expect(await countNamed(OWNER_ME, '验收班次')).assertEqual(1);
      expect(await countNamed(OWNER_PARTNER, '验收班次')).assertEqual(1);
      // 删一侧不许带走另一侧：deleteShiftType 的 owner 双条件也在这条里验
      await ScheduleRepo.deleteShiftType('keytest', OWNER_PARTNER);
      expect(await countNamed(OWNER_PARTNER, '验收班次')).assertEqual(0);
      expect(await countNamed(OWNER_ME, '验收班次')).assertEqual(1);

      await ScheduleRepo.deleteShiftType('keytest', OWNER_ME);
      await restoreTemplate(OWNER_ME, savedMine);
      await restoreTemplate(OWNER_PARTNER, savedTheirs);
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
      const hadPairId: string = SettingsStore.getPairId();
      const hadState: string = SettingsStore.getPairState();
      const hadUid: string = SettingsStore.getPartnerUid();
      const hadVer: number = SettingsStore.getPartnerSnapVer();
      const hadKey: string = await readLegacyPairKey();
      try {
        await seedLegacyPairKey('not-a-real-huks-handle');
        await SettingsStore.savePairId('pair-from-the-old-device');
        await SettingsStore.setPairState(PAIRED, 'uid-of-the-old-partner');
        expect(SettingsStore.getPairState()).assertEqual(PAIRED);
        // 残留确实经过了真实的 Preferences 落盘，不是被读逻辑吞掉了
        expect(await readLegacyPairKey()).assertEqual('not-a-real-huks-handle');

        // 与 EntryBackupAbility.onRestore 同一组调用
        await SettingsStore.clearPairKey();
        await SettingsStore.savePairId('');
        await SettingsStore.setPartnerSnapVer(0);
        await SettingsStore.setPairState(PAIR_NONE, '');

        expect(SettingsStore.getPairState()).assertEqual(PAIR_NONE);
        expect(await readLegacyPairKey()).assertEqual('');
        expect(SettingsStore.getPairId()).assertEqual('');
        expect(SettingsStore.getPartnerSnapVer()).assertEqual(0);
        expect(SettingsStore.getPartnerUid()).assertEqual('');
      } finally {
        // 还回测试机上原有的配对事实。即使中途断言失败，也不能把原 pairId 留空。
        await SettingsStore.savePairId(hadPairId);
        await SettingsStore.setPairState(hadState, hadUid);
        await SettingsStore.setPartnerSnapVer(hadVer);
        if (hadKey !== '') {
          await seedLegacyPairKey(hadKey);
        }
      }
      expect(SettingsStore.getPairId()).assertEqual(hadPairId);
      expect(SettingsStore.getPairState()).assertEqual(hadState);
      expect(SettingsStore.getPartnerUid()).assertEqual(hadUid);
      expect(SettingsStore.getPartnerSnapVer()).assertEqual(hadVer);
      expect(await readLegacyPairKey()).assertEqual(hadKey);
    });

    /**
     * 待补删欠账的设备侧兼容验收（批次 AP·Task 1 的另一半）。
     *
     * 离线那一格（`entry/src/test/ProfileSettingsGuardTest.ets`）已经钉住"解码只剩 domain 一处实现"，
     * 但它读的是 `tools/test/run.mjs` 里的内存替身——桩绿证明不了沙箱里那份真文件绿。所以这里把
     * 三种历史形状直接种进 `crd_settings`，再让生产读路径 `SettingsStore.getPendingCloudUnpair()`
     * 去读：单对象（批次 U·U5 那一版写的，直接升上来的设备就卡在这一形）、数组（本包写的，
     * 其中夹一条缺 uid 的坏行）、脏串（半截写入或手工改过）。
     * 缺 `dead` 那一位时必须读成 false：旧包压根没有这一位，把它读成"已判死"会让一笔还删得动的账
     * 从此不再被补删链敲门——比读没了更坏，因为连"下次联网会自动再试"都不再成立。
     * 结尾那一步顺手证明写侧只产数组形状：新账不许再往旧形状写，否则这条兼容链永远剪不断。
     */
    it('cloud_debt_history_shapes_read_from_real_preferences', 0, async () => {
      const had: string = await readRawPreference(DEBT_KEY);
      try {
        await seedRawPreference(DEBT_KEY, '{"pairId":"legacy-row","uid":"uid-legacy"}');
        const legacy: PendingCloudUnpair[] = SettingsStore.getPendingCloudUnpair();
        expect(legacy.length).assertEqual(1);
        expect(legacy[0].pairId).assertEqual('legacy-row');
        expect(legacy[0].uid).assertEqual('uid-legacy');
        expect(legacy[0].dead).assertFalse();

        await seedRawPreference(DEBT_KEY,
          '[{"pairId":"kept","uid":"uid-a","dead":0},'
          + '{"pairId":"terminal","uid":"uid-b","dead":1},{"pairId":"no-uid"}]');
        const many: PendingCloudUnpair[] = SettingsStore.getPendingCloudUnpair();
        expect(many.length).assertEqual(2);
        expect(many[0].pairId).assertEqual('kept');
        expect(many[0].dead).assertFalse();
        expect(many[1].pairId).assertEqual('terminal');
        expect(many[1].uid).assertEqual('uid-b');
        expect(many[1].dead).assertTrue();

        await seedRawPreference(DEBT_KEY, '[{"pairId":"half-written"');
        expect(SettingsStore.getPendingCloudUnpair().length).assertEqual(0);

        const next: PendingCloudUnpair = { pairId: 'written-back', uid: 'uid-c', dead: true };
        await SettingsStore.savePendingCloudUnpair([next]);
        expect((await readRawPreference(DEBT_KEY)).startsWith('[')).assertTrue();
        const back: PendingCloudUnpair[] = SettingsStore.getPendingCloudUnpair();
        expect(back.length).assertEqual(1);
        expect(back[0].pairId).assertEqual('written-back');
        expect(back[0].dead).assertTrue();
      } finally {
        await seedRawPreference(DEBT_KEY, had);
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
