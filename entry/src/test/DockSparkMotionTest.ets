import { describe, it, expect } from '@ohos/hypium';
import { DockSparkMotion } from 'commons';

export default function dockSparkMotionTest() {
  describe('dockSparkMotion', () => {
    it('cycle_parameters_are_bounded_and_not_a_fixed_path', 0, () => {
      const first = DockSparkMotion.next(0, 6200);
      const last = DockSparkMotion.next(0.9999, 6200);
      expect(first.left >= 5 && last.left <= 95).assertTrue();
      expect(first.drift >= -12 && last.drift <= 12).assertTrue();
      expect(first.delayMs >= 300 && last.delayMs <= 3300).assertTrue();
      expect(first.left !== last.left).assertTrue();
      expect(first.periodMs).assertEqual(6200);
      expect(last.periodMs).assertEqual(6200);
    });
    it('malformed_random_and_period_do_not_escape_the_animation_band', 0, () => {
      const a = DockSparkMotion.next(Number.NaN, -3);
      const b = DockSparkMotion.next(4, Number.POSITIVE_INFINITY);
      expect(a.left >= 5 && a.left <= 95).assertTrue();
      expect(b.left >= 5 && b.left <= 95).assertTrue();
      expect(a.periodMs).assertEqual(6200);
      expect(b.periodMs).assertEqual(6200);
    });
    it('opacity_starts_and_ends_at_zero', 0, () => {
      expect(DockSparkMotion.opacity(0, 0.8)).assertEqual(0);
      expect(DockSparkMotion.opacity(1, 0.8)).assertEqual(0);
      expect(DockSparkMotion.opacity(0.4, 0.8)).assertEqual(0.8);
    });
  });
}
