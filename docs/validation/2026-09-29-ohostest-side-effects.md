# ohosTest 副作用与执行边界（2026-09-29）

`node tools/verify.mjs --steps=ohostest` 只编译测试包，**没有运行设备用例**。当前 `List.test.ets` 装配 `Ability.test.ets` 与 `UpgradeMigrationTest.ets`；两套都会接触应用真实沙箱，不能在保存着正式配对／班表的 5555 上运行。

| 用例／阶段 | 真实写入对象 | 正常退出仍可能留下什么 | 可在 5555 执行？ |
| --- | --- | --- | --- |
| `Ability` 启动、首页读数 | 初始化 RDB、种子班次、窗口缓存 | 计算缓存与种子数据 | 否；全量套件不能只挑这两格来声称通过 |
| `plan_occupies_explains_reschedules_and_frees_the_slot` | 计划、临时班次类型、单日覆盖、窗口缓存；日历与提醒走测试注入端口 | 计划取消后为 `CANCELLED` 行；若断言或进程中断，临时班次／覆盖也可能残留 | 否 |
| `same_id_coexists_for_both_owners` | 我／TA 两侧的 `keytest` 循环模板与班次类型 | 正常完成会还原模板并删除测试班次；中断会覆盖同 ID 记录 | 否 |
| 四条恢复标记／普通启动用例 | 固定 `plan_restore_test` 计划行、恢复标记、快照／日历投影状态 | `afterAll` 将测试计划标为 `CANCELLED`，不会删掉历史行 | 否 |
| `pairing_reset_lands_on_real_preferences` | 真实 `crd_settings` 的 `pair_key`、`pair_id`、配对状态、伴侣 uid、快照版本 | 现已在 `finally` 还原进入前的 `pairId` 等读数；若进程在 `finally` 前崩溃仍可能留假值 | 否 |
| `cloud_debt_history_shapes_read_from_real_preferences` | 真实 `pending_cloud_unpair` 键 | `finally` 还原原文；进程中断则可能把真实欠账换成测试串 | 否 |
| `newer_schema_is_never_rewritten` | `SCHEMA_VERSION_KEY` 与 RDB 重开 | 正常 `finally` 复原本包版本；中断可能把版本留在 99 | 否 |

执行前置：准备**两台可丢弃的 API 26 实例**，在独立测试身份／测试 pair 下运行；第三台拒绝测试需要再加入第三台。不要把 5555 与新实例配成测试对。全量执行前记录 bundleName、测试包版本、两台的 `pairId` 指纹（不要把完整值抄进日志）、RDB 相关表行数；执行后核对并留截图／日志。测试即使全绿，也不能据此保证无残留；实例只装测试数据，执行后按可丢弃环境处置。

本轮只做静态审计、`pairId` 恢复修补与 ohosTest **出包**。协议 §11、AO 设备计划和 `docs/testing-checklist.md` 中的实际设备格仍保持未验。
