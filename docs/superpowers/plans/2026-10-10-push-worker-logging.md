# Push Worker Platform Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make worker execution observable through AGC's logger without exposing secrets or weakening dispatch authentication.

**Architecture:** Keep the callback entry and push delivery protocol unchanged. Resolve an invocation-local fourth-argument/global logger, emit fixed diagnostic fields before callback, and parse a bounded set of scheduler envelopes with unchanged secret validation. A cloud scheduler that never invokes the function cannot be repaired by handler code; provide a separate operator check.

**Tech Stack:** TypeScript, AGC Node.js callback runtime, local ES2020/ES5 contract tests.

**Spec:** `docs/validation/2026-10-10-push-worker-setup.md` and the user's 2026-10-10 request to fix worker logging and investigate missing scheduled invocations.

## Global Constraints

- No real service-account keys, event bodies, tokens, raw errors or arbitrary event key names in logs.
- Preserve timingSafeEqual, callback result codes, retry limits, and TIMER-only deployment.
- No changes to phone UI, certificate, pairing data, or cloud tables.
- Preserve unrelated dirty files; no Git commit/staging. Unavailable executing-plans skill: execute inline with checkpoints as explicitly requested.

### Task 1: Worker logging and safe event compatibility

**Files:** `cloud-backend/cloudfunctions/dateplan/dispatch.ts`, `cloud-backend/test/dateplan-contract.mjs`.

**Interfaces:** `handler(event, context, callback, logger?)`; callback retains `{code, providerAccepted}`. Logs use `FORTWO_PLAN_PUSH`, fixed build, stages, fixed input shape, booleans and counts only.

- [x] Add tests for fourth argument/global logger precedence, invocation-local loggers, auth rejection before DB, supported envelopes, malformed/ambiguous input rejection, and no secret output.
- [x] Run `node cloud-backend/test/dateplan-contract.mjs`; observed missing logger records before implementation.
- [x] Implement platform logging, fixed diagnostic stages, and bounded envelope parsing, without bypassing authentication.
- [x] Run contract tests with modern and `--es5` targets plus SDK strict/noEmit: each 57 passed.

### Task 2: Rebuild and operator handoff

**Files:** sibling cloud project `dispatch.ts` copies; `docs/validation/2026-10-10-push-worker-setup.md`; generated `../.crdtest/dateplanpush.zip`.

- [x] Synchronize only changed worker source using apply_patch; verify hashes.
- [x] Rebuild with `node tools/build-dateplan-push-worker.mjs`; ZIP root dispatch.js hash matches generated source, contains diagnostic build, and credential file-name scan is clean.
- [x] Document reupload, unchanged environment variables, manual log verification, and disable/enable scheduler check. Do not claim scheduler fixed without actual automatic invocation evidence.
- [x] Check diff whitespace and record local test results; cloud reupload and automatic invocation verification remain operator actions, not completed deployment claims.
