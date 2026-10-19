# Weekly Schedule Prototype Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a separate interactive HTML design preview for dated weekly scheduling.

**Architecture:** One offline HTML file, isolated pure scheduling helpers and in-memory view state. No application, database, backend or existing prototype changes.

**Tech Stack:** HTML, CSS, vanilla JavaScript, Node built-in test/assert.

**Spec:** `docs/plans/2026-10-09-weekly-schedule-prototype-design.md`

## Global Constraints

Preserve the dirty working tree. Use existing brand colors. No network dependencies. Do not interpret unknown days as rest. The approved scope is prototype-only; no subagent or application implementation is needed.

## Tasks

- [x] Create `docs/prototype/weekly-schedule-redesign-2026-10-09.html`: responsive phone frame, weekly roster, presets, home, fit-content dialogs and actual memory interactions.
- [x] Add `tools/design/weekly-schedule-prototype.test.cjs`: date boundary, split shift, same-day overlap, overnight conflict, copy strategies, source preservation and preset snapshot tests. Run `node tools/design/weekly-schedule-prototype.test.cjs`.
- [ ] Inspect in browser: weekly roster → add shift → copy week; preset editing; home → personal arrangement. Check narrow viewport and browser errors, then open the new preview for the user. Browser visual review remains unverified because browser policy rejected local `file:` navigation; no workaround attempted.

## Results

21 model and simulated-DOM checks passed. Simulated-DOM checks exercise initial rendering, adding same-day shifts, rejection without data mutation, per-week saving, preset snapshot isolation, copying, personal-event warning/confirmation and HTML escaping. These checks do not replace browser layout, focus or hit-testing validation.

The new HTML source was requested in a Codex file panel (tool status: queued). It is an offline file the user can open directly in a browser. No App files or previous prototype were changed by this task.
