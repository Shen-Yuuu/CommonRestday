# 计划弹窗休休爪缘贴卡片

用户要求让计划弹窗兔子的爪子扒在下方粉色摘要卡片上，消除悬空距离。

## 调整

- 不改角色图片、96×88vp 尺寸、左右位置、探头动画或点击穿透。
- 原有透明安全带仍为 62vp，保留完整耳朵的窗口空间。
- 增加 `PEEK_CARD_DROP=8vp`，只调整兔子的落位；不挪动摘要、句柄、表单或底部按钮。
- 实际素材 alpha≥200 的爪缘在图片内约 84.29vp；原落点为 sheet 内容顶 22.29vp，而摘要上沿在 27vp，原间隙约 4.71vp。下移 8vp 后爪缘进入粉色卡片约 3.29vp，形成轻搭效果。

## 验证

- `node tools/test/companion-assets-regression.mjs`：PASS。读取生产 PNG 透明度与生产布局常量，约束实际爪缘重叠 2～5vp、耳朵仍在安全带内；本次测得 3.29vp。
- `node tools/test/ui-refinement-regression.mjs`：PASS。约束原尺寸、Contain、无矩形阴影、点击穿透及动画接线不变。
- `plan-form-regression.mjs`、`plan-time-list-regression.cjs`：PASS，计划类型、标题、自定义时间和保存校验未受影响。
- ArkTS 技能脚本（ohpm install --all + assembleApp）：BUILD SUCCESSFUL，日志 `../.crdtest/plan-bunny-contact-build.log`。

这些是素材/布局数学和编译验证，不是原生截图；还需重新运行后观察实际贴边效果。本轮不连接设备、不卸载/清数据、不修改计划或云同步逻辑。
