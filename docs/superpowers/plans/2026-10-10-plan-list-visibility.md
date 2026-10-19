# Current Plan List Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove withdrawn and ended plans from the current plan list without deleting persisted records.

**Architecture:** Explicit local-epoch-minute visibility policies shared by local/cloud cards and pending badges. Refresh visibility locally while mounted and on foreground return; keep database records, confirmed occupancy, and historical calendars unchanged.

**Tech Stack:** ArkTS / ArkUI, production-policy Node regression tests, existing offline/debug verification runner.

**Spec:** The user's 2026-10-10 request: withdrawn cards and past plans must no longer occupy the plan list. Ended means end <= current minute; ongoing plans remain. Withdrawal of an amendment retains its original confirmed plan. Future amendments remain actionable even if the original interval has ended.

## Global Constraints

- Preserve unrelated working-tree changes; no data deletion or cloud redeployment.
- Filter terminal shared states (withdrawn, cancelled, declined, expired).
- Use the project's local epoch-minute clock, not UTC epoch minutes.
- Keep unknown-result request recovery available and validate cached records before filtering.
- No cloud requests or schedule recomputation for clock-only visibility updates.
- Implement inline: the referenced execution sub-skill is unavailable in this session; do not delegate or delay this authorized bug fix.

## Tasks

### 1. Regression coverage and visibility policy

- [x] Add failing tests to `tools/test/shared-plan-experience-regression.cjs` for terminal states, end boundaries, ongoing/cross-day plans, amendment withdrawal, future amendments, source preservation, and merged ordering.
- [x] Implement explicit-time policies in `feature/src/main/ets/model/SharedPlanPresentation.ets`; export them from `feature/Index.ets`.
- [x] Run focused tests and verify red-to-green behavior (terminal-state test initially returned 3 visible records instead of 0).

### 2. View and badge integration

- [x] Filter before counting visible pending plans in `SharedPlanViewService.ets`.
- [x] Integrate local/shared visibility and timer cleanup in `PlansView.ets`; keep raw local cache for re-filtering.
- [x] Update the common-page pending badge from visible plan rows in `CoTimeView.ets`.
- [x] Clarify raw plan query documentation without changing historical queries.

### 3. Verification and handoff

- [x] Run focused presentation/drawer tests and `node tools/verify.mjs --steps=offline,debug`.
- [x] Record verified results and device-test limitations in `docs/validation/2026-10-10-plan-list-visibility.md`.
- [x] Handoff: cover-install the updated client; no cloud redeploy is required.
