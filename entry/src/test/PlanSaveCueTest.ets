import { describe, it, expect } from '@ohos/hypium';
import { PlanSaveCueStore } from 'commons';

export default function planSaveCueTest() {
  describe('planSaveCue', () => {
    it('empty_id_does_not_emit_a_cue', 0, () => {
      const store = new PlanSaveCueStore();
      expect(store.publish('', 1000)).assertEqual(0);
      expect(store.peek(1001) === undefined).assertTrue();
    });
    it('saved_id_is_visible_and_consumed_exactly_once', 0, () => {
      const store = new PlanSaveCueStore();
      const serial = store.publish('real-plan-id', 1000);
      const cue = store.peek(1200);
      expect(cue !== undefined && cue.id === 'real-plan-id').assertTrue();
      expect(store.consume(serial)).assertTrue();
      expect(store.consume(serial)).assertFalse();
      expect(store.peek(1300) === undefined).assertTrue();
    });
    it('expired_or_future_cue_is_not_replayed', 0, () => {
      const store = new PlanSaveCueStore();
      store.publish('p', 1000);
      expect(store.peek(1000 + 30000) !== undefined).assertTrue();
      expect(store.peek(1000 + 30001) === undefined).assertTrue();
      expect(store.peek(999) === undefined).assertTrue();
      expect(store.peek(Number.NaN) === undefined).assertTrue();
    });
    it('a_new_save_replaces_an_old_cue_without_old_consumer_erasing_it', 0, () => {
      const store = new PlanSaveCueStore();
      const first = store.publish('old', 1000);
      const second = store.publish('new', 1100);
      expect(second > first).assertTrue();
      expect(store.consume(first)).assertFalse();
      const cue = store.peek(1200);
      expect(cue !== undefined && cue.id === 'new').assertTrue();
      expect(store.consume(second)).assertTrue();
    });
  });
}
