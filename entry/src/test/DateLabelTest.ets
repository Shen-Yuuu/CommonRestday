import { describe, it, expect } from '@ohos/hypium';
import { DateLabel } from 'commons';
import { MIN_PER_DAY, dayOfEnd, dayOfStart } from 'domain';

const DAY_MIN = 1440;
/** 2026-09-25 的 epochDay：写死一个已知日子，免得断言跟着机器钟点漂。 */
const T = 20721;

/**
 * 端点日期标签（D-44）：起草器原来只印 HH:MM，明天 07:00 与今天 07:00 在屏幕上长得一样，
 * 半夜打开窗口两次都撞过（批次 H、批次 J），所以两端都要自证是哪一天。
 */
export default function dateLabelTest() {
  describe('dateLabel', () => {

    it('stamp_uses_relative_words_only_for_today_and_tomorrow', 0, () => {
      expect(DateLabel.stamp(T * DAY_MIN + 1410, false, T)).assertEqual('今天 23:30');
      expect(DateLabel.stamp((T + 1) * DAY_MIN + 420, true, T)).assertEqual('明天 07:00');
      // 再往后不念相对词：页面停留跨过零点，"明天"就不指原来那一天了
      expect(DateLabel.stamp((T + 2) * DAY_MIN + 420, false, T)).assertEqual('9月27日 07:00');
      expect(DateLabel.stamp((T - 1) * DAY_MIN + 420, false, T)).assertEqual('9月24日 07:00');
    });

    it('stamp_keeps_the_midnight_end_on_the_previous_day', 0, () => {
      // 结束落在整零点记成前一天 24:00，与 DateLabel.endLabel 同一口径
      expect(DateLabel.stamp((T + 1) * DAY_MIN, true, T)).assertEqual('今天 24:00');
      expect(DateLabel.stamp((T + 2) * DAY_MIN, true, T)).assertEqual('明天 24:00');
      expect(DateLabel.stamp((T + 1) * DAY_MIN, false, T)).assertEqual('明天 00:00');
    });

    it('edgeTime_reads_a_midnight_end_as_24_00_only_on_the_end', 0, () => {
      // D-58：整零点这一个瞬间有两种读法——区间的尾巴属于前一天（24:00），
      // 区间的头属于后一天（00:00）。改前这条口径抄在三处，另有七个终点调用点压根没接。
      expect(DateLabel.edgeTime((T + 1) * DAY_MIN, true)).assertEqual('24:00');
      expect(DateLabel.edgeTime((T + 1) * DAY_MIN, false)).assertEqual('00:00');
      // 非整零点时 isEnd 不许额外改动时刻
      expect(DateLabel.edgeTime(T * DAY_MIN + 1230, true)).assertEqual('20:30');
      expect(DateLabel.edgeTime(T * DAY_MIN + 1230, false)).assertEqual('20:30');
    });

    it('edgeDay_puts_a_midnight_end_on_the_previous_day', 0, () => {
      // 判错半边，区间在屏幕上就短或长一整天：同一分钟按 isEnd 读会差一天
      expect(DateLabel.edgeDay((T + 1) * DAY_MIN, true)).assertEqual(T);
      expect(DateLabel.edgeDay((T + 1) * DAY_MIN, false)).assertEqual(T + 1);
      expect(DateLabel.edgeDay(T * DAY_MIN + 1230, true)).assertEqual(T);
      expect(DateLabel.edgeDay(T * DAY_MIN - 1, true)).assertEqual(T - 1);
    });

    it('endLabel_uses_the_same_edge_rule_as_stamp', 0, () => {
      // 两个读者钉在同一份判定上：谁再各自抄一遍 24:00，这里先红
      expect(DateLabel.endLabel(T * DAY_MIN + 1200, (T + 1) * DAY_MIN)).assertEqual('20:00–24:00');
      expect(DateLabel.endLabel(T * DAY_MIN + 1200, (T + 2) * DAY_MIN))
        .assertEqual('20:00 – ' + DateLabel.md(T + 1) + ' 24:00');
      // 起点落在整零点仍念 00:00，别把「尾巴」的读法漏给「头」
      expect(DateLabel.endLabel((T + 1) * DAY_MIN, (T + 1) * DAY_MIN + 540)).assertEqual('00:00–09:00');
    });

    it('commons_day_wraps_on_the_same_minute_count_as_domain', 0, () => {
      // commons 是依赖图的底，那条 1440 不能 import domain 的 MIN_PER_DAY（见 DateLabel.ets 注释）。
      // 单位定义写不出第三个值，但谁改动其中一份，这一格立刻红：时刻与端点日期都得跟着同一个天数走。
      expect(DateLabel.hm(T * MIN_PER_DAY + 420)).assertEqual('07:00');
      expect(DateLabel.hm((T + 1) * MIN_PER_DAY + 420)).assertEqual('07:00');
      expect(DateLabel.edgeDay(T * MIN_PER_DAY + 420, false)).assertEqual(T);
      expect(DateLabel.edgeDay(T * MIN_PER_DAY, true)).assertEqual(T - 1);
    });

    it('edge_day_and_time_agree_with_the_domain_edge_rule', 0, () => {
      // 「端点算哪天／怎么念」在 commons 与 domain 各有一份（前者不能 import 后者，加依赖边待用户裁定）。
      // 静态门禁 `span:` 只拦"再抄第三份"，等不等价得在这里逐点核对：整零点、整零点前后一分钟、
      // 跨多日都要走到。两份分家的现场是 D-58——同一个 w.end 在窗口行念 24:00、在忙碌行念 00:00。
      const dayOffsets: number[] = [-3, -1, 0, 1, 7, 200];
      // 不含 0：整零点就是上面单独核对的那一格，混进这张表里会被"非整零点"那两条断言冤枉
      const minutes: number[] = [1, 59, 720, 1379, 1439];
      for (let i = 0; i < dayOffsets.length; i++) {
        const edge = (T + dayOffsets[i]) * MIN_PER_DAY;
        // 午夜端点：归日退回前一天，时刻念成 24:00——同一条口径的两半，必须同真同假
        expect(DateLabel.edgeDay(edge, false)).assertEqual(dayOfStart(edge));
        expect(DateLabel.edgeDay(edge, true)).assertEqual(dayOfEnd(edge));
        expect(dayOfEnd(edge) !== dayOfStart(edge)).assertTrue();
        expect(DateLabel.edgeTime(edge, true) === '24:00').assertTrue();
        // 起点端读的是次日 00:00，不许把"尾巴"的读法漏给"头"
        expect(DateLabel.edgeDay(edge, false)).assertEqual(edge / MIN_PER_DAY);
        expect(DateLabel.edgeTime(edge, false) === '24:00').assertFalse();
        for (let j = 0; j < minutes.length; j++) {
          const m = edge + minutes[j];
          expect(DateLabel.edgeDay(m, false)).assertEqual(dayOfStart(m));
          expect(DateLabel.edgeDay(m, true)).assertEqual(dayOfEnd(m));
          // 非整零点：终点归当天，念法也回到普通 HH:MM
          expect(dayOfEnd(m) === dayOfStart(m)).assertTrue();
          expect(DateLabel.edgeTime(m, true) === '24:00').assertFalse();
        }
      }
    });
  });
}
