import { describe, it, expect } from '@ohos/hypium';
import {
  SharedPlanState, SharedPlanAction, SharedPlanRecord, SharedPlanContent,
  evaluateSharedPlanAction, initialSharedPlan, sharedPlanActivity, sharedPlanPendingCount,
  sharedPlanAad, sharedPlanStateLabel, shouldApplySharedPlan, sharedActions
} from 'feature';

function content(start: number = 600): SharedPlanContent {
  return { title: '午餐', kind: 'meal', start: start, end: start + 60 };
}

function invitation(): SharedPlanRecord {
  return initialSharedPlan('pair-A', 'plan-A', 'member-A', 'member-B', content());
}

function act(row: SharedPlanRecord, action: SharedPlanAction, actor: string,
  expected: number = row.stateVersion, proposed: SharedPlanContent | null = null): SharedPlanRecord {
  return evaluateSharedPlanAction(row, { action: action, actorUid: actor, expectedVersion: expected,
    nextContent: proposed, nowMin: 500 }).record;
}

function accepted(): SharedPlanRecord {
  return act(invitation(), SharedPlanAction.ACCEPT, 'member-B');
}

export default function sharedPlanFlowTest() {
  describe('sharedPlanFlow', () => {
    it('presentation_actions_follow_actor_and_keep_old_accepted_time_during_amendment', 0, () => {
      const pending = invitation();
      expect(sharedActions(pending, 'member-A').join(',')).assertEqual('WITHDRAW');
      expect(sharedActions(pending, 'member-B').join(',')).assertEqual('ACCEPT,DECLINE');
      expect(sharedActions(pending, 'member-C').length).assertEqual(0);
      const confirmed = accepted();
      expect(sharedActions(confirmed, 'member-A').join(',')).assertEqual('AMEND,CANCEL');
      const amended = act(confirmed, SharedPlanAction.AMEND, 'member-A', confirmed.stateVersion, content(800));
      expect(sharedActions(amended, 'member-B').join(',')).assertEqual('ACCEPT,DECLINE,CANCEL');
      expect(sharedActions(amended, 'member-A').join(',')).assertEqual('WITHDRAW,CANCEL');
      expect(sharedPlanActivity(amended)?.content.start).assertEqual(600);
      expect(sharedActions(act(confirmed, SharedPlanAction.CANCEL, 'member-A'), 'member-A').length).assertEqual(0);
    });
    it('pending_has_no_activity_but_retains_a_persistent_dot', 0, () => {
      const row = invitation();
      expect(sharedPlanActivity(row) === null).assertTrue();
      expect(sharedPlanPendingCount([row], 'pair-A')).assertEqual(1);
      expect(sharedPlanPendingCount([row], 'other-pair')).assertEqual(0);
      expect(sharedPlanPendingCount([row], 'pair-A')).assertEqual(1);
    });
    it('only_recipient_can_accept_or_decline_initial_invitation', 0, () => {
      for (const action of [SharedPlanAction.ACCEPT, SharedPlanAction.DECLINE]) {
        const denied = evaluateSharedPlanAction(invitation(), { action: action, actorUid: 'member-A',
          expectedVersion: 1, nextContent: null, nowMin: 500 });
        expect(denied.code).assertEqual('FORBIDDEN');
        expect(denied.record.state).assertEqual(SharedPlanState.PENDING);
      }
      expect(accepted().state).assertEqual(SharedPlanState.ACCEPTED);
      expect(act(invitation(), SharedPlanAction.DECLINE, 'member-B').state).assertEqual(SharedPlanState.DECLINED);
    });
    it('confirmation_produces_one_stable_activity_and_no_pending_dot', 0, () => {
      const row = accepted();
      const projection = sharedPlanActivity(row);
      expect(projection !== null).assertTrue();
      if (projection !== null) {
        expect(projection.id).assertEqual('shared:pair-A:plan-A');
        expect(projection.content.start).assertEqual(600);
        expect(projection.contentRevision).assertEqual(1);
      }
      expect(sharedPlanPendingCount([row], 'pair-A')).assertEqual(0);
    });
    it('stale_version_and_non_member_never_change_the_record', 0, () => {
      const row = invitation();
      const stale = evaluateSharedPlanAction(row, { action: SharedPlanAction.ACCEPT, actorUid: 'member-B',
        expectedVersion: 0, nextContent: null, nowMin: 500 });
      expect(stale.code).assertEqual('VERSION_CONFLICT');
      const foreign = evaluateSharedPlanAction(row, { action: SharedPlanAction.ACCEPT, actorUid: 'stranger',
        expectedVersion: 1, nextContent: null, nowMin: 500 });
      expect(foreign.code).assertEqual('FORBIDDEN');
      expect(row.stateVersion).assertEqual(1);
      expect(row.state).assertEqual(SharedPlanState.PENDING);
    });
    it('withdraw_is_author_only_and_terminal_states_do_not_activate', 0, () => {
      const wrong = evaluateSharedPlanAction(invitation(), { action: SharedPlanAction.WITHDRAW, actorUid: 'member-B',
        expectedVersion: 1, nextContent: null, nowMin: 500 });
      expect(wrong.code).assertEqual('FORBIDDEN');
      const row = act(invitation(), SharedPlanAction.WITHDRAW, 'member-A');
      expect(row.state).assertEqual(SharedPlanState.WITHDRAWN);
      expect(sharedPlanActivity(row) === null).assertTrue();
      expect(act(row, SharedPlanAction.ACCEPT, 'member-B').state).assertEqual(SharedPlanState.WITHDRAWN);
    });
    it('amendment_keeps_old_activity_until_other_member_accepts', 0, () => {
      const row = act(accepted(), SharedPlanAction.AMEND, 'member-A', 2, content(800));
      expect(row.state).assertEqual(SharedPlanState.ACCEPTED);
      expect(row.contentRevision).assertEqual(2);
      expect(sharedPlanPendingCount([row], 'pair-A')).assertEqual(1);
      const before = sharedPlanActivity(row);
      if (before !== null) expect(before.content.start).assertEqual(600);
      const next = act(row, SharedPlanAction.ACCEPT, 'member-B');
      const after = sharedPlanActivity(next);
      if (after !== null) {
        expect(after.id).assertEqual('shared:pair-A:plan-A');
        expect(after.content.start).assertEqual(800);
      }
      expect(sharedPlanPendingCount([next], 'pair-A')).assertEqual(0);
    });
    it('declining_or_withdrawing_amendment_preserves_previous_agreement', 0, () => {
      for (const action of [SharedPlanAction.DECLINE, SharedPlanAction.WITHDRAW]) {
        const row = act(accepted(), SharedPlanAction.AMEND, 'member-B', 2, content(800));
        const actor = action === SharedPlanAction.DECLINE ? 'member-A' : 'member-B';
        const next = act(row, action, actor);
        expect(next.state).assertEqual(SharedPlanState.ACCEPTED);
        const projection = sharedPlanActivity(next);
        expect(projection !== null).assertTrue();
        if (projection !== null) expect(projection.content.start).assertEqual(600);
        expect(sharedPlanPendingCount([next], 'pair-A')).assertEqual(0);
        expect(next.contentRevision).assertEqual(2);
      }
    });
    it('either_member_may_amend_or_cancel_but_not_accept_own_amendment', 0, () => {
      const row = act(accepted(), SharedPlanAction.AMEND, 'member-B', 2, content(800));
      const wrong = evaluateSharedPlanAction(row, { action: SharedPlanAction.ACCEPT, actorUid: 'member-B',
        expectedVersion: 3, nextContent: null, nowMin: 500 });
      expect(wrong.code).assertEqual('FORBIDDEN');
      for (const actor of ['member-A', 'member-B']) {
        const cancelled = act(accepted(), SharedPlanAction.CANCEL, actor);
        expect(cancelled.state).assertEqual(SharedPlanState.CANCELLED);
        expect(sharedPlanActivity(cancelled) === null).assertTrue();
      }
    });
    it('expired_time_and_invalid_content_do_not_confirm_or_amend', 0, () => {
      const late = evaluateSharedPlanAction(invitation(), { action: SharedPlanAction.ACCEPT, actorUid: 'member-B',
        expectedVersion: 1, nextContent: null, nowMin: 601 });
      expect(late.code).assertEqual('TIME_PASSED');
      const invalid: SharedPlanContent = { title: '', kind: 'custom', start: 800, end: 860 };
      const bad = evaluateSharedPlanAction(accepted(), { action: SharedPlanAction.AMEND, actorUid: 'member-A',
        expectedVersion: 2, nextContent: invalid, nowMin: 500 });
      expect(bad.code).assertEqual('BAD_CONTENT');
    });
    it('pending_amendment_cannot_be_overwritten_by_another_amendment', 0, () => {
      const row = act(accepted(), SharedPlanAction.AMEND, 'member-A', 2, content(800));
      const next = evaluateSharedPlanAction(row, { action: SharedPlanAction.AMEND, actorUid: 'member-B',
        expectedVersion: 3, nextContent: content(900), nowMin: 500 });
      expect(next.code).assertEqual('STATE_CONFLICT');
    });
    it('aad_changes_with_content_not_confirmation_state', 0, () => {
      const pending = invitation();
      const confirmed = accepted();
      expect(sharedPlanAad(pending.pairId, pending.planId, pending.contentRevision))
        .assertEqual(sharedPlanAad(confirmed.pairId, confirmed.planId, confirmed.contentRevision));
      const changed = act(confirmed, SharedPlanAction.AMEND, 'member-A', 2, content(800));
      expect(sharedPlanAad(changed.pairId, changed.planId, changed.contentRevision) !==
        sharedPlanAad(pending.pairId, pending.planId, pending.contentRevision)).assertTrue();
    });
    it('same_or_stale_and_other_pair_cloud_updates_are_ignored', 0, () => {
      const old = invitation();
      const fresh = accepted();
      expect(shouldApplySharedPlan(old, fresh, 'pair-A')).assertTrue();
      expect(shouldApplySharedPlan(fresh, old, 'pair-A')).assertFalse();
      expect(shouldApplySharedPlan(fresh, fresh, 'pair-A')).assertFalse();
      expect(shouldApplySharedPlan(old, fresh, 'other-pair')).assertFalse();
    });
    it('returned_projection_and_transition_are_not_mutable_aliases', 0, () => {
      const source = invitation();
      const next = act(source, SharedPlanAction.ACCEPT, 'member-B');
      expect(source.state).assertEqual(SharedPlanState.PENDING);
      const projection = sharedPlanActivity(next);
      if (projection !== null) projection.content.title = '变更';
      expect(next.acceptedContent !== null && next.acceptedContent.title === '午餐').assertTrue();
    });
    it('pending_label_distinguishes_awaiting_me_and_awaiting_partner', 0, () => {
      expect(sharedPlanStateLabel(invitation(), 'member-A')).assertEqual('等待 TA 确认');
      expect(sharedPlanStateLabel(invitation(), 'member-B')).assertEqual('待我确认');
      expect(sharedPlanStateLabel(accepted(), 'member-B')).assertEqual('已确认');
    });
    it('higher_version_cannot_revive_terminal_or_reassign_members', 0, () => {
      const stopped = act(accepted(), SharedPlanAction.CANCEL, 'member-A');
      const forged = accepted();
      forged.stateVersion = 100;
      expect(shouldApplySharedPlan(stopped, forged, 'pair-A')).assertFalse();
      forged.recipientUid = 'member-C';
      expect(shouldApplySharedPlan(invitation(), forged, 'pair-A')).assertFalse();
    });
    it('duplicate_rows_use_latest_state_for_the_pending_dot', 0, () => {
      expect(sharedPlanPendingCount([invitation(), invitation()], 'pair-A')).assertEqual(1);
      expect(sharedPlanPendingCount([invitation(), accepted()], 'pair-A')).assertEqual(0);
      expect(sharedPlanPendingCount([accepted(), invitation()], 'pair-A')).assertEqual(0);
    });
    it('inconsistent_accepted_content_never_projects', 0, () => {
      const row = accepted();
      row.acceptedRevision = 0;
      expect(sharedPlanActivity(row) === null).assertTrue();
      row.acceptedRevision = 1;
      if (row.acceptedContent !== null) row.acceptedContent.end = row.acceptedContent.start;
      expect(sharedPlanActivity(row) === null).assertTrue();
    });
  });
}
