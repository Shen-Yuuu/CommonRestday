# Plan Ticket and Swipe Drawer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the approved lavender plan tickets and native confirmed-plan drawer without changing synchronization semantics.
**Architecture:** Keep SharedPlansPanel as the single repository-reading header and its existing read-free card mode. Card mode owns a native ListItem. Pure presentation helpers split pending decisions from confirmed management. Reuse a small date-ticket component in local and shared cards. Both calendar modes share one plan-block builder.
**Tech Stack:** HarmonyOS API 26, ArkTS/ArkUI, semantic color resources, Node offline regression runner.
**Spec:** docs/plans/2026-10-09-plan-ticket-drawer-design.md

## Global Constraints

- Preserve unrelated dirty worktree changes; no staging/commits, simulator control, cloud deployment or data removal.
- No long-swipe destructive callback; cancellation requires existing explicit confirmation.
- Keep pending content out of occupancy calculations, existing date formatting and request fencing intact.
- Execution-plan subskills are not available in this session; execute these steps inline, without delegated agents.

## Task 1: Regression policy

- [x] Add `tools/test/plan-ticket-drawer-regression.cjs`; exercise production helpers with valid confirmed, invitation and amended records.
- [x] Run `node tools/test/plan-ticket-drawer-regression.cjs` before implementation; missing presentation helper failed as expected.
- [x] Add helpers `sharedInlineActions`, `sharedDrawerActions` (ordered EXPORT/AMEND/CANCEL); pending amendment disables AMEND without losing CANCEL or export.

## Task 2: Visual tokens and week blocks

- [x] Add base/dark semantic lavender and drawer colors plus DesignTokens mappings; test all new text/background contrast pairs.
- [x] Replace outlined plan blocks with a shared `planBlock({ plan, day })` builder, preserving day clipping and conflict marker. Short blocks omit time; tall blocks show `DateLabel.hm(plan.start)`.
- [x] Update legend; keep class/course colors and free-time blocks unchanged.

## Task 3: Ticket cards and native drawer

- [x] Add a reusable date tile using DateLabel and domain dayOfStart; adopt it in shared and local cards.
- [x] Make SharedPlansPanel card mode render a root ListItem; wire native end-swipe actions with measured card height, no delete area, and explicit action clicks.
- [x] Keep invitation decisions inline; use ordered drawer/menu for confirmed actions; close native drawers before opening editor/dialog/calendar.
- [x] Wire PlansView to a ListScroller and remove the extra ListItem wrapper around shared cards.
- [x] Preserve latest-read/mounted guards, busy guards, retry feedback and cross-day edit pickers; add stale row/version callback guards.

## Task 4: Verification and handoff

- [x] Register regression in `tools/test/run.mjs`; run focused tests and CRLF-aware `git diff --check` for touched tracked files. New files have no trailing spaces/tabs.
- [x] Run `node tools/verify.mjs --steps=offline,debug,release,ohostest` with unchanged warning baselines; final code ALL PASS, exit 0.
- [x] Record actual evidence and device-only checks at `docs/validation/2026-10-09-plan-ticket-drawer.md`. Device visual/gesture acceptance remains for the user.
