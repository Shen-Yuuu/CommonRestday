/** 由 tools/test/run.mjs 调用：加载转译后的两套 Hypium 用例并汇总退出码。 */
const hyp = require('@ohos/hypium');

require('./out/test/List.test.js').default();
require('./out/etest/List.test.js').default();
process.exitCode = hyp.xhsRun();
