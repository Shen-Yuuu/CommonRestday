import { describe, it, expect } from '@ohos/hypium';
import { DateLabel } from 'commons';

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
  });
}
