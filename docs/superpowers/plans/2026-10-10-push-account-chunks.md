# Push Account Chunks Implementation Plan

> **For agentic workers:** Execute inline. User explicitly authorized implementation; executing-plans is unavailable. Do not delegate, commit, log in, deploy, or read real credentials.

**Goal:** Support bounded segmented cloud environment configuration and regenerate the notification worker package.

**Architecture:** One account parsing/environment installation module shared by dateplan and dispatch. Mutually exclusive legacy JSON versus counted chunks, with fail-closed validation and warm-instance replacement.

**Tech Stack:** TypeScript, Node.js crypto, AGC Server SDK 1.0.5, PowerShell, local SDK contract harness.

**Spec:** docs/plans/2026-10-10-push-account-chunks-design.md

## Global Constraints

- Parts 1–32, each 1–512 characters, total 16384 UTF-8 bytes; preserve JSON escape sequences by concatenating before parsing.
- No real private keys, external deployment, credential logging, data clearing or manual reserved environment variable creation.
- Retain original single-JSON configuration when no chunk configuration exists.

### Task 1: Cloud parser and worker injection

**Files:** Create cloud-backend/cloudfunctions/dateplan/push-account.ts; modify push.ts and dispatch.ts; test cloud-backend/test/dateplan-contract.mjs.

**Interfaces:** `PushAccount { project_id: string; key_id: string; private_key: string; sub_account: string; }`; `readPushAccount(env: Record<string, string | undefined> = process.env): PushAccount`; `installPushAccountEnvironment(source: Record<string, string | undefined>): void`.

- [x] Add and run failing tests for reconstructed signing, legacy compatibility, mixed/missing/extra/count/size/type rejection and warm-instance replacement.
- [x] Implement counted concatenation, sanitized PUSH_CONFIG_INVALID rejection, four-field type checks and account-specific environment replacement; import reader in push.ts and installer in dispatch.ts.
```ts
const account = readPushAccount();
if (context?.env) installPushAccountEnvironment(context.env);
```
- [x] Run `node cloud-backend/test/dateplan-contract.mjs` and the same command with `--es5`; both strict SDK checks and behavior suites must pass (51 each). Worker preflight reports fixed account/project/key errors before database access.

### Task 2: User tool, synchronized sources and worker package

**Files:** Create tools/prepare-push-account.ps1, tools/test/push-account-tool-regression.mjs; modify tools/build-dateplan-push-worker.mjs; update cloud README/operator steps and docs/validation/2026-10-10-push-worker-setup.md.

**Interface:** `prepare-push-account.ps1 -Path <local-json> [-PartLength 128..512] [-CopyPart 0..32 | -CopyEnvironmentJson]`; default metadata only, part 0 copies N. Worker ZIP contains push-account.js and no credentials.

- [x] Test with generated fixture account that default output contains no key, all chunks fit, reconstruction preserves the original key, and invalid inputs return sanitized errors. No real files outside synthetic fixtures are read.
- [x] Implement clipboard-only opt-in output and account summary; add push-account to both build file lists.
```js
for (const name of ['identity', 'push-account', 'push', 'dispatch']) { /* existing transpilation */ }
```
- [x] Compare source hashes for only changed files in FortwoCloud and CloudDevSpikeOfficial; sync exact account/push/dispatch files with apply_patch, preserve unrelated files. All six module comparisons match; README notes corrected in both projects.
- [x] Run tool regression (4 passed); build ZIP with `node tools/build-dateplan-push-worker.mjs`; verify all six root module hashes match the generated build, Server SDK is included, and no PEM/P12/env/service-account/agconnect-services credential files are packaged.
- [x] Document exact environment variables, local clipboard commands, event-call function/dispatch.handler/TIMER-only setup, scheduler secret, tests and platform credential/trigger-format boundaries. Do not claim online delivery is verified.
