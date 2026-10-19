# 两人份品牌启动页验收记录

日期：2026-10-01。结论：配置与 debug 编译通过；设备观感待用户验证，不构成发布验收完成。

## 已落地

- EntryAbility 引用 `$profile:start_window`，增强原生启动页中央使用用户的 `$media:jim1_resized`。
- 底部 `start_brand.svg` 为两行「两人份 / ForTwo」轮廓路径，提供 base/dark 两种文字颜色。每份 5637 字节，不分发字体，不引用外网。
- 背景跟随系统：浅色 `#FFF6F3`、深色 `#241C3B`；暖色图标本身有背景，深色下仍保留原图背景，不宣称是透明图标。
- 图标源尺寸 1024×1024，1307433 字节，原样复用；没有修改用户文件、桌面图标引用、`vendor=ShenYuuu` 或配对业务。
- 没有新增 Splash 路由、加载倒计时、最低停留时长或云服务等待；首页仍是 `pages/Index`。

## 本轮机器证据

| 检查 | 结果 |
|---|---|
| 静态回归先红 | 未创建 profile 时 ENOENT |
| `node tools/test/start-window-regression.mjs` | PASS |
| `node tools/verify.mjs --steps=offline` | closed/open 各 typecheck 0 errors、271 passed / 0 failed、exit 0 |
| serial clean + debug assembleHap | BUILD SUCCESSFUL，ArkTS:ERROR 0、ArkTS:WARN 287，基线 289 未修改 |
| `git diff --check`（本轮修改文件） | 无错误 |

构建日志：`E:/desktop/Code/harmony/.crdtest/brand-start-debug.log`。debug 产物：`entry/build/default/outputs/default/entry-default-signed.hap`。本轮没有生成正式发布 APP，也没有重跑 release 或 ohosTest。

## 设备步骤（全部待验证）

1. 使用正常 Run 或安装最新测试 HAP，不卸载、不清库。
2. 系统设为浅色，在应用管理中结束应用进程，再从桌面图标启动；也可用 DevEco Stop 停止应用后再点桌面。仅返回桌面通常不是冷启动。
3. 检查中央双环心形图标、奶油色全屏背景、底部两行字标；没有蓝色默认启动图标，字标不被系统导航区域遮住。必要时用屏幕录制逐帧查看，快速设备上启动页可能仅显示很短时间。
4. 系统切到深色，重复结束进程与桌面启动。检查深紫背景、浅色品牌字标；中央图标保留原图奶油底板，这是原始素材的正常效果，不是深色资源失效。
5. 确认直接进入首页，不新增固定等待，不因断网延长品牌展示。首页数据加载与原有行为一致。
6. 返回桌面后立即再次进入，确认没有另一个自绘启动页重复播放；系统原生动画是否出现由系统生命周期决定。

如果不喜欢原图在深色底上的浅色方块，需要单独提供透明标识素材；本批不做抠图。显示位置和字标大小由系统增强启动页布局决定，不能仅凭静态资源判定观感通过。
