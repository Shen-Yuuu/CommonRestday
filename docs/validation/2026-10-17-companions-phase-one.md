# 共同休时双角色第一阶段验证

日期：2026-10-17。实现范围见 `docs/plans/2026-10-17-companions-phase-one-design.md`；不是整个深化文档的全部功能完工报告。

## 已实现

- `CompanionsDuo.ets` 接入 CoTimeView 标题右侧；112×56vp，窄内容宽度自动 100×56vp，列表/周历/计划保持下一行。
- 使用用户所选 B 合成图，透明背景、无投影；通过局部显示裁切排除底边残片，原素材像素未修改。
- 2.8 秒整组呼吸 ±1.5%、四段捏压回弹、500ms 连击窗口、最多五下及小幅摇摆；再次按压从现有画面变换续接，800ms 无操作后下一次回到基础力度（无需空转计时器）。
- 触屏 Down 即开始、同一次 Click 不重复计数；鼠标/键盘及没有物理 Down 的辅助激活走相同行为，Cancel 归位。
- 组件内 Animator，不写页面帧状态、不触发重算/刷新/云请求。切 Tab、根页隐藏、应用后台、不可见、模态遮挡、销毁时取消并归位。旧回调通过实例身份闸门拒绝。
- 复用现有系统减少动态效果，停止循环、点击幅度收敛；无新增设置、权限或媒体依赖。

## 自动验证

- RED：先加入回归，因 `CompanionMotion.ets` 尚不存在而失败。
- `node tools/test/companion-motion-regression.mjs`：PASS。实际生产数学函数与组件控制方法，替换 Animator 端口；验证连击/时间边界、缩放上下限、端点、快速中断、迟到回调、重复激活、前后台/根页/组件可见、取消触摸和辅助激活。不是设备帧时间或触控验收。
- ArkTS syntax skill 的 `scripts/run.ps1`：最终 assembleApp BUILD SUCCESSFUL，记录 `E:/desktop/Code/harmony/.crdtest/companions-skill-build.log`。
- 首次编译发现并修正以下完整业务编译诊断（不是忽略类型检查）：
  - `10505001: Property 'Touch' does not exist on type 'typeof SourceType'.` CompanionsDuo.ets:141:39。
  - `10505001: Property 'stopPropagation' does not exist on type 'ClickEvent'.` CompanionsDuo.ets:147:13。
  - `10505001: Property 'Touch' does not exist on type 'typeof SourceType'.` CompanionsDuo.ets:148:39。
  - 本地 SDK 使用 `SourceType.TouchScreen`，阻止冒泡在 TouchEvent 执行，不在 ClickEvent 调不存在的方法。
- 最终 `node tools/verify.mjs --steps=offline,debug,release`：ALL PASS。
  - closed / open：各 typecheck 0 errors、368 Hypium passed / 0 failed，新增 companion 回归也在入口中执行，所有附加测试/静态审计通过。
  - debug：BUILD SUCCESSFUL，281 ArkTS WARN（基线 289）。
  - release：BUILD SUCCESSFUL，279 ArkTS WARN（基线 289）。
  - 未放宽告警基线；记录位于 `E:/desktop/Code/harmony/.crdtest/verify-*.log`。
- 限定已跟踪文件 `git -c core.safecrlf=false diff --check`：PASS。
- 应用 PNG 与用户附件 SHA256 相同：`1E7B9EB98024304869B63FAECA1B539EA3DA10C25BABA2D2087A802CDABAA007`。

## 浏览器视觉检查

独立命名 session `fortwo-companions-phaseone-20261017`（已关闭），无服务器、无外网资源。预览运动参数由 `tools/design/build-companion-preview.mjs` 从生产 ArkTS 纯函数机械转译，不手写另一套数值。

- 390px 手机框：角色槽 112px、无标题重叠、无页面横向溢出、图片自然宽度 1774 且已加载。
- 360px 手机框：角色槽 100px、无标题重叠/横向溢出。
- 实际 360px 浏览器：手机框因评审页留白为 336px，角色槽 100px，无横向溢出/标题重叠。
- 浅/深截图已实际查看，未看到图中底部白色残边；点击显示“第 1 下”，暂停后变换为单位矩阵。
- 预览页 `docs/prototype/companions-motion-2026-10-17.html`；截图同目录 `companions-motion-{light,dark,mobile}-2026-10-17.png`。

## 仍未完成的设计规格

没有交付 15 个 SVG 分层和三份音效。当前是保留已选造型的**合成图第一阶段**，不是独立角色呼吸/相位差、耳朵/爪子微动、八套表情、四段叙事、耳朵滞后或音效/触觉完整实现。

点击回弹使用显式四段平滑插值，不是经过实机调参的物理弹簧。文档中“低于一帧”“等积”“声音与系统音量关系”等不能作为已验证事实。下一阶段交付要求见 `docs/design/companions-b-asset-handoff-2026-10-17.md`。

## 用户在设备上检查

1. 重新运行主项目，打开共同休时；确认页头角色外观、大小和字体缩放下的布局。
2. 连点一次、两次、五次；中途切 Tab 再回来，确认没有残留压扁/循环加速或文字闪动。
3. 打开计划详情/日详情，再返回；退后台再回来，确认暂停和恢复正常。
4. 检查深色主题和系统减少动态效果；特别观察挤压峰值是否被固定边界裁切得过多，以设备手感决定微调。

未安装到模拟器/真机、未做帧耗时测量，未修改云端/签名配置/权限，未提交或发布。生成的构建包不代表上述设备检查已经通过。
