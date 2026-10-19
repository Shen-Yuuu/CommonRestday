# Weekly Roster App Implementation Plan

> Executed inline in the current task; no delegation, cloud deployment or device installation.

**Goal:** Implement the approved dated-week design and consolidate work adjustments into ＋日程.

**Architecture:** Pure domain roster helpers; owner-scoped versioned JSON persistence through existing meta repository; one serialized feature service; shared daily editor and weekly draft view. Preserve legacy cyclic reads.

**Tech Stack:** ArkTS, ArkUI V1 consistent with current pages, RDB meta storage, existing encrypted snapshot pipeline, offline Hypium and Hvigor.

**Spec:** `docs/plans/2026-10-09-weekly-roster-app-design.md`

## Global Constraints

No data wipe, no cloud deployment, no emulator installation, no unrelated changes, no broad Git staging. Keep current brand tokens and direct native color picker. Existing blank-work users must not become unknown unless work scheduling is enabled.

## Task 1: Domain and persistence

Files: domain Types/WeeklyRoster and exports; feature WeeklyRosterService and exports; ScheduleRepo segment meta handling and partner cleanup.

Interfaces: `rosterDayOf(schedule, epochDay): RosterDay`, `rosterError(days): string`, `copyRosterWeek(source, current, targets, strategy): RosterDay[]`, `WeeklyRosterService.read(owner): Promise<WeeklyScheduleState>`, `loadDays(owner,start,count)`, `saveDays(owner,days,acknowledge)` and `savePersonal(owner,entry,acknowledge)` returning ScheduleCommandResult plus message/warning.

- [x] Add pure tests for two shifts, split shifts, overnight collision, legacy fallback and copy strategies.
- [x] Implement deep snapshot and validated owner-key JSON load/save; never fall back to empty on corrupt JSON.
- [x] Persist all changes using a serialized read/validate/write; recompute only after successful write.

## Task 2: Calculation and presentation

Files: CommonFreeEngine, AvailabilityBuilder, ScheduleUseCase, ScheduleOverviewQueryService, TodayAgenda, CommonTimeQueryService.

- [x] Feed dated snapshots and personal entries into local and snapshot input.
- [x] Use explicit day precedence; UNKNOWN conservative occupancy only in enabled work mode; exclude UNKNOWN from claims of actual busy work.
- [x] Derive week blocks and today agenda from the same concrete entries, preserving split gaps and cross-day edges.
- [x] Run `node tools/test/run.mjs`; retain all old engine tests and add new roster coverage.

## Task 3: Weekly and daily UI

Files: new WeeklyRosterView; DayShiftSheet; CycleEditor wrapper; ScheduleHub; ScheduleEditor.

- [x] Build seven-date strip, dated row tickets, independent current-week draft, copy/repeat explicit ranges and strategies.
- [x] Reuse one daily editor with per-date save or parent draft callback; allow multiple presets and manual times.
- [x] Add multi-segment preset form and system time selectors; preserve direct color picker and old advanced options.
- [x] Remove temporary-adjustment menu and old cycle editor UI, keep legacy route compatibility.

## Task 4: Personal entry and acceptance

Files: new ScheduleEntrySheet; HomeView; TodayOverview; regression tests and test runner.

- [x] Wire ＋日程 → personal/work; use separate personal storage, show overlap confirmation, never create plan invitations.
- [x] Update source regressions only where old requirements were superseded; add assertions for the new connections.
- [x] Run full offline tests in both cloud flag tiers, `node tools/verify.mjs --steps=debug`, and `git diff --check` on touched files.
- [x] Record user steps: preserve installed data, test current-week save, split shifts, copy overlap, unknown/rest, personal agenda and paired snapshot sync.

## Verification outcome

2026-10-09: `node tools/verify.mjs --steps=offline,debug` ALL PASS. Both cloud flag tiers: 365 passed, 0 failed, typecheck 0 errors. Added 28 Hypium cases and 5 separate production loader/check integration cases. Debug BUILD SUCCESSFUL with 281 ArkTS warnings versus the unchanged baseline of 289. Scoped tracked-file `git diff --check` passed. No rendered/device/real-cloud evidence is claimed.

Operator acceptance: `docs/validation/2026-10-09-weekly-roster-app.md`.
