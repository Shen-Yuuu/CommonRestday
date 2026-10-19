# Unified Pairing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. That skill is not installed here; execute inline with the explicit checks below, without delegation.

**Goal:** One user-visible pairing workflow activates both schedule synchronization and authenticated encrypted shared plans.

**Architecture:** A bounded encrypted offer on PairMemberBinding lets the existing schedule partners exchange the dateplan invitation without a second user code. A single-flight, consent-scoped coordinator drives existing secure setup methods; the UI shows success only after the local secure session and key are activated.

**Tech Stack:** ArkTS/ArkUI, HUKS AES-GCM, existing SHA256 adapter, TypeScript AGC Server SDK 1.0.5, CloudDB, Node isolated regression fixtures.

**Spec:** docs/plans/2026-10-14-unified-pairing-design.md

## Global Constraints

- No key export, UID authentication substitution, plaintext offer persistence, notification auto-consent, new shared-plan acceptance rules, or cloud deployment.
- Existing ACTIVE data is preserved. Explicit per-schedule-pair consent gates automatic continuation.
- UI polling: visible/foreground only, single flight, 3 seconds, maximum 60 seconds, stop on failure.
- Only Administrator accesses the new model fields; update schema before server.
- Do not commit the existing dirty worktree or unrelated user changes.

### Task 1: Encrypted offer protocol and authenticated server handoff

**Files:** cloud-backend/cloudfunctions/dateplan/{bootstrap.ts,dateplan.ts,models.js,models.d.ts}; cloud-backend/clouddb/objecttype/PairMemberBinding.json; cloud-backend/test/dateplan-bootstrap.mjs; cloud/src/main/ets/api/{PlanPairingBridge.ets,DatePlanCloudApi.ets}; cloud/Index.ets.

**Interfaces:** server publishLink(token,pairId,route,offer), discoverLink(token,route). Client BridgeOffer {pairId,publicKey,inviteCode,expiresAt}, bridge seal/open bound to legacy pair and both UIDs.

- [x] Add a failing server regression that calls api.publishLink and expects owner-only publication and ciphertext-only discovery; run `node cloud-backend/test/dateplan-bootstrap.mjs` and record missing-method failure.
- [x] Add default-empty bootstrapRoute/String and bootstrapOffer/Text plus exact reflection/index declarations; add authenticated wrappers. Publication reads the existing binding in a transaction, rejects revoked/non-creator/changed route or offer, and discovery returns at most five live WAITING/PENDING encrypted offers.
- [x] Implement domain-separated SHA256 route and random-nonce AES-GCM offer, matching both legacy UIDs, secure pair/public key, code and safe expiration; invalid or stale values return null. Do not derive long-term keys from the short code.
- [x] Run server bootstrap, original contract and ES5 suites; all must pass, including schema/reflection/permissions.

### Task 2: Durable single pairing coordinator and consent

**Files:** feature/src/main/ets/usecase/{UnifiedPairingUseCase.ets,UnifiedPairingAdapters.ets,ProfileSettingsService.ets}; data/src/main/ets/settings/SettingsStore.ets; feature/Index.ets; tools/test/unified-pairing-regression.cjs.

**Interfaces:** UnifiedPairingResult {code,phase}; UnifiedPairingUseCase.local():Promise<UnifiedPairingResult>; advance(consent:boolean):Promise<UnifiedPairingResult>. Phases NOT_PAIRED/UPGRADE/CONNECTING/WAITING/READY/FAILED. Adapter exports unifiedPairing().

- [x] Write isolated two-device ports: creator create publishes encrypted offer, peer opens and joins, creator resumes then confirms, peer resumes ACTIVE; assert no extra user code. Client cases were added alongside implementation; the server entry had the recorded failing test before implementation.
- [x] Implement single-flight and context/epoch fences around every asynchronous boundary. Check existing ACTIVE session before starting, preserve pending original intent, reject multiple valid offers, never reset unresolved/revoked flow automatically. Consent is persisted for the exact legacy pair, not inherited on a new pair.
- [x] On successful schedule join/confirm record consent; automatically progress only after authoritative schedule ACTIVE. Existing disconnected users must explicitly grant completion consent. Clear consent on cancelling/forgetting/unpairing and retain original secure deletion ordering.
- [x] Run coordinator, secure setup and lifecycle fixtures, including failed offers, lost replies, stale contexts, old ACTIVE preservation, gating and cleanup retention.

### Task 3: One visible flow and lifecycle integration

**Files:** entry/src/main/ets/component/UnifiedPairingStatus.ets; entry/src/main/ets/view/MeView.ets; entry/src/main/ets/util/PlanNotifications.ets; tools/test/{unified-pairing-regression.cjs,run.mjs}.

- [x] Assert MeView no longer renders SecurePairingSetup and new component has foreground/visible/timer-stop guards.
- [x] Render unified progress within the cloud pairing block. Existing short-code entry stays only for schedule initiation; unified status offers completion/continue, no second short code or separate disconnect. Main status is success only when READY.
- [x] Continue already-authorized setup on foreground; no background polling. Stop visible polling after 60 seconds/error and preserve progress for manual continuation. Coalesce with the coordinator flight.
- [x] Register regression in both execution and failedRun gate, then run `node tools/verify.mjs --steps=offline,debug,release,ohostest,perf`.

### Task 4: Cloud source synchronization and operator handoff

**Files:** docs/validation/2026-10-14-unified-pairing.md; both existing cloud projects' dateplan source and PairMemberBinding definition; generated worker ZIPs.

- [x] Byte-copy only changed source/model via apply_patch, preserve configs/dependencies/credentials, verify SHA256 parity.
- [x] Rebuild `node tools/build-dateplan-push-worker.mjs` and `node tools/build-dateplan-push-worker.mjs --wake`; validate ZIP roots and imports.
- [x] Document exact incremental deployment order, tests actually run, old-pair upgrade, no-notification-auto-consent and real-device/online evidence boundary.
