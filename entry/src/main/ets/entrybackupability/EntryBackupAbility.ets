import { BackupExtensionAbility, BundleVersion } from '@kit.CoreFileKit';
import { Db, MigrationRunner, PAIR_NONE, ScheduleRepo, SettingsStore } from 'data';
import { Logger } from 'commons';

const TAG = 'CrdRestore';

/**
 * 备份/恢复扩展（阶段 6 Task 6.1）。
 *
 * 备份阶段什么都不做：八张表和 Preferences 都在沙箱默认目录里，系统整体备份自然覆盖，
 * 应用自己再打一份只会造出两套"用户数据"。
 *
 * 恢复阶段要处理的是"数据回来了，但这台机器不是原来那台"：
 * 1) 结构版本可能落后于本包（旧装机备份 → 新装机恢复）：Db.init 里的 MigrationRunner
 *    会在打开库时就地补齐，恢复流程本身不写迁移语句；
 * 2) 只在本机成立的事实必须作废（系统日历事件 id、提醒 id、云端同步状态）：这里只置
 *    "待清理"标记，真正的 UPDATE 由下一次启动的 MigrationRunner.finishRestore 消费——
 *    同一套口径不允许在恢复回调里再实现一遍；
 * 3) 长期密钥在 HUKS 里，而 HUKS 不参与备份，恢复后必然解不出对方快照：配对事实直接
 *    抹成"未配对"，界面回到重新配对，而不是留一个假的 PAIRED 等用户撞上解密失败。
 *
 * 全程 best-effort：恢复回调抛错会被框架记成"恢复失败"，用户看到的是数据没回来，
 * 比"数据回来了但状态是旧的"更糟，所以两段各自兜底、失败只进日志。
 *
 * 框架的两条约束决定了这里的分工（华为《应用数据迁移适配》V14）：onRestore 内的异步操作
 * 必须等完（所以两段都 await），而单应用的数据迁移窗口只有 15 分钟。扫全表的活不放在这里做，
 * 这里只留一个标记，第一次正常启动去兑现。
 */
export default class EntryBackupAbility extends BackupExtensionAbility {
  async onBackup(): Promise<void> {
    Logger.info(TAG, 'onBackup: sandbox default backup covers RDB and preferences, nothing to pack');
  }

  async onRestore(bundleVersion: BundleVersion): Promise<void> {
    Logger.info(TAG, 'onRestore from bundle ' + bundleVersion.code + ' / ' + bundleVersion.name);
    await this.markDbForProjectionCleanup();
    await this.dropDeviceLocalHandles();
  }

  /**
   * 打开恢复过来的库（顺带完成结构升级）并落下"待清理投影"标记。
   * 只置位不清理：清理在启动路径上做，中途失败标记还在，下次启动接着补，
   * 不会把"清了一半"当成"已经清了"。
   */
  private async markDbForProjectionCleanup(): Promise<void> {
    try {
      await Db.init(this.context);
      await ScheduleRepo.setMeta(MigrationRunner.RESTORE_PENDING_KEY, MigrationRunner.RESTORE_PENDING_ON);
      Logger.info(TAG, 'restore marker set; projections demoted on next launch');
    } catch (e) {
      // 库打不开（恢复早期加密区尚未解锁等）：日历/提醒状态会短暂保留来源设备的值。
      // 用户侧的兜底是计划卡片上的"写入日历"重试入口；这里绝不谎报已经清理。
      Logger.warn(TAG, 'restore marker failed: ' + (e as Error).message);
    }
  }

  /**
   * 抹掉随备份过来但在这台机器上不成立的配对凭据。
   * 伴侣档案（本机代录的那份）是用户输入、不是设备投影，保留。
   * 计划行的日历/提醒句柄不在这里清：RESTORE_PENDING 标记会让首启把它们降级重挂（Task 6.1）。
   *
   * HUKS 别名不在备份范围内（密钥材料出不了这台设备），所以恢复后 `hasPairKey(pairId)` 必然为假：
   * 这里清的是 Preferences 里那份"声称已配对"的标记，顺带把旧原型残留的明文 `pair_key` 也带走。
   * 对方快照的信封（`partner_snap_cache`）也在清理之列：它跟着备份过来了，可这台机器上没有别名
   * 解得开它——留着就是一块永久读不出来的死数据（读侧的 pairId 比对只是兜底）。
   * 少清这一格，新机界面就会对着一个解不开的 pairId 报"正在同步"。
   */
  private async dropDeviceLocalHandles(): Promise<void> {
    try {
      await SettingsStore.init(this.context);
      await SettingsStore.clearPairKey();
      await SettingsStore.savePairId('');
      await SettingsStore.setPartnerSnapVer(0);
      await SettingsStore.clearPartnerSnapCache();
      // 强制首启重算一次：恢复来的窗口缓存可能是旧引擎算的，重算比让它一直准更便宜
      await SettingsStore.setLastRecomputeDay(-1);
      await SettingsStore.setPairState(PAIR_NONE, '');
      Logger.info(TAG, 'pairing handles reset after restore');
    } catch (e) {
      Logger.warn(TAG, 'pairing reset failed: ' + (e as Error).message);
    }
  }
}
