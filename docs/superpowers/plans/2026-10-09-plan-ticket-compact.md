# Compact Plan Ticket Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Follow the user's explicit compact-card revision: shorter cards, time-only subtitle and swipe-only management.
**Architecture:** Retain native ListItem drawer and controller safety guards. Compact the shared header to title/status on one row, reuse canonical DateLabel endpoint formatting, and reduce the reusable date tile without hard-clipping card height.
**Tech Stack:** ArkTS/ArkUI API 26, Node regression and project verification.
**Spec:** docs/plans/2026-10-09-plan-ticket-drawer-design.md, compact revision.

## Global Constraints

No simulator control, cloud/schema/certificate changes or commits. Preserve confirmation, pending occupancy, date semantics and dirty worktree. Execute inline because execution subskills are unavailable and delegation is not authorized.

## Task 1: Compact card and matching regression

**Files:** SharedPlansPanel.ets, PlanDateTicket.ets, PlansView.ets, tools/test/plan-ticket-drawer-regression.cjs.

- [x] Change regression to require no `.bindMenu(`, card minimum 92vp, and `DateLabel.endLabel(content.start, content.end)` for subtitle. Run `node tools/test/plan-ticket-drawer-regression.cjs`; menu assertion failed before implementation as expected.
- [x] Remove `menuItems` and the ellipsis Button; retain drawer click handlers and stale-row checks. Put title and status on one Row.
- [x] Implement `private timeRange(row: SharedPlanRecord): string` with `const content = row.pendingContent ?? row.acceptedContent; return content === null ? '申请已结束' : DateLabel.endLabel(content.start, content.end);`. Keep complete `stamp(content)` only for accessibility and original-time amendment text.
- [x] Use `.padding({ left: 14, right: 14, top: 10, bottom: 10 })` and `.constraintSize({ minHeight: 92 })`; initialize drawer height to 92, retaining measured equal-height updates. Use date number 24vp and tile padding 6vp.
- [x] Apply compact padding to local cards; show `DateLabel.endLabel(arg.p.start, arg.p.end)` plus existing duration, keeping `.accessibilityText(this.subLabel(arg.p))` and full-date confirmation messages.
- [x] Run focused regression (9 passed) plus `node tools/verify.mjs --steps=offline,debug,release,ohostest`; ALL PASS, exit 0, unchanged warning baselines.
- [x] Update existing validation document with results and swipe-only manual checks; device visual acceptance stays with user.
