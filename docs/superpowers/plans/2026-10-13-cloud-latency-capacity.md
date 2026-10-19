# Cloud Latency and Capacity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce cloud round trips and UI refresh contention, decouple provider latency behind a validated durable wake channel, and replace lifetime limits with bounded activity plus encrypted history.

**Architecture:** Compatible server storage-v2 behind a default-closed gate; binding-anchored CAS counters/change pages and archive proofs. The client persists verified change pages before acknowledging their cursor or archive eligibility. A separate signed wake worker handles a specific durable outbox event; existing synchronous delivery stays the deployment fallback.

**Tech Stack:** ArkTS/ArkUI, AGC Server SDK 1.0.5, CloudDB, HUKS, Node ES2020/ES5 contract adapters, existing SQLite and offline/build verification.

**Spec:** `docs/plans/2026-10-13-cloud-latency-capacity-design.md`; primary platform evidence in `docs/research/2026-10-13-agc-plan-dispatch.md`.

## Global Constraints

- Preserve all unrelated dirty-tree changes; no commits or destructive reset. Edits use apply_patch; model generation may use a documented mechanical generator.
- Do not weaken server auth, same-partner proof, original request/digest/ciphertext reuse, state-version CAS, local generation fences or notification consent.
- `FORTWO_PLAN_STORAGE_V2` and `FORTWO_PLAN_ASYNC_PUSH` default false until deployment prerequisites are verified.
- No naked asynchronous provider send, no unverified trigger guarantee, no automatic retransmission of uncertain user decisions.
- Batch/page size <= 50; archive and cleanup are bounded; original encrypted historical content and immutable request evidence remain readable until explicit cleanup.
- Inline execution: named execution sub-skill unavailable. Research delegation only; no implementation agents.

### Task 1: Storage and contract groundwork

**Files:** new object definitions under `cloud-backend/clouddb/objecttype/`; `cloud-backend/cloudfunctions/dateplan/models.js`, `models.d.ts`; new `storage-v2.ts`; `service.ts`, `protocol.ts`; `cloud-backend/test/dateplan-contract.mjs` and a focused storage-v2 test.

**Interfaces:** `storageEnabled(): boolean`; helpers consume a verified binding and use its existing CAS anchor. A change page contains `plans`, `cursor`, `more`, `syncVersion: 2`, and verified binding body. Archive candidates contain only `{ planId: string, stateVersion: number }`.

- [x] Add admin-only model definitions and keep reflection types identical using mechanical generation.
- [x] Add failing tests for archived request replay, archived plan ID rejection, counted active capacity, two-member/version archive votes, and bounded sequence pages.
- [x] Implement binding-anchored initialization, append changes within mutation/expiry transactions, immutable compressed receipt archive, and full encrypted plan archive.
- [x] Read every transaction query before any writes; update counters and canonical/archive rows atomically.
- [x] Implement `readChanges` and `acknowledge` authenticated server methods; preserve v1 behavior when storage gate is closed.
- [x] Extend revoke/cleanup to all new tables with bounded progress and safe unfinished status.
- [x] Run cloud contract tests in both targets; old idempotency, conflict and revocation tests must remain green.

### Task 2: Independent signed wake delivery

**Files:** new `wake.ts`; `dateplan.ts`, `push.ts`, `dispatch.ts`; worker build tool; new wake tests.

**Interfaces:** `dispatchEvent(eventId: string, delivery?: PushDelivery): Promise<number>`; `enqueueWake(eventId: string): Promise<boolean>`; `wake.handler(event, context, callback, logger?)`.

- [x] Add failing tests for exact-event priority, repeated event/active lease, malformed/forged trigger input and slow provider separation.
- [x] Reuse claim/finish; both synchronous fallback and DB worker dispatch exactly the committed event rather than scan old pair backlog first.
- [x] Write single wake via collection.insert after commit; sign fixed id/pair/event/time fields with server-only dispatch secret.
- [x] Enforce model/zone/size/signature/repository checks in DB-only handler; TIMER authentication remains unchanged.
- [x] Default async flag closed. When enabled, return after durable wake insertion; on insertion failure await fallback without changing the committed business result.
- [x] Package dedicated dateplanwake and dateplanpush ZIPs without secrets; verify roots/entry paths and tests.

### Task 3: Verified incremental client and view lifecycle

**Files:** `SharedPlanUseCase.ets`, `SecureSharedPlanGateway.ets`, `SharedPlanPersistence.ets`, `SharedPlanRepo.ets`, `SharedPlanSchema.ets`, `DatePlanCloudApi.ets`, `PlanNotifications.ets`, navigation and Home/CoTime/Me/Plans views, existing refresh tests and new incremental tests.

**Interfaces:** optional gateway change-read/ack methods preserve existing isolated ports. Local cursor is scoped to pair/actor/generation. Root selection publishes or passes active-tab state; each view has a mounted/active read fence.

- [x] Add failing tests: page must persist before cursor commit; failed decode must not advance; equal cursor avoids repeated decryption; pending actions do not recompute; mutation invalidates shared reads.
- [x] Add durable local cursor and clearing/restore fences; apply a max-50 verified page before recording its cursor.
- [x] Implement read-only sync with verified binding in its response, without bypassing peer proof or using a cached authorization for writes. Retain compatibility fallback when server explicitly disables v2.
- [x] Submit archive votes only after successful local sync and only for ended/no-amendment or terminal versions.
- [x] Keep in-flight read coalescing, bounded pages, errors preserving last valid state, and explicit unknown-write recovery.
- [x] Gate background tabs' reads and merge page invalidations; entry into a tab reads cached current data without a full-screen loading reset.
- [x] Retain original snapshot failure pause/manual retry; reduce duplicate snapshot/auth/push work only where tests show equivalent fences.
- [x] Run focused storage, lifecycle, refresh-performance and presentation tests.

### Task 4: Full verification and deployment handoff

- [x] Run `node cloud-backend/test/dateplan-contract.mjs` and `--es5`; run new tests in the same gate.
- [x] Run `node tools/verify.mjs --steps=offline,debug,release,ohostest,perf` without increasing warning baselines.
- [x] Sync approved source/models to both cloud projects; rebuild and inspect worker packages, not user credentials.
- [x] Record actual evidence in `docs/validation/2026-10-14-cloud-latency-capacity.md` and provide exact staged deployment/flag/device steps.
- [x] State remaining platform trigger/timer verification and real-device latency honestly; never mark cloud resources or notifications verified from local tests.

## Completion evidence (2026-10-14)

Local implementation and verification complete: cloud contract 57 + storage 10 + wake 4 in ES2020/ES5; new client regressions 10; offline closed/open 368 each; debug/release/ohosTest/perf all pass without raising warning baselines. Both local cloud projects match scoped source hashes; worker ZIPs rebuilt and inspected. Deployment, automatic DB/TIMER execution and real-device latency remain explicit operator gates, not claimed completed. See the validation report and adjacent operator checklist.
