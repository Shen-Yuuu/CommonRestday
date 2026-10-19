# 双角色表情与互动阶段 · 验证记录

> 已被用户后续要求替代：仅保留眨眼和点击，修复缺耳并整体下移 3vp。当前实现与验证见 `2026-10-17-companions-blink-only.md`；本文件四段叙事和独立耳爪仅为历史记录。

## 已实现

- 沿用用户确认造型，位图身体 + 八份独立 SVG 五官 + 从统一画布裁切的耳爪，不是整张图换帧。
- 原生 CompanionsDuo 已使用 CompanionScene / CompanionActor：错相呼吸、双人眨眼、偶发耳动/爪动、四段叙事；角色底边仍在标题行的固定 44vp 槽中。
- 随机等待 30～60 秒，权重 40/25/20/15；同一时刻只运行 ambient 或 squish。点击从当前场景姿态平滑归位，快速连点不中断反馈。
- 页面不可见、sheet 遮挡、退后台、销毁会取消并复位；回来只新排等待，不追播过去动作。不新增声音、震动、设置或权限，不修改云链路。

## 测试证据

- `companion-narrative-regression.mjs`：四条生产时间线逐毫秒采样；有限值、缩放/旋转/脸编号范围；对视 1.8 秒停留；试探停留；结束归位；眨眼边界；试探近爪间距约 3.94vp。
- `companion-motion-regression.mjs`：执行实际组件控制方法，假 Animator 检查单实例、连点、旧回调、离页、后台、遮挡、重现、故事完成间隔、触摸从当前故事姿态接续；不是设备测试。
- `companion-assets-regression.mjs`：RGBA 透明角、文件引用、八份不同 SVG、无白板/脚本/嵌入图；与身体层组合人工检查。
- 原型浏览器已检查默认装配、碰耳、困倦靠肩和试探；保留 assembly / ear / lean / paw-dark 截图。观察到初稿误用了外侧爪，已改为相邻爪并增加间距回归，不以“图层有运动”冒充正确互动。
- SDK 本地声明核实 `PathShape.commands` / `clipShape` / `sourceSize`，ArkTS 技能脚本 compile 通过。首次因组件成员 `width` 与系统方法同名报错，已改名 sceneWidth。
- 最终 `node tools/verify.mjs --steps=offline,debug,release` 全通过：closed/open 两档各 368/0、typecheck 0 errors；Debug 280 WARN、Release 278 WARN（基线 289，未变更）。离线审计曾提示容器 accessibilityLevel(no) 是无效挂点，已移除冗余容器标注，保留每个装饰 Image 的 no 标注后通过。
- 浏览器窄尺寸 100×44，标题行和角色槽的 DOM bottom 都为 270.890625px，所有图片加载成功；它是布局盒对齐测量，不是文字墨迹测量。留存 narrow-dark 截图。
- 故事进行 3.6 秒时点击角色，观察 mode 从 story 经 squish 回 idle、外层 transform 归 `scale(1,1) rotate(0deg)`；不是在点击时突然换回另一幅完整图。
- 播放碰耳后在隔离浏览器切到新建空白页，再返回原型：读到 `mode=idle`、`story=-1`，没有补播旧故事；随后关闭了自用浏览器 session。

## 仍待手机检查

1. 覆盖安装新构建，在共同休时页停留 30～60 秒，查看自动故事；正常待机约 5～10 秒可看到眨眼/耳动。
2. 连点五次、故事中点击、快速切页、打开计划 sheet、锁屏再回来：应归位，不积压故事、不同一时刻播两段。
3. 小屏/大字体和深色下检查耳根与爪子接缝、标题底边、是否有掉帧；如果有，请提供画面或短录屏。

未运行原生模拟器/手机动画，本记录不声称已完成设备帧率、内存或耳根像素级验收。
