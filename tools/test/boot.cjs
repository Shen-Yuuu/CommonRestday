/** 由 tools/test/run.mjs 调用：加载转译后的两套 Hypium 用例并汇总退出码。 */
const hyp = require('@ohos/hypium');

/**
 * AppStorage 最小替身：ScheduleUseCase 桩按设备侧同名键广播 recomputeCount，
 * 命令层用例据此断言"一次保存只重算一次"，不依赖任何测试专用字段。
 */
if (typeof globalThis.AppStorage === 'undefined') {
  const mem = new Map();
  globalThis.AppStorage = class AppStorage {
    static get(key) { return mem.get(key); }
    static set(key, value) { mem.set(key, value); return true; }
    static setOrCreate(key, value) { mem.set(key, value); return true; }
  };
}

require('./out/test/List.test.js').default();
require('./out/etest/List.test.js').default();
// xhsRun 是异步的（用例可能 await 真机侧异步 API），退出码要等它跑完再定
(async () => {
  process.exitCode = await hyp.xhsRun();
})();
