# Manual Cloud Sync Retry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After snapshot sync failure, stop automatic retries and provide one explicit retry action in 「我的」 only.

**Architecture:** Preserve the persisted three-state format. Gate both automatic push and pull whenever either failure state is stored; a separate user-triggered path bypasses that gate for one bounded push/pull attempt. Present the failure and action in MeView only.

**Tech Stack:** ArkTS/ArkUI API 26, existing Preferences/Cloud API, Hypium offline runner and hvigor.

**Spec:** `docs/plans/2026-09-30-manual-cloud-sync-design.md`

## Global Constraints

- Healthy paired sync remains automatic; local edits and calculations never fail because cloud failed.
- Old `RETRY|day|code` values remain readable and become manual-only without migration.
- Transient failure must not clear on a partial push/pull success; one manual attempt at a time.
- Cloud failure copy appears only in 「我的 → 伴侣与同步」; unrelated local/stale/missing-data notices remain.
- Preserve all unrelated dirty-worktree changes; no simulator operation is part of this implementation.

---

### Task 1: Persistent pause and copy

**Files:** Modify `feature/src/main/ets/model/CloudSyncRules.ets`, `feature/Index.ets`, `entry/src/test/CloudSyncRulesTest.ets`.

**Interfaces:** `pushBlockedToday(raw: string, today: number): boolean` continues to read the old wire format but returns `true` for both failed outcomes regardless of day. `canManuallyRetry(s: SyncState): boolean` returns `true` only for the `RETRY` outcome. `syncStateNoteOf` no longer promises next-day retry.

- [ ] **Step 1: Write failing assertions** for yesterday's `RETRY` remaining blocked, manual eligibility (`RETRY=true`, `BLOCKED=false`, `SYNCED=false`), and no automatic-retry promises in failure copy.
- [ ] **Step 2: Run** `node tools/test/run.mjs` with `CRD_TIER=open`; expect the new assertions to fail.
- [ ] **Step 3: Implement** the pure rules and export the new eligibility predicate in `feature/Index.ets`.
- [ ] **Step 4: Rerun** the offline suite; expect the new rules to pass.

### Task 2: One explicit cloud attempt

**Files:** Modify `feature/src/main/ets/usecase/ScheduleUseCase.ets`; add or update focused tests in `entry/src/test` and register them in `entry/src/test/List.test.ets` / `tools/test/run.mjs` only if the runner requires it.

**Interfaces:** `ScheduleUseCase.retryCloudSync(): Promise<boolean>` performs at most one in-flight attempt; it is only callable when cloud is enabled, paired, and the stored state is retryable. Its success requires both push and pull success; failure keeps the latest failure state. Normal pull and merged push inspect the persistent pause gate.

- [ ] **Step 1: Add failing tests** for no automatic cloud call after failure across a day boundary, one manual push/pull attempt, and duplicate-tap coalescing.
- [ ] **Step 2: Run** the offline suite; expect the new cases to fail.
- [ ] **Step 3: Implement** the guarded normal paths and explicit retry. Pull success must be reported separately from cached-fallback success. Only full success clears the failure; refresh derived windows from the newly obtained cached snapshot without a second network request.
- [ ] **Step 4: Rerun** focused and complete offline tests; inspect the cloud call counts.

### Task 3: 「我的」 action and page cleanup

**Files:** Modify `entry/src/main/ets/view/MeView.ets`, `HomeView.ets`, `CoTimeView.ets`; update the affected cloud protocol and operations runbook paragraphs.

**Interfaces:** MeView's failure `NoticeBar` receives `actionLabel: '手动重试'` only for retryable state and an `onAction` guarded by a busy state. The other two pages do not read or render cloud sync failure state.

- [ ] **Step 1: Remove** only cloud failure display branches and their dedicated page state/imports from HomeView and CoTimeView; preserve local/stale/missing-data notices.
- [ ] **Step 2: Add** MeView's busy latch, explicit action, reloaded status, and truthful success/failure feedback.
- [ ] **Step 3: Revise** protocol/runbook text that still says day rollover retries automatically or that manual retry is absent.
- [ ] **Step 4: Run** `node tools/verify.mjs --steps=offline,debug,release,ohostest,perf`; if an environment step cannot run, report its exact boundary without claiming device acceptance.

## Self-review

All design requirements map to Tasks 1–3. The persisted wire values and cloud-unpair debt queue are unchanged. Device acceptance remains the user's manual test, not a simulated claim.
