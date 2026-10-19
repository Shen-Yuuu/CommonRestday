# 两人份 / For Two：HarmonyOS NEXT 商业化一手资料核对

调研基准日：2026-10-09，中国大陆。使用华为官方公开页面进行只读调研；没有登录开发者后台，没有配置账号、开通服务或修改应用代码。已知项目已完成双端云配对及共同计划确认流程测试，目前没有 IAP 实现。

## 可确认的结论

| 问题 | 结论 | 直接来源与文档日期 |
| --- | --- | --- |
| 可否一次付费永久解锁 | 可以。HarmonyOS SDK 的 IAP Kit 产品页明确支持非消耗型商品，一次购买且不过期；适合去广告、专业版等长期数字权益。 | [IAP Kit 产品页](https://developer.huawei.com/consumer/cn/sdk/iap-kit)，页面未显示更新时间，2026-10-09 检索；[配置应用内资费类型和应用内商品](https://developer.huawei.com/consumer/cn/doc/App/agc-help-release-app-goods-0000002278981442)，更新 2026-06-25 11:52。 |
| 可否订阅 | 可以。IAP Kit 支持自动续期订阅，取消后当期结束不再续费；AGC 商品配置还明确列出非续期订阅，可售卖到期不自动续费的一段服务。 | [IAP Kit 产品页](https://developer.huawei.com/consumer/cn/sdk/iap-kit)，日期未显示；[商品配置](https://developer.huawei.com/consumer/cn/doc/App/agc-help-release-app-goods-0000002278981442)，2026-06-25。 |
| 商品何时可以上线交易 | 首个数字商品或新增商品类型需要关联新的应用版本提交审核；沙盒可以在正式审核前测试，生产商品须审核通过。 | [数字商品服务常见问题](https://developer.huawei.com/consumer/cn/doc/doccenter-distribution/faq-0000002417214845)，更新 2025-11-07 07:36；[商品配置](https://developer.huawei.com/consumer/cn/doc/App/agc-help-release-app-goods-0000002278981442)，2026-06-25。 |
| 支付是否只支持华为支付 | 不是。官方 HarmonyOS 5 及以上消费者说明列出华为支付、支付宝、微信支付；支付方式在华为账号的付款与账单中设置。 | [华为应用内支付如何添加付款方式](https://consumer.huawei.com/cn/support/content/zh-cn16010472/)，适用 HarmonyOS 5.0 及以上，页面未显示发布日期，2026-10-09 检索。 |
| 如何收款 | AGC 官方入门说明要求付费应用/内购收入分成开发者开通商户服务并签署商户服务协议；数字商品 FAQ 明确结算收款账户使用商户服务银行账户。 | [AGC 入门说明](https://developer.huawei.com/consumer/fr/doc/app/agc-help-getstarted-0000001100316670)，官方英文正文，更新 2026-03-13 10:01；[数字商品 FAQ](https://developer.huawei.com/consumer/cn/doc/doccenter-distribution/faq-0000002417214845)，2025-11-07。 |
| 云服务有没有免费额度 | 有。HarmonyOS 端云一体化官方指南写明云函数、云数据库、云存储均提供试用免费额度；AGC 付费服务协议说明限额免费与按实际用量付费两种方式。 | [端云一体化业务介绍](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-v5/agc-harmonyos-clouddev-overview-V5)，更新 2025-03-03 02:06；[AGC 付费服务协议](https://developer.huawei.com/consumer/cn/doc/PaidService)，更新 2025-04-28 09:41。 |

## 华为账号：设备登录和应用登录需要分开判断

HarmonyOS 原生 IAP 的官方订阅接入流程要求先调用 `queryEnvironmentStatus`，检查当前已登录的华为账号服务地；失败时将 IAP 功能设为不可用。消费者付款方式文档也将支付设置绑定到华为账号。因此商业设计应把设备上可用的华为账号视为 IAP 购买环境的前提，不能承诺完全匿名完成华为 IAP 交易。[订阅接入流程](https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V14/iap-integrate-subscription-V14)（HarmonyOS API 14 官方文档，更新 2025-05-20 08:43）；[付款方式说明](https://consumer.huawei.com/cn/support/content/zh-cn16010472/)（HarmonyOS 5.0 及以上，无页面日期）。

这不能直接推出“必须在两人份里新增 Account Kit 华为账号登录按钮”。本次没有找到普通工具应用因接入 IAP 就必须使用 Account Kit 作为应用自身账号体系的官方强制条款。当前配对身份、应用用户身份、购买人的华为账号需要在权益设计中明确映射，但具体实现不在本次调研范围。

非消耗型权益的恢复查询 API、不同设备恢复条件及未登录时的准确错误码：**尚未完成官方 API 正文验证**。已定位 [IAP ArkTS API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/iap-iap)、[IAP 错误码](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/iap-error-code)、[权益发放指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/iap-delivering-products-V5)，但网页工具多次只返回页面框架或超时，文档日期未可靠取得。论坛中的 `NONCONSUMABLE + CURRENT_ENTITLEMENT` 示例和镜像中的 `ACCOUNT_NOT_LOGGED_IN` 不能替代官方 API 验证；尤其不能照搬旧 Android HMS 的 `obtainOwnedPurchases` 或凭非官方文章假定存在 `restorePurchases`。

“一人购买、情侣双方共享”是两人份自己的商品权益规则。本次没有验证华为为该应用自动提供情侣共享或家庭共享。需说明权益归购买人还是当前配对关系，以及解除配对、换伴侣、退款之后如何变化。

## 个人开发者主体与资质

华为中国开发者联盟允许个人开发者实名认证，资料依据认证方式包括姓名、身份证、人脸或个人银行卡。[实名认证介绍](https://developer.huawei.com/consumer/cn/doc/start/itrna-0000001076878172)（更新 2026-04-22 03:40）。官方商户服务协议公开模板也存在个人开发者在中国大陆分发产品/服务的个人所得税条款，因此不能笼统断言商业化一律必须企业主体。[商户服务协议模板](https://terms-drcn.platform.dbankcloud.cn/agreementservice/developer/getAgreementTemplate?agrType=1003&country=cn&language=zh_cn&version=2026031101)（URL 版本标识 2026031101；页面实际签署/生效日未验证）。

但个人实名认证成功不等于本应用已获数字商品服务准入。本次没有核实该开发者账号的商户审核状态、税务/银行资料、数字商品协议签署或应用资质。应在实际后台确认个人主体对本应用、所选数字商品类型的服务开通资格。相关官方操作入口：[商户服务](https://developer.huawei.com/consumer/cn/doc/start/merchant-service-0000001053025967)（正文抓取不稳定，日期未验证）；[HarmonyOS NEXT 数字商品服务配置](https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V14/store-iap-config-agc-V14)（搜索可读段明确要求开通该应用的 IAP Kit NEXT 开关并激活服务，日期未可靠取得）。

应用资质还取决于功能类别。2026 年审核指南 11.4 对银行金融、医疗保健等受严格管控的应用明确要求法律实体；这不能用来判定普通情侣排班工具必须企业主体。是否属于社交/婚恋类别、是否存在聊天或公开内容，以及应用备案、隐私条款、用户注销等材料，应按最终功能及上架分类核对，不能从“只有两人配对”推定全部豁免。[应用审核指南](https://developer.huawei.com/consumer/cn/doc/app/50104)（更新 2026-09-22 09:52）。

## 付费下载、内购分成及税费

官方消费者文档在 HarmonyOS 5 及以上的范围内提及付费下载应用，说明平台存在该类商品；但本次未核实两人份在当前中国大陆个人开发者后台可选择的付费下载配置、定价档位及 DRM 配套，不能把 Android 付费下载接入文档当作本项目已具备的发行路径。[退款说明](https://consumer.huawei.com/cn/support/content/zh-cn16015264/)（适用 HarmonyOS 5.0 及以上，无页面日期）。

**未验证适用于本账号、本应用的确切平台分成比例、支付通道手续费、结算周期和到手税后金额。** 可公开核实的是数字商品展示/支付价格涉及含税口径，华为按当地税率扣税后分成，最终以对账单为准。[数字商品 FAQ](https://developer.huawei.com/consumer/cn/doc/doccenter-distribution/faq-0000002417214845)（2025-11-07）。不要在商业计划里无依据写 30%、15%、零抽成，或将旧联运促销/激励政策当作 2026 年恒定费率。

用于估算时可以先保留变量：净收入 = 实际收款扣除退款、适用税费和平台/支付费用；具体计费基数和扣除顺序需以签署协议与结算单核实。这是估算方法，不是华为费率承诺。

## 云成本能否可靠评估

目前可以判断“存在免费额度及超额计费机制”，不能可靠给出“两人份每月成本为零”或某固定金额。AGC 协议按资源使用计费，并允许调整服务价格；免费配额耗尽后如不选按需付费，相关服务可能不能继续使用。[AGC 付费服务协议](https://developer.huawei.com/consumer/cn/doc/PaidService)（2025-04-28）。

本次未可靠获取当前中国大陆项目的云数据库、云函数、云存储各项免费额度数值、超额单价、配额计量周期及共享范围。已找到官方 [云数据库计费页](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/agc-clouddb-price-0000001256815629)，但抓取超时，日期/数值均未验证；不能用华为云 RDS、OBS、第三方平台或旧 Android 套餐的数据代替 AGC Cloud Foundation Kit。

正式预算需要该项目当前计费页和实际监控用量：活跃配对数、每对每天云函数调用量、函数时长/内存、云数据库读写与数据大小、网络流量、存储与保留时长。再按对应 SKU 的免费额和超额单价计算，并为重试、订阅/轮询和后台任务保留余量。这是预算建议，未对当前代码进行成本测算。可先在小规模真实使用中记录用量，再讨论永久权益价格是否足以覆盖长期云同步。

## 对当前产品的含义

从已验证的平台能力看，免费体验加一次性专业权益、非续期服务包或自动续期都可作为候选商品模型；选择哪种仍需付费意愿与持续成本证据。非消耗型的“不自动过期”并不等于平台保证应用永远运营，长期云服务义务需要开发者自己定义和承担。

若做自动续费，官方审核要求显著披露服务和价格、用户主动同意、购买支付二次确认，以及提供单次开通选项和便捷退订。不能只因技术上支持自动续费就只提供自动订阅。[应用审核指南](https://developer.huawei.com/consumer/cn/doc/app/50104)（2026-09-22，6.2）。

尚需验证的关键项：个人主体实际准入；该账号最终商业协议及费率；原生 IAP 购买、恢复与退款的沙盒验证；共享权益的归属和解除配对规则；当前 AGC 项目配额及实际用量。以上是后续验证清单，本次未执行开通或实现。
