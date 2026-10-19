# Conservative redundancy cleanup implementation plan

> Execute inline in this chat; user approved the conservative scope. Do not delegate or commit the user's existing changes.

**Goal:** Reduce distracting UI copy and verifiable production redundancy while retaining behavior, recovery paths, historical designs, tests and deployment materials.

**Architecture:** Produce a read-only source/resource inventory, inspect each candidate, then make a bounded cleanup. Keep historical-only animation sources/assets outside production resource directories with their original tests/generators pointing at the archive. Preserve immutable backups of removed files outside the project.

**Tech Stack:** ArkTS/ArkUI, TypeScript AST import inspection, Node offline regression harness, PowerShell filesystem metadata and build wrapper.

**Spec:** `docs/plans/2026-10-17-conservative-cleanup-design.md`.

## Constraints

- No changes to sync/transaction/crypto/authorization/old-data migration semantics.
- No deletion of routes, public APIs, permissions, privacy text or recovery solely on a static unused warning.
- No broad directory deletion; exact targets only; backup and verify paths/hashes before deletion.
- Preserve user changes and untracked design assets. Test assertions about obsolete presentation copy may change, behavioral assertions may not be weakened.

## Task 1: Inventory and evidence

- [x] Add/run `tools/audit-redundancy.mjs` for first-party main source, named imports, private member candidates and packaged media references; report candidates only.
- [x] Cross-check candidate consumers in tests, prototype HTML/generators, resource manifests, route and module entrypoints.
- [x] Record the selected exact files with reasons; save original copies for files removed/moved.

## Task 2: UI copy cleanup

- [x] Remove repeated introduction/usage labels in schedule entry, personal form and ordinary day editor; shorten retained roster snapshot/copy boundaries.
- [x] Shorten plan confirmation, calendar, pairing and empty-state descriptions without removing important rules.
- [x] Add `tools/test/conservative-cleanup-regression.mjs` to verify removed noise does not return while required rule/privacy/retry text and all actions remain.
- [x] Run that regression and update only directly affected presentation assertions.

## Task 3: Production redundancy cleanup

- [x] Remove inspected unused imports/private presentation code, not platform callbacks or Watch targets.
- [x] Move old animation-only source/assets to historical tooling/prototype area; update original tests/generator paths and check the generated browser file is unchanged.
- [x] Remove verified orphan assets only after backup; do not delete current role plates, expression 0/3, app icons or historic design material.
- [x] Rerun inventory and compare resource/code counts and bytes to the original snapshot.

## Task 4: Verification and handoff

- [x] Run `node tools/verify.mjs --steps=offline` (closed/open typecheck 0 and all tests pass).
- [x] Run `C:/Users/ASUS/.agents/skills/arkts-syntax-assistant/scripts/run.ps1` with DevEco tools/SDK configured; confirm actual `BUILD SUCCESSFUL`, not merely the wrapper's success string. Both clean and final builds succeeded.
- [x] Write `docs/validation/2026-10-17-conservative-cleanup.md` listing copy before/after, exact removals/moves, recovery path, retained categories, verification and native visual caveat.
