# 真机反馈修复与角色校对 · 2026-10-17

本记录对应素材统一/界面诊断阶段；随后新增的表情和互动分层验收见 `2026-10-17-companions-layered.md`。

## 已改动

- CoTimeView：标题与角色组成底对齐的一行，备注独立下一行。CompanionsDuo 热区高 44vp、绘制高不超过 44vp，底边轴缩放；原动画生命周期不变。
- DayShiftSheet：保存/自定义确认操作独立于滚动正文；底部内边距为实测窗口底部避让 vp + 12vp。具名 avoidAreaChange 监听在窗口/Ability 销毁时释放，回前台重新读取。只测量窗口，不新增权限。
- 发送计划：失败后留下可读反馈和白名单诊断，不再只有瞬时 toast。未决请求冻结编辑，按钮改为“核实 / 重试”；复用原 requestId 和已有密文。成功核实 PROPOSE 后恢复列表定位信号；核实的是之前 ACCEPT/AMEND 时不冒充“新邀请已发出”。
- Gateway：区分连接、加密、发送凭据保存、RPC、回包、核实等阶段；仅提取数字 SDK 码与格式受限的云诊断 UUID。HUKS init/finish 保留安全数字错误码并正确 abort 未完成会话。
- 明确的日程冲突仍可编辑；状态查询的 FORBIDDEN 不是原事务失败证明，不能删除未决请求。没有改动服务端、配对数据或云端配置。

## 角色资源边界

用户最新要求：造型一致，神态/动作无需照搬原图，允许补出身体。此前改掉脸型、眼睛和毛发感的生成稿不使用。

新校对图：`docs/prototype/assets/companions-identity-expressions-review-2026-10-17.png`。
图像编辑工具以原已选 B 图为参考，探索三组互动；完整提示词见 `docs/design/companions-identity-expression-prompt-2026-10-17.md`。
它仍是静态合成校对稿，有裁切底边残片，**不是八套表情分层或可直接上线的动画资源**。
用户随后明确确认校对稿造型一致，已按此生成 `bubu_peek.png`、`xiuxiu_peek.png`、`xiuxiu_sleep.png`，分别接入 ConfirmDialog / WindowDetailSheet / StatePanel，旧 SVG 文件保留可回退。
三份 PNG 使用 Contain 等比显示、有限 sourceSize 解码、不加图片节点阴影。PNG 独立通道检查：真正透明区域 >15%，近不透明区域 >25%，中间透明度像素仅 0.62% / 0.69% / 0.67%；四角完全透明。提供者把图内 alpha 输出为 253/254，故近不透明阈值为 250，不误报成外围光晕。
独立表情/耳动和四段叙事动画尚未完成；三张静态图不等同于 15 个分层资源。
已选原图 SHA256 保持 `1E7B9EB98024304869B63FAECA1B539EA3DA10C25BABA2D2087A802CDABAA007`。

## 已验证范围

- `real-device-feedback-regression.mjs` 执行生产控制方法和 Gateway/UseCase，隔离云/密钥/存储/窗口端口：seal、wire read/save、RPC、decode、resolve 错误；白名单脱敏；原请求核实/重发；确定本地冲突不锁表单；非 PROPOSE 核实不误报创建；导航 px→vp 与监听注销。
- `shared-plan-secure-regression.cjs`：38 项通过。使用 Node 加密适配器，不代表设备 HUKS 已测试。
- `visual-motion-regression.mjs`、`companion-motion-regression.mjs`、`plan-time-list-regression.cjs` 均通过。
- `companion-assets-regression.mjs`：独立 PNG 解码检查 alpha 与新资源的正式接线；`ui-refinement-regression.mjs` 保留无矩形图片阴影/底框、位移/穿透等原有约束。
- ArkTS 技能脚本完成 `ohpm install --all` 与 `assembleApp`，编译成功。首次编译发现诊断模型内联类型不符合 ArkTS，改为命名接口后通过。
- 浏览器隔离 session 检查原型：390 浅色与 360 深色、暂停待机时，标题行 DOM 底边及绘制容器底边均为 228px，热区高 44px。此项是布局盒测量，不是中文字体墨迹或原生设备验收。新增两张 baseline 截图，未覆盖原截图。
- 另外生成 `companions-assets-light-2026-10-17.png` / `companions-assets-dark-2026-10-17.png`，三份新资源在 96×88 的预览容器中已加载，人工检查浅深背景无明显矩形底框或外部光晕。它是浏览器小尺寸素材检查，不是原生确认弹窗截图。

## 仍需手机验证

最终门禁：`node tools/verify.mjs --steps=offline,debug,release` 全部通过。closed/open 两档分别 368 passed / 0 failed，typecheck 0 errors；Debug 280 WARN、Release 278 WARN（基线均 289，未修改基线）。本次不部署云对象、不改证书/Profile、不运行清数据或解绑。

1. 用本次构建覆盖安装，**不用卸载/清数据/解除配对**。
2. 打开当日班次安排，正文滚到最后，检查保存和自定义确认按钮是否始终在小白条上方；大字体、键盘弹出时也检查。
3. 发送一次未来计划邀请。若仍失败，直接截弹窗底部反馈或“计划 → 核实 / 重试”后的诊断；无需日志、Token 或请求内容。
4. 检查双方计划卡片及确认状态；断网重试不应创建重复邀请。

不能依据当前隔离回归断言用户手机的邀请根因已确定或云链路已修复。新诊断用于区分失败发生在加密之前、云请求阶段或回包校验阶段。
