# AGC 用户增长后的额度扩充操作

核查日期：2026-10-19（Asia/Shanghai）。范围：当前项目使用的 AGC 云函数、CloudDB for Object。只读研究，未进入或修改用户后台、未改变源码。复用本次已实际读取的华为官方渲染文档；本次网页抓取器再次超时不改变先前已读证据。

## 可以据此指导用户的步骤

1. 登录 AppGallery Connect，选择“开发与服务”，进入**正式 App 当前真正调用的 AGC 项目**，不要误升测试项目。打开“项目设置 → 项目配额”，先确认云函数、CloudDB 各 SKU 的已用量；多个数据处理位置的用量在这里合计，统计通常延迟不超过 1 小时，最终以账单为准。[服务定价与订购，更新 2026-04-09](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/agc-service-billing-0000001058092595#section12556205315)
2. 在同一“项目设置 → 项目套餐”页查看当前服务的免费档套餐，展开云函数、云数据库相关套餐，分别确认服务 SKU、免费额度和超额价格，对所需套餐点击“升级到付费档”，阅读确认提示并确认。如果一个套餐组合了多个服务，以该套餐实际包含的 SKU 为准；不要假设一次升级自动覆盖所有服务。[官方升级步骤](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/agc-service-billing-0000001058092595#section1337763420106)
3. 官方明确：升级前要开通付费服务；使用收费服务需要结算账户及付费服务协议，协议缺失或不是最新版会要求签署。界面将默认币种设为人民币。按页面指引完成账户/协议流程，保证有效付款来源或余额充足。**没有充分证据证明必须先充值某个固定金额才能点击升级**，因此不要给出臆造的最低充值要求。[服务定价与订购](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/agc-service-billing-0000001058092595)、[AGC 付费服务协议，更新 2025-04-28](https://developer.huawei.com/consumer/cn/doc/PaidService)
4. 升级完成后回到“项目套餐”核对已变成付费档。官方说明套餐升级**立即生效**；并非购买一台新服务器，也不因这一套餐操作而要求修改 App 云接口、重新配对或迁移数据库。最后一句是基于“更改同项目服务订阅方式”的流程作出的技术判断，特定账号异常仍需以控制台为准。[官方升级步骤](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/agc-service-billing-0000001058092595#section1337763420106)
5. 官方建议尽快前往“账户中心 → 费用 → 消费提醒”设置阈值，也设置账户余额不足提醒。结合“项目配额”和账单持续监测，而不是等免费档停用后再处理。提醒不是已核实的硬性消费封顶；不能保证收到提醒即自动停止扣费。[服务定价与订购](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/agc-service-billing-0000001058092595)

## 升级后怎样计费

- 升级不是把免费额度取消：官方说明只对周期内**超出免费配额的用量**按量付费。服务运行靠同一个项目现有资源延续，不需通过新建项目来“叠免费额度”。具体实际套餐/专属优惠仍看该项目控制台。[官方按量付费定义](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/agc-service-billing-0000001058092595)
- 云函数独立计量调用次数、GB-s、函数代码访问公网的出方向流量；CloudDB 独立计量存储、网络出站、读/写/删除等。数据库读写是每日配额，其他主要项目是每月，不能只看总调用次数。[云函数计费](https://developer.huawei.com/consumer/cn/doc/appgallery-connect-Guides/agc-cloud-function-price-0000001211271102)、[CloudDB 计费](https://developer.huawei.com/consumer/cn/doc/appgallery-connect-Guides/agc-clouddb-price-0000001256815629)
- CloudDB 当前公开收费表把免费档同时客户端连接最大 150、付费档最大 200,000 列为不同档位限制；这不是承诺 App 能同时在线 20 万人，也没有证明本项目 Server SDK 每用户对应一连接。仍需验证读写吞吐、连接模型与函数并发。[CloudDB 计费表，更新 2025-03-05](https://developer.huawei.com/consumer/cn/doc/appgallery-connect-Guides/agc-clouddb-price-0000001256815629)
- 服务有代金券时，官方说明付费档下优先用代金券抵扣，再扣账户费用。不能保证用户账号当前有券，也不能按“有券”设计长期成本。[云函数计费页](https://developer.huawei.com/consumer/cn/doc/appgallery-connect-Guides/agc-cloud-function-price-0000001211271102)

## 钱能解决的额度与钱不能直接解决的限制

1. **计费额度**：调用数、GB-s、流量、存储等周期性免费额度用尽，升级按量付费可让服务继续计量使用；不等于无限资源或自动提高所有技术限制。
2. **技术限制**：函数内存档、超时、实例并发配置、数据库对象/事务/索引限制、接口限流等，要分别核查。官方函数配置当前列内存 500/1000/2000/4000 MB、实例并发配置范围 1–10000，但该可填范围不是已验证免费/付费项目都能实现的实际吞吐或独占资源保证。[创建并配置函数，更新 2026-02-27](https://developer.huawei.com/consumer/cn/doc/appgallery-connect-Guides/self-constructed-create-and-config-func-0000001713088141)、[云函数使用限制，更新 2025-04-25](https://developer.huawei.com/consumer/cn/doc/appgallery-connect-Guides/agc-cloud-function-restriction-0000001058641770)
3. **扩限申请**：如果目标超出公开上限或碰到账号/区域的网关限额，应向华为开发者官方提单，并附项目 ID、区域、目标峰值、函数名、监控截图与错误码；不要贴私钥/Token。**本次未核实某一技术限额有可自助调整入口、官方审批标准或承诺提升范围**，不能保证后台改数字即可扩容。
4. **应用效率**：付费仍按浪费的请求计量；缓存、增量同步、去重、退避重试、独立通知 worker、历史归档可改善成本与速度，但不是本次已实施修改，也不能代替真实负载测试。

## 尚未核实的边界

- 用户生产项目的套餐实际名称/价格、付款方式、余额及是否有特别合同；控制台可能出现按账号不同的入口文字。
- “先充值”在该账号的界面是否硬性阻止升级、最小充值额、可选支付渠道和消费硬封顶机制。
- 函数时间计费取整、MB/GB 换算，以及 CloudDB 批量读写/事务重试的精确计费粒度；不能用其他云产品的规则代替。
- Push WORK 场景权益、推送频控和技术扩限不是升级 CloudDB/云函数付费档就自动获得的功能。

配额数字、估算公式与原始链接参见[前次免费额度核查](./2026-10-18-agc-free-tier-primary-sources.md)。
