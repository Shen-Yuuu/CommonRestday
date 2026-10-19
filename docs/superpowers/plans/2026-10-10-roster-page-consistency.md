# Roster Page Consistency Implementation Plan

> Execute inline in the current task. No delegation, staging or commits in the user's dirty checkout.

**Goal:** Apply the user's explicit navigation, title and week-control consistency requirements.

**Architecture:** Extract the existing WeekScheduleView week navigation into WeekNavigator; keep dates, animation and dirty protection owned by their existing parents. Relocate the preset route entry to CycleEditor's header.

**Tech Stack:** ArkTS / ArkUI API 26, source regression tests, existing offline test runner, Hvigor Debug.

**Spec:** docs/plans/2026-10-10-roster-page-consistency-design.md

## Global constraints

Preserve saved records and draft protections. No cloud or device mutation. No speculative redesign. Computation behavior is a separate user choice, not an implied UI change.

## Task 1: Existing layout consistency

Files: entry/component/WeekNavigator.ets, WeekScheduleView.ets, WeeklyRosterView.ets; entry/pages/CycleEditor.ets; entry/view/ScheduleHub.ets; tools/test/schedule-editing-regression.mjs.

- [x] Add failing source assertions: ScheduleHub uses `text: '我的班表'`; CycleEditor contains chevron_left and the common-preset route; WeeklyRosterView does not render `Text('周班表')` or own preset button; both week views render WeekNavigator.
- [x] Add `WeekNavigator` with `@Prop weekStart: number`, `@Prop horizontalOffset: number = 0`, `@Prop alpha: number = 1`, and callbacks `onPrevious`, `onNext`, `onCurrent`. Copy the existing week navigation styling and accessibility. Replace both week navigation rows with the component, passing existing callbacks, horizontalOffset and alpha. Avoid the native CustomComponent method name offset.
- [x] Replace CycleEditor's pill back button with the existing arrow/text pattern, title 17vp, header padding 12, and right preset entry routing to `pages/ScheduleEditor` with `ownerParam(this.owner)`. Preserve `leave()` and `onBackPress()`, disable preset entry while busy. Remove duplicate body heading. Rename ScheduleHub first Tab to 我的班表.
- [x] Run `node tools/test/schedule-editing-regression.mjs`, then `node tools/verify.mjs --steps=offline,debug`. Review scoped diff and record the device acceptance boundary.

## Task 2: Approved unassigned-as-free behavior

Files: domain/engine/CommonFreeEngine.ets; domain/src/test/WeeklyRosterTest.ets; data/repo/ScheduleRepo.ets; tools/test/weekly-roster-integration-regression.cjs; tools/test/schedule-cache-navigation-regression.cjs; WeeklyRosterView.ets.

- [x] Revise and run failing regressions: unassigned work-mode date is available, waking hours still enforced, personal entries and confirmed plans still busy, privacy-level snapshots preserve real occupancy but no invented whole-day UNKNOWN, and real plan checker accepts otherwise-free unassigned dates.
- [x] Delete the `weeklyMode` UNKNOWN whole-day injection only. Keep dated-day storage, legacy cycles, all real occupancy and null-partner presentation gates unchanged. Update roster note to explain the approved rule.
- [x] Write `window_cache_policy_v1 = unassigned_free_v2` inside replaceWindows' existing transaction; windowCacheComputedAt reads timestamps only when that policy marker exists. Isolated SQLite must prove pre-policy rows remain stored but require recalculation, empty fresh result succeeds, and failures roll back timestamps, rows and policy together.
- [x] Run full offline both cloud tiers and Debug; record result and instructions to update and refresh both cloud-paired devices, without claiming actual device/cloud verification.
