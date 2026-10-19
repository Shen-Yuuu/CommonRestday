# Request recovery and work-sheet measurement implementation plan

> Inline execution in this chat. Do not delegate or commit unrelated user changes.

**Goal:** Restore the work editor's usable scroll/Save area and make unresolved invitations visible and recoverable without duplicate submissions.

**Architecture:** Work editors declare a viewport-derived intrinsic height, with a weighted scroll area and a non-shrinking safe footer. Request recovery still reads the original receipt first; a separate explicitly confirmed close operation serializes against mutation on the same binding and writes an immutable negative receipt only if no commit exists.

**Tech Stack:** ArkTS/ArkUI, CloudDB transactions, TypeScript server, Node regression harness.

**Spec:** User screenshots in this chat: clipped work scheduling sheet and unresolved-request conflict without visible original invitation.

## Constraints

- Preserve pending drafts, encrypted wire, requestId, confirmed schedules, pairing, and user edits.
- Never equate missing receipt with cancellation. No replay while time is past or availability conflicts.
- No cloud deployment, data deletion, reinstall, or device reset in this implementation.
- Unresolved request is labelled local/unverified, not an invitation delivered to the partner.

## Task 1: Restore bounded work-sheet layout

- [x] Add regression assertions for `Scroll.layoutWeight(1)`, numeric root height and safe footer.
- [x] Publish viewport height with bottom inset; size DayShiftSheet at 82% viewport (subtract enclosing header in day detail).
- [x] Run regression and ArkTS skill build; native visual verification remains explicitly pending.

Files: `BottomSafeArea.ets`, `DayShiftSheet.ets`, `DayDetailSheet.ets`, `tools/test/real-device-feedback-regression.mjs`.

## Task 2: Recover or safely close original requests

- [x] Test expired-but-committed recovery before local validation; uncommitted past-start classification; close unknown results keep queue; committed close restores record.
- [x] Server `closeRequest(token, commandJson)` returns the existing receipt or atomically records `REQUEST_CLOSED`, touching the same binding as mutate. Replays can never create a closed request.
- [x] Gateway `close` reuses original persisted wire; use case only finishes on `REQUEST_CLOSED` or validated/applied `OK`.
- [x] Show locally stored original title/time/action in the plans panel; add confirmed close action; distinguish past start from a schedule conflict.
- [x] Run server contracts including CAS races, V2 counters and archived receipts, offline suites and compile; sync checked server files to existing CloudProgram folders. Worker packages do not include service/dateplan and need no new build for this change; previous Long-fix packages remain required if not deployed.
- [x] Document deployment plus retry/close acceptance steps and remaining native/live-cloud validation.

Files: `service.ts`, `dateplan.ts`, `DatePlanCloudApi.ets`, `SecureSharedPlanGateway.ets`, `SharedPlanUseCase.ets`, `SharedPlanViewService.ets`, `SharedPlanPresentation.ets`, `SharedPlanDiagnostic.ets`, `SharedPlansPanel.ets`, associated tests and validation document.
