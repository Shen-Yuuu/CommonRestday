import { describe, it, expect } from '@ohos/hypium';
import { SerialQueue } from 'feature';

/**
 * 重算独占队列的语义（差异文档 D-52 的后半边）。
 *
 * 队列本体不碰 @kit，离线就能真测——这正是把它单独抽成一件事的理由：接在它外面的八处入口
 * 全在设备侧，而"两次重算不许重叠"这条性质一旦在队列里破了，缓存表就会留下两代并存的行
 * （`replaceWindows` 只删 `computed_at` 更旧的，删不掉更新的那一代），症状是"已经改掉的班还在"，
 * 且要等下一次重算才自愈——设备复验很容易撞上又错过。所以先在这里把队列钉死。
 */

/** 让出事件循环 ms 毫秒：任务时长由这里给，好把"发起顺序"和"完成顺序"分开发。 */
async function sleep(ms: number): Promise<void> {
  await new Promise<number>((resolve) => {
    setTimeout(resolve, ms);
  });
}

export default function serialQueueTest() {
  describe('serialQueue', () => {

    /** 全程并发数不许多于 1，且执行顺序 = 发起顺序（时长反着给，慢的那个排在最前）。 */
    it('runs_one_at_a_time_in_submission_order', 0, async () => {
      const q = new SerialQueue();
      const trace: string[] = [];
      let running = 0;
      let peak = 0;
      const body = (label: string, ms: number): (() => Promise<string>) => {
        return async (): Promise<string> => {
          running += 1;
          if (running > peak) {
            peak = running;
          }
          trace.push('start-' + label);
          await sleep(ms);
          trace.push('end-' + label);
          running -= 1;
          return label;
        };
      };
      // 三次发起都发生在同一个同步段里：a 最慢，c 最快——不排队的话 c 会抢在 a 之前落地
      const a = q.run(body('a', 30));
      const b = q.run(body('b', 10));
      const c = q.run(body('c', 1));
      expect(await a).assertEqual('a');
      expect(await b).assertEqual('b');
      expect(await c).assertEqual('c');
      expect(peak).assertEqual(1);
      expect(trace.join(' ')).assertEqual('start-a end-a start-b end-b start-c end-c');
    });

    /** 每段各拿各的结果：排队不许把返回值串到别人手上（引擎结果一路透传）。 */
    it('each_caller_gets_its_own_result', 0, async () => {
      const q = new SerialQueue();
      const slow = q.run((): Promise<number> => {
        return sleep(20).then((): number => 1);
      });
      const fast = q.run((): Promise<string> => Promise.resolve('two'));
      const third = q.run((): Promise<boolean> => Promise.resolve(true));
      expect(await slow).assertEqual(1);
      expect(await fast).assertEqual('two');
      expect(await third).assertTrue();
    });

    /** 抛错的那段只炸自己：调用方收到同一个错，队列随即放行下一位，不锁死。 */
    it('a_failing_task_rejects_its_caller_and_lets_the_next_run', 0, async () => {
      const q = new SerialQueue();
      const trace: string[] = [];
      const bad = q.run((): Promise<string> => {
        trace.push('bad');
        return Promise.reject(new Error('engine blew up'));
      });
      const good = q.run((): Promise<string> => {
        trace.push('good');
        return Promise.resolve('after-failure');
      });
      let caught = '';
      await bad.catch((e: Error) => {
        caught = e.message;
      });
      expect(caught).assertEqual('engine blew up');
      expect(await good).assertEqual('after-failure');
      expect(trace.join(',')).assertEqual('bad,good');
    });

    /** 排空之后还接得下活：tail 每次结算都回到已履行状态，不是一次性开关。 */
    it('keeps_accepting_work_after_draining', 0, async () => {
      const q = new SerialQueue();
      const first: number = await q.run((): Promise<number> => Promise.resolve(1));
      expect(first).assertEqual(1);
      // 上一段已经结算，这里走的是"队首直接放行"那条支路——写坏成只服务第一批也会在这一格红
      const second: number = await q.run((): Promise<number> => {
        return sleep(5).then((): number => 2);
      });
      expect(second).assertEqual(2);
      const third: number = await q.run((): Promise<number> => Promise.resolve(3));
      expect(third).assertEqual(3);
    });

    /**
     * 一段任务里"读 → 算 → 写回"中间不许插进另一段。
     *
     * 这条就是重算要的形状：`recomputeLocked` 先读班表、再算引擎、最后 `replaceWindows` 写缓存表，
     * 而那次写入的清理条件是按**这一代自己的**时间戳删更旧的行。另一段插进读与写中间时，
     * 两代各自写各的、彼此的清理都只扫到自己之前那一半——表里就同时留着两代窗口。
     */
    it('a_task_is_not_interleaved_between_its_read_and_its_write', 0, async () => {
      const q = new SerialQueue();
      const trace: string[] = [];
      const task = (label: string, ms: number): Promise<void> => {
        return q.run((): Promise<void> => {
          trace.push('read-' + label);
          return sleep(ms).then((): void => {
            trace.push('write-' + label);
          });
        });
      };
      // 慢的那段先发起：不排队时它和快的那段交错成
      // read-a,read-b,write-b,write-a——正是缓存表留下两代结果的那条序列
      const a = task('a', 20);
      const b = task('b', 1);
      await a;
      await b;
      expect(trace.join(',')).assertEqual('read-a,write-a,read-b,write-b');
    });
  });
}
