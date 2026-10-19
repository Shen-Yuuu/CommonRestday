# 双角色精简与缺耳修复 · 验证

## 本轮范围

- 用户要求仅保留眨眼、原有点击反馈，并让整体底部更靠下。
- 原先去耳 head + 独立 PathShape 耳爪层在用户模拟器截图中缺失。现改用已确认完整 plate（两耳、两爪都在同一底图内）+ face 0/3；不再依赖这条原生裁切路径。不把尚未运行原生设备的推测单位问题写成已实测原因。
- 保留完整造型，不改素材、不加动作；移除页头对叙事、呼吸、摆耳和伸爪的调用。历史资源/纯数学文件保留，不参与当前页头播放。
- 保持 44vp 槽和 100/112vp 宽度，整体组件 offset y=3vp，不在裁切框内移动底图，避免把脚底再次裁掉。
- 仅两个短计时器调度错相眨眼：兔子 5～8s、熊 7～10s，闭眼 150ms；无待机 Animator / requestAnimationFrame。
- 点击暂停并取消眨眼，原捏压结束后重排；生命周期取消带 epoch 保护，不补播。

## 已验证

1. `node tools/test/companion-motion-regression.mjs`：PASS。真实生产控制器 + 假计时器/Animator，检查两路计时、闭眼恢复、重复调度、过期回调、点击/连点、辅助点击、隐藏、后台、销毁、固定下移和完整 plate 引用。不是原生渲染测试。
2. `node tools/test/companion-assets-regression.mjs`：PASS。透明角、真实 alpha、消费引用检查。
3. ArkTS 技能 `scripts/run.ps1`（ohpm install --all + assembleApp）：BUILD SUCCESSFUL，日志 `../.crdtest/blink-skill-build.log`。未修改签名配置。
4. `node tools/verify.mjs --steps=offline`：ALL PASS，closed/open 各 368 passed / 0 failed，typecheck 0 errors。
5. 隔离 agent-browser session：所有图片加载成功，实际尺寸 scene computed top=3px；完整两耳与爪子在截图可见；点击后恢复 idle，transform=matrix(1,0,0,1,0,0)。窄尺寸/深色留图，随后关闭自用 session。不代表原生设备表现。

截图：`docs/prototype/companions-blink-only-2026-10-17.png`、`docs/prototype/companions-blink-only-narrow-dark-2026-10-17.png`。旧 layered URL 已更新为精简版，浏览器刷新即可查看。

## 仍需原生复核

重新构建运行后，检查两耳齐全和下移 3vp 的观感；停留 10 秒检查眨眼，点击检查反馈，打开 sheet/切页再回来检查无停留闭眼。不需要卸载、清数据、解除配对或重新部署云函数。本轮未连接/操作原生模拟器或手机。
