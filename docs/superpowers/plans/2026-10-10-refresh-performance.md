# Refresh Performance Implementation Plan

> **For agentic workers:** Execute inline task-by-task. No delegation or commit: user authorized direct implementation in the existing dirty checkout; executing-plans is unavailable in this session.

**Goal:** Eliminate safe-area white strips and avoid redundant networking/recomputation while preserving consistency.

**Architecture:** Rendering-only safe-area expansion; cached-only presentation and local save recomputation. Operation-scoped binding proof plus write-boundary-aware single-flight reads, and separate shared-record versus availability notifications.

**Tech Stack:** ArkTS / ArkUI API 26, RDB, AGC cloud objects, Node adapter regressions, Hypium.

**Spec:** docs/plans/2026-10-10-refresh-performance-design.md

## Global Constraints

- Preserve existing layout, theme, confirmation, conflict, session fences and durable request IDs.
- No cloud deployment, data clearing, completed-result TTL caching, automatic ambiguous-write retries, or commits.
- Keep safe content layout and keyboard avoidance; extend SYSTEM rendering only.

### Task 1: Immersive backgrounds

**Files:** Modify Index.ets, AppNavigator.ets, CycleEditor.ets, remaining independent page roots. Test tools/test/refresh-performance-regression.cjs.

**Interface:** Existing roots retain percent width/height and gradients.

- [x] Assert each route root uses system rendering expansion; run regression to see missing-root failure.
- [x] Add to root backgrounds, not scrolling children:
```ets
.expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
```
- [x] Re-run checks and review keyboard/content positions through declared layout contracts. Navigation shares page gradient; FadingHeaderSurface extends its top background. Actual rendered-device acceptance remains in the validation document.

### Task 2: Cached reads and local saves

**Files:** ScheduleUseCase.ets, ScheduleOverviewQueryService.ets, ScheduleCommandService.ets, PlanUseCase.ets, ProfileSettingsService.ets.

**Interface:** Expose existing partnerBusyWithoutNetwork(startEpochDay: number, params: EngineParams): Promise<PartnerBusyResult | null>; no semantic fallback change.

- [x] Assert getDayView/getWeekLanes do not invoke buildPartnerBusy; local write services call onScheduleChanged(true).
- [x] Replace query network source with partnerBusyWithoutNetwork. Replace local save calls with cached-only recompute; leave cold entry, pairing and daily rollover network-capable.
```ets
await ScheduleUseCase.onScheduleChanged(true);
const partner = await ScheduleUseCase.partnerBusyWithoutNetwork(epochDay, dayParams);
```
- [x] Run query/cache and schedule command regressions.
- [x] Move network waiting outside RECOMPUTE_QUEUE, keeping network/cursor work in SNAPSHOT_PULL_QUEUE. Re-read inputs only after the wait; fence snapshot response/decryption and cache writes by the active pair. Isolated deferred-network test proves local calculation completes before network release and then the later calculation sees the new local version.

### Task 3: Shared-plan operation efficiency

**Files:** SecureSharedPlanGateway.ets, SharedPlanUseCase.ets, SharedPlanLocalAdapters.ets, SharedPlansPanel.ets, CoTimeView.ets; tests SharedPlanUseCaseTest.ets and shared-plan-secure-regression.cjs.

**Interfaces:** SharedPlanLocalPort.changed?(): void; crdSharedPlanTick; internal SingleFlight<T>.run(work): Promise<T>, invalidate(): void.

- [x] Change RPC count assertions to capabilities/read and capabilities/mutate; add proof reuse, consumed/clone proof, logout and generation rejection tests. Add pending/no-recompute, accepted/cancel recompute and overlapping refresh/write boundary cases.
- [x] Implement single-use reference-scoped proof. Retain fresh credential and all session/UID fences; direct calls use capabilities fallback.
- [x] Compare old/new sharedPlanActivity before storage.apply and recompute only changed occupied intervals. Broadcast shared-record changes separately. Preserve failed recomputation for a later explicit refresh.
```ets
if (updates.length > 0 && this.local.changed !== undefined) this.local.changed();
if (occupancyChanged) await this.local.recompute();
```
- [x] Wrap queued refresh in SingleFlight; invalidate before mutation queues. Share schedule pulls while invalidating before cached-only (write) recomputations. LatestReadQueue batches plan-page and shared-panel reads, preserving LatestLanding and unmount cancellation.
- [x] Run targeted tests, then complete closed/open offline suites and Debug build.

### Task 4: Evidence and handoff

**Files:** docs/validation/2026-10-10-refresh-performance.md.

- [x] Inspect scoped diff and failing logs; repair within approved scope.
- [x] Record test totals, exact RPC reductions and unverified real-device/system-bar/AGC timing boundaries. Mark completed steps; provide device acceptance instructions without requiring data reset.
