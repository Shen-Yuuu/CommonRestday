# 历史角色动画源码

这里是 2026-10-17 之前的动作方案快照，供历史网页原型与动作回归测试重建，不参与 App 编译。

- `CompanionMotion.ets`：早期整组呼吸与点击回弹。
- `CompanionNarrative.ets`：对视、依偎、捂耳和伸爪四段动作。
- `CompanionRig.ets`：旧耳朵/爪子分层裁切与坐标。

当前 App 只使用 `entry/src/main/ets/util/CompanionMotion.ets` 中的点击反馈、六个固定站位常量以及眨眼控制器。不要把历史动作重新接回正式界面。原型生成器和历史动作测试已改为读取这里的快照，避免把历史实现随应用打包。
