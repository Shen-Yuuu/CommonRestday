# Plan Title and Cold-Start Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Switching fixed plan types updates the title; selecting Other retains it. Start independent cloud reads as soon as local storage is ready.

**Architecture:** Keep the existing plan form and change its selection method. Split storage readiness from the initial cached calculation in EntryAbility so foreground plan refresh no longer waits behind snapshot networking. Reuse existing single-flight refresh, serial calculation, session fences, and manual-only recovery.

**Tech Stack:** ArkTS / ArkUI, Node production-method tests and isolated lifecycle adapters, existing offline/debug gate.

**Spec:** User request on 2026-10-10: title follows plan type except Other; cloud state updates are delayed after cold startup.

## Global Constraints

- Keep layout and cloud protocols unchanged; no optimistic acceptance, deleted caches, background polling or automatic replay of uncertain writes.
- Storage must be ready before any sync/cleanup. Storage failure must prevent dependent work without breaking the local error UI.
- Cache-based initial calculation must not wait for cloud; plan refresh and snapshot refresh begin independently.
- Preserve warm-start day rollover, push consent, session revocation and failed-sync pause behavior.
- Inline implementation; the named execution sub-skill is unavailable. No delegation or commits in the dirty user checkout.

### Task 1: Plan title selection

**Files:** `entry/src/main/ets/component/WindowDetailSheet.ets`, `tools/test/plan-form-regression.mjs`, `docs/prototype/index.html`.

**Interface:** `pickKind(idx: number): void`, `onTitleChange(v: string): void`.

- [x] Change regression expectations first: fixed labels replace a manually edited title; Other retains both a preset label and typed text; invalid indices do nothing.
- [x] Run `node tools/test/plan-form-regression.mjs` and confirm failure under the old behavior (Other cleared the title instead of retaining 出游).
- [x] Implement selection:

```typescript
if (!Number.isInteger(idx) || idx < 0 || idx >= PLAN_KINDS.length) return;
if (PLAN_KINDS[idx].key !== OTHER_PLAN_KIND_KEY) this.title = PLAN_KINDS[idx].label;
this.kindIdx = idx;
```

- [x] Remove the obsolete titleTouched state and keep the HTML prototype selection consistent; run the focused test.

### Task 2: Cold startup scheduling

**Files:** `entry/src/main/ets/entryability/EntryAbility.ets`, new `tools/test/startup-sync-regression.cjs`, `tools/test/run.mjs`.

**Interface:** `initChain: Promise<void>` represents only initialized DB, settings and seed data. A first-foreground flag distinguishes cold startup from warm day rollover.

- [x] Execute actual EntryAbility with mocked kits/storage/feature services. Hold snapshot networking and verify shared plan refresh and cached calculation can start, but neither can start before storage readiness. Verify failure, warm rollover and cleanup waiting.
- [x] Confirm the held-snapshot test fails with the old full-initChain implementation (initial calculation was network-dependent).
- [x] Set initChain to `Promise.all([Db.init(...).then(...ensureSeeded...), SettingsStore.init(...)])` followed by a void resolution. Separately schedule `onScheduleChanged(true)` and catch/log startup failures.
- [x] On first foreground, schedule `pullToRefresh()` after initChain without waiting for cached calculation. On later foregrounds, retain the existing day-rollover check after initChain. All dependent foreground promise chains catch failures.
- [x] Keep `PlanNotifications.onForeground()` after storage readiness; its authenticated connection check, plan refresh, and consent-bound token renewal stay unchanged.
- [x] Add the lifecycle test to the existing offline runner; run it and existing refresh-performance tests.

### Task 3: Verify and handoff

- [x] Run `node tools/verify.mjs --steps=offline,debug`; record actual results and device timing limitations.
- [x] Document device checks and explain that SDK auth/network/cloud cold starts can still add latency; no guaranteed latency number without device measurements.
- [x] Handoff: updated client only, no cloud redeployment; see `docs/validation/2026-10-10-plan-title-startup-sync.md`.
