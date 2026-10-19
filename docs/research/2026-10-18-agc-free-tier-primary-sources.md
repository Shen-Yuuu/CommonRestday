# AGC 免费配额与容量估算：官方资料核查

问题基准日期：2026-10-18（Asia/Shanghai）。本次跨日资料核查完成于 2026-10-19；只记录本次实际能读取的华为官方资料，不将第三方转载作为定价依据。未登录、查看或修改用户的 AGC 控制台，未查看任何密钥或账单。因此下列是公开标准配额，不等于已经验证该项目的实际套餐、剩余额度或专属权益。

## 结论

- 免费云服务没有一个可直接换算的固定“注册人数上限”；决定容量的是每日计费数据库读写、每月函数调用和 GB-s、出站流量、累计存储及峰值连接等维度中最先用尽的一项。
- 本项目同步的是日程快照和计划等结构化密文，不是媒体文件；应优先测量 CloudDB 与云函数消耗，不要用云存储的 GB 数直接除以用户人数。
- 免费档配额用尽会造成该服务在剩余周期不可用；不是无限免费，也不应在没有升级付费档的情况下假定超额自动正常服务。华为官方说明升级付费档后按超额实际用量计费，免费额度仍先抵扣。[AGC 服务定价与订购，更新 2026-04-09](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/agc-service-billing-0000001058092595)

## 1. 云函数 Cloud Functions

公开计费页更新于 **2024-11-06**，本次在官方文档页面实际渲染后读取。普通网页文本抓取曾超时/空白，不代表页面不存在；以下数字来自渲染页面。[云函数计费说明](https://developer.huawei.com/consumer/cn/doc/appgallery-connect-Guides/agc-cloud-function-price-0000001211271102)

| 维度 | 免费配额 | 付费档超额价格（人民币） |
| --- | --- | --- |
| 请求量 | 1,000,000 次/月 | 1.9378 元/1,000,000 次 |
| 内存时长 | 400,000 GB-s/月 | 1.421 元/10,000 GB-s |
| 函数内外网出方向流量 | 5 GB/月 | 1.2918 元/GB |

上述各行数值及单位均见[官方云函数计费表](https://developer.huawei.com/consumer/cn/doc/appgallery-connect-Guides/agc-cloud-function-price-0000001211271102)。每次触发执行计一次调用；内存时长按函数实例内存乘运行时长计算；“函数内出流量”在原文具体指函数代码访问公网产生的出方向流量，不能未经核查将所有手机收到的响应字节等同于该 SKU。

官方函数配置说明中，内存配置档为 **500、1000、2000、4000 MB**，实例并发参数范围为 1–10000。此范围是配置能力，并不保证免费项目有相同实际并发吞吐。[创建并配置函数，更新 2026-02-27](https://developer.huawei.com/consumer/cn/doc/appgallery-connect-Guides/self-constructed-create-and-config-func-0000001713088141)

未查明项：本次所读公开计费表没有解释运行时长取整粒度、MB/GB 换算基数、实例并发时账单如何归集。估算时应注明内存是假设值，用控制台实际计量结果校准，不能把客户端“等待了 3 秒”直接视为函数实际执行 3 秒。不要套用华为云 FunctionGraph、Firebase、腾讯 CloudBase 的计费粒度。

## 2. 云数据库 for Object / CloudDB

官方计费页更新于 **2025-03-05**；以下为本次在渲染后的官方页面实际读到的表格。[云数据库计费说明](https://developer.huawei.com/consumer/cn/doc/appgallery-connect-Guides/agc-clouddb-price-0000001256815629)

| 维度 | 免费配额/档位限制 | 付费档超额价格/档位限制 |
| --- | --- | --- |
| 数据存储 | 1 GB/月 | 1.1627 元/GB，按月计费 |
| 网络出站流量 | 10 GB/月 | 0.7751 元/GB |
| 对象读取 | 50,000 次/天 | 0.3876 元/100,000 次 |
| 对象写入 | 20,000 次/天 | 1.1627 元/100,000 次 |
| 对象删除 | 20,000 次/天 | 0.1292 元/100,000 次 |
| 同时客户端连接数 | 最大 150 | 最大 200,000 |

表格全部数值和计费项说明见[官方 CloudDB 计费表](https://developer.huawei.com/consumer/cn/doc/appgallery-connect-Guides/agc-clouddb-price-0000001256815629)。存储包含用户数据以及开发者对象类型的主键、索引和字段等；出站流量包含查询/订阅返回消息体、控制台导出对象类型与数据等。存储 1 GB/月不是每月赠送可累积的新增 1 GB；保留的密文历史、回执、对象索引会持续占容量。

**150 是同时客户端数据库连接数，不是 150 个注册用户或 150 DAU。** 本项目主要通过云函数 Server SDK 操作数据库，不能未经官方确认将每位 App 用户当作一个持久 CloudDB 连接。对于该 Server SDK 架构，连接计数、连接复用与实例扩缩容的实际归属本次没有查到足够细的官方计费说明，需实测或提交 AGC 工单确认。

**读取计量的不确定性：**原文只定义“对象读取”为“read 操作次数”、“对象写入”为“upsert 操作次数”、“对象删除”为“delete 操作次数”。本次未找到官方明确说明一个批量查询返回 N 个对象、空查询、事务重试、订阅首次读取及增量通知分别记多少次。因此不可把“一次 SDK query 调用 = 一次计费读取”当成已证事实，也不能套 Firebase 的按 document 数计费。在容量公式中使用“计费读取单位/人/日”，通过控制台用量差值校准。

官方云函数和 CloudDB 计费页均有“某工具类 App 月新增下载近一万，免费额度支持日常调用”的示例；这不是对任何 App 的固定用户承诺，不能用于本项目用户容量结论。[云函数示例](https://developer.huawei.com/consumer/cn/doc/appgallery-connect-Guides/agc-cloud-function-price-0000001211271102)、[CloudDB 示例](https://developer.huawei.com/consumer/cn/doc/appgallery-connect-Guides/agc-clouddb-price-0000001256815629)

## 3. 作用域、周期、超额行为

- 官方入口为“开发与服务 → 选择项目 → 项目设置 → 项目套餐 / 项目配额”，套餐列表展示当前项目下套餐。因此容量按**所选 AGC 项目的服务套餐**评估；不是给每台设备、每对伴侣或每个云函数各发一份额度。同一项目下测试和正式应用若共用这些云资源，应把用量合计纳入评估。[服务定价与订购，更新 2026-04-09](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/agc-service-billing-0000001058092595)
- 同一项目启用多个数据处理位置时，项目配额页显示各位置配额用量总和。公开页没有承诺创建更多位置就能复制一份免费额度。[查看项目配额章节](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/agc-service-billing-0000001058092595#section12556205315)
- 官方规定配额统计通常存在不超过 **1 小时**的延迟，配额页面与账单不一致时以账单为准。[查看项目配额章节](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/agc-service-billing-0000001058092595#section12556205315)
- CloudDB 读写删是每日额度，函数调用/内存时长、各流量及数据库存储是每月项目；不要用“每月读 150 万”掩盖某一天超过 5 万的中断风险。[CloudDB 计费表](https://developer.huawei.com/consumer/cn/doc/appgallery-connect-Guides/agc-clouddb-price-0000001256815629)、[云函数计费表](https://developer.huawei.com/consumer/cn/doc/appgallery-connect-Guides/agc-cloud-function-price-0000001211271102)
- 免费档用尽后，可以升级按量付费，否则等下周期恢复前服务不可用。升级立刻生效；降级后如果当前用量已经超过免费额度，服务会不可用，且计费资源可能被删除。不要为了“省钱”直接降级已超额项目。[服务定价与订购](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/agc-service-billing-0000001058092595)、[CloudDB 降级注意](https://developer.huawei.com/consumer/cn/doc/appgallery-connect-Guides/agc-clouddb-price-0000001256815629)
- 官方订购页指出中国站点以外个人开发者目前无法订购付费档。中国区项目仍需以具体账号实际控制台支持为准，不从这一限制反推出已核实用户账号可订购。[升级到付费档章节](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/agc-service-billing-0000001058092595#section1337763420106)

## 4. 如何估算本项目可承载的人数

这是方法，不是容量压测或服务保证。定义每日活跃人数 D，每人每日函数调用 F，平均每调用计费内存 G（GB）和执行时长 T（s），每日 CloudDB 计费读取 R、写入 W，固定后台调用数及 GB-s 为 B、H。取 30 天作示例月份：

```text
函数调用约束：D <= (1,000,000 - B) / (30 × F)
函数内存约束：D <= (400,000 - H) / (30 × F × G × T)
数据库每日读取约束：D <= (50,000 - 后台每日计费读取) / R
数据库每日写入约束：D <= (20,000 - 后台每日计费写入) / W
```

另须同时满足出站流量、存储、峰值并发/限流及删除等约束。配对用户以两个人计，不把“1000 人”和“1000 对”混写；完全离线且不使用云能力的用户不能简单等同于云日活。

固定后台轮询和 CloudDB 触发的 worker、通知补送、重复校验、重试均要计入。容量测量应包含成功、失败和离线重试场景；每次界面刷新可能引起多个云函数和数据库操作。未来上线前用小规模真实用户一周数据估计人均计量，并预留峰值和增长余量。

## 5. 本次没有确认、不应强行报数字的项目

- **匿名认证**：未成功读取用户当前适用的最新认证计费页面，不能证明无上限免费，也不能把短信验证码配额当成匿名认证人数额度。待查看该项目“项目套餐”中的认证服务 SKU 或向官方提单。待核查官方入口：[认证服务计费说明](https://developer.huawei.com/consumer/cn/doc/app/agc-help-auth-pricing-0000002236496822)。
- **Push Kit**：本次未完成当前 HarmonyOS 推送“如何收费”及 WORK 场景的限频/总量原文核查，不能将已获工作提醒权益等同于无限推送、必达 SLA 或免费后端。即使通道费用为零，触发通知的云函数/CloudDB/外网调用仍可能计量。官方入口：[Push Kit 文档目录](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/push-appendix)。
- **实际剩余额度、定价优惠和代金券**：没有控制台读取证据；以用户目标生产项目的“项目套餐”“项目配额”“账单详情”为准。

## 6. 产品边界

本报告核查的是 **AppGallery Connect / Cloud Foundation Kit 的云函数和 CloudDB for Object**，不是个人华为云空间，也不是华为云 FunctionGraph、RDS 或 GaussDB 的试用套餐。官方端云一体化介绍明确以 Cloud Foundation Kit 为底座并分别使用这些 AGC 服务的配额。[端云一体化业务介绍，更新 2025-03-03](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-v5/agc-harmonyos-clouddev-overview-V5)

该旧版本介绍页同时仍有过时的“模拟器不支持”等约束，故这里只引用其产品关系，不用其旧约束断言当前 SDK 行为；容量核心依据是上面的独立现行计费页面。
