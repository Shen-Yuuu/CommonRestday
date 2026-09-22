import { taskpool } from '@kit.ArkTS';
import { systemDateTime } from '@kit.BasicServicesKit';
import { CommonFreeEngine, CommonFreeResult, EngineInput } from 'domain';
import { Logger } from 'commons';

const TAG = 'RecomputeExecutor';

/**
 * 主线程纯计算预算（ms）：60fps 一帧 16.6ms，留掉渲染与系统消息后，一次计算段能占的只有一帧。
 * 这是"要不要把计算搬出主线程"的唯一判据，见 docs/validation/performance-budget.md。
 */
export const MAIN_THREAD_BUDGET_MS: number = 16;

/**
 * 直接按 TaskPool 跑的视界下限（天）。
 * 依据是 tools/perf/budget.mjs 的视界扫描：120 天配对重算 P50 13.6ms（贴着预算），
 * 150 天起 P50 20.3ms 已经是开发机**下界**超预算，而 150 天是用户可设的合法视界
 * （HORIZON_MAX=366）。等真机攒够 8 个样本才迁移，等于先让第一批用户各卡一次。
 */
export const MIGRATE_HORIZON_DAYS: number = 150;

/** 引擎纯计算段标签：唯一有资格决定线程归属的测量对象。 */
const LABEL_ENGINE = 'common_free_engine';

/**
 * 保存动作的端到端墙钟标签（写入 + 重算 + 广播，含 RDB I/O）。
 * 这条只用来观察用户能感知的延迟：它含 I/O，超预算不能靠挪线程解决，因此不参与迁移判定。
 */
export const LABEL_SAVE_FLOW = 'save_recompute';

/** 判定要攒够这么多样本才翻转，避免一次抖动就把计算永久挪到别的线程。 */
const MIN_SAMPLES: number = 8;

/** 每个标签只留最近这么多条样本：视界调小、课程删完之后，旧分布不该继续钉住策略。 */
const RING_SIZE: number = 24;

/**
 * 工作线程上跑的引擎段。
 * @Concurrent 的入参与返回值都要能跨线程序列化：EngineInput / CommonFreeResult 全是
 * 普通对象与数组（班次、区间、标签），没有函数、Promise、Proxy，符合 taskpool 的可序列化口径。
 * 函数体内也不得读主线程状态——这里只依赖入参和 domain 的纯函数。
 */
@Concurrent
function computeOnWorker(input: EngineInput): CommonFreeResult {
  return CommonFreeEngine.compute(input);
}

/**
 * 纳秒级单调时钟读数（ms，含小数）。
 * ACTIVE 型不计深睡，跨休眠的一次重算不会被计出负数或巨大的耗时；
 * Date.now() 只有毫秒分辨率，测不出快照编解码那种百微秒级段落。
 */
function nowMs(): number {
  return systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, true) / 1000000;
}

function nearestRank(sorted: number[], q: number): number {
  return sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))];
}

/**
 * 重算执行器：把"要不要跨线程"变成一个有数的判据，而不是凭感觉。
 *
 * - 只测**纯计算段**决定线程归属：P95 超过 16ms 才迁移，小数据永远留在主线程内联
 *   （跨线程序列化本身要付代价，120 天轻班表实测 P50 2.1ms，没必要挪）。
 * - 迁移是进程内单向的：切线程的决策本身不该在阈值上下反复抖动，视界调大即时生效，调小靠重启进程回到内联。
 * - TaskPool 任何失败（worker 起不来、序列化不了）都退回内联：这是本机主流程，不能因为取数失败就没有共同时间。
 */
export class RecomputeExecutor {
  private static samples: Map<string, number[]> = new Map<string, number[]>();
  private static migrated: Set<string> = new Set<string>();

  /** 共同时间重算的唯一计算入口：内联还是 TaskPool 由实测预算决定。 */
  static async compute(input: EngineInput): Promise<CommonFreeResult> {
    const horizon = input.params.horizonDays;
    const workerFirst = horizon >= MIGRATE_HORIZON_DAYS || RecomputeExecutor.migrated.has(LABEL_ENGINE);
    if (workerFirst) {
      const t0 = nowMs();
      try {
        const task = new taskpool.Task(computeOnWorker, input);
        const onWorker = await taskpool.execute(task) as CommonFreeResult;
        RecomputeExecutor.record(LABEL_ENGINE, nowMs() - t0, 'taskpool', horizon);
        return onWorker;
      } catch (e) {
        // 10200003 worker 初始化失败 / 10200006 序列化失败：宁可主线程慢一帧，也不能算不出窗口
        Logger.warn(TAG, 'taskpool compute failed, fallback inline: ' + (e as Error).message);
      }
    }
    const t1 = nowMs();
    const inline = CommonFreeEngine.compute(input);
    RecomputeExecutor.record(LABEL_ENGINE, nowMs() - t1, workerFirst ? 'inline-fallback' : 'inline', horizon);
    return inline;
  }

  /** 包一段异步编排计时（不改线程归属，只记账）。失败不记样本：那是错误路径，不是延迟。 */
  static async measure<T>(label: string, work: () => Promise<T>): Promise<T> {
    const t0 = nowMs();
    const v = await work();
    RecomputeExecutor.record(label, nowMs() - t0, 'await', 0);
    return v;
  }

  /**
   * 落一次样本并打印验收要读的那一行：
   * hilog 里 grep "PERF" 即可拿到每个标签的 n/p50/p95/max 与当前模式。
   */
  private static record(label: string, ms: number, mode: string, horizon: number): void {
    let bucket = RecomputeExecutor.samples.get(label);
    if (bucket == null) {
      bucket = [];
      RecomputeExecutor.samples.set(label, bucket);
    }
    bucket.push(ms);
    if (bucket.length > RING_SIZE) {
      bucket.shift();
    }
    const sorted = bucket.slice().sort((a: number, b: number): number => a - b);
    const p50 = nearestRank(sorted, 0.5);
    const p95 = nearestRank(sorted, 0.95);
    Logger.perf(TAG, label
      + ' mode=' + mode
      + ' horizon=' + horizon
      + ' n=' + sorted.length
      + ' last=' + ms.toFixed(3)
      + ' p50=' + p50.toFixed(3)
      + ' p95=' + p95.toFixed(3)
      + ' max=' + sorted[sorted.length - 1].toFixed(3)
      + ' budget=' + MAIN_THREAD_BUDGET_MS);
    if (label === LABEL_ENGINE && !RecomputeExecutor.migrated.has(label)
      && sorted.length >= MIN_SAMPLES && p95 > MAIN_THREAD_BUDGET_MS) {
      RecomputeExecutor.migrated.add(label);
      Logger.warn(TAG, 'p95 ' + p95.toFixed(3) + 'ms over budget with ' + sorted.length
        + ' samples: moving engine compute to TaskPool');
    }
  }
}
