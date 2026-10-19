# Schedule Calendar Recovery Implementation Plan

> Execute inline in this task; no delegation or device installation.

**Goal:** Restore the original calendar entry and fix false stale state plus the evidenced tab-switch crash.

**Architecture:** Keep the dated roster implementation behind its route. Store an independent freshness marker in the existing cache-write transaction. Use one safe scroll-offset reader in CoTimeView.

**Tech Stack:** ArkTS/ArkUI API 26, existing RDB sync_meta, isolated SQLite, Node source/production regressions, Hvigor.

**Spec:** `docs/plans/2026-10-10-schedule-calendar-recovery-design.md`

## Global constraints

Do not remove stored rosters, old cycles or plans. Do not hide genuinely stale results. Preserve the existing directional animation. No cloud deployment, clearing/installing device data, or unrelated worktree cleanup.

## Task 1: Cache correctness

Files: ScheduleRepo.ets; new tools/test/schedule-cache-navigation-regression.cjs; tools/test/run.mjs.

- [x] Execute production repository on isolated SQLite: initially timestamp 0; legacy row timestamp is readable; nonempty → empty preserves fresh timestamp; metadata-write failure rolls back both rows and timestamp.
- [x] Add marker `window_cache_computed_at_v1` in replaceWindows()'s transaction, and include it in windowCacheComputedAt()'s aggregate query. Keep the same public signatures.

## Task 2: Scroll-controller lifecycle

Files: entry/util/ScrollOffset.ets; CoTimeView.ets; regression above.

- [x] Production `readScrollY(scroller: Scroller, fallback: number): number` uses offset(), returns a finite nonnegative value, preserves valid fallback if unbound/throws, and defaults invalid fallback to 0.
- [x] Use the helper in commitView and both view callbacks; bind the empty-list Scroll to windowScroller. Verify undefined/null/NaN/negative/throw and populated offsets.

## Task 3: Restore calendar and acceptance

Files: ScheduleHub.ets; schedule-editing-regression.mjs; validation document.

- [x] Restore WeekScheduleView with owner propagation, day editing sheet, and 周历／日程管理 tab labels; remove direct WeeklyRosterView and redundant 常用班次 menu entry.
- [x] Keep 周班表 → CycleEditor → WeeklyRosterView → 常用班次. Keep 临时调整 menu absent.
- [x] Run both cloud tiers and Debug using `node tools/verify.mjs --steps=offline,debug`; run scoped diff check; document device re-test steps without claiming a device UI run.
