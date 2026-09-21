# Warm Editorial Prototype Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the approved warm-editorial direction only to the lean interactive prototype without changing its state or calculation behavior.

**Architecture:** Add a `lean-mode` body hook and scope every new visual override beneath it, then make small render-hook adjustments for entry motion. Preserve all existing JavaScript interfaces and screen functions; full mode keeps the original visual system.

**Tech Stack:** HTML5, CSS custom properties, vanilla JavaScript

**Spec:** `docs/plans/2026-09-21-warm-editorial-prototype-design.md`

## Global Constraints

- Preserve every existing `data-act`, `data-p`, element ID, state key, and calculation function.
- Do not add third-party dependencies, remote fonts, images, or scripts.
- Redesign only lean-mode screens and lean-mode overlays; full mode must retain its original visual styles.
- Keep both lean and full prototype modes operational.
- Support viewport widths from 360px upward without horizontal overflow.
- Animate only `transform` and `opacity`; honor `prefers-reduced-motion`.

---

### Task 1: Add isolated lean-mode theming

**Files:**
- Modify: `docs/prototype/index.html`

**Interfaces:**
- Consumes: existing `S.lean`, `render()`, `.phone`, `.screen`, and component hooks.
- Produces: `body.lean-mode` and `#phone[data-mode="lean"]` hooks without changing full-mode presentation.

- [x] Update `render()` to toggle `body.lean-mode` and set `#phone[data-mode]` from `S.lean`.
- [x] Add a lean-only warm ivory/berry token overlay and fixed paper grain inside the device.
- [x] Add 360px responsive fixes scoped to lean mode; do not restyle the outer console or full mode.

### Task 2: Redesign the lean in-device component system

**Files:**
- Modify: `docs/prototype/index.html`

**Interfaces:**
- Consumes: existing `.card`, `.hero`, `.chip`, `.btn`, `.seg`, `.tabbar`, `.sheet`, `.dlg`, calendar, week-grid and form hooks.
- Produces: warm editorial visual system used only while `body.lean-mode` is present.

- [x] Override tokens beneath `body.lean-mode` with an ivory/berry/warm-neutral palette for light and dark themes.
- [x] Apply serif display typography, asymmetric radii, softer surfaces, semantic colors, nested CTA interactions, and editorial dividers to lean screens.
- [x] Restyle lean overlays, forms, schedules and bottom navigation without altering event behavior or full-mode styles.

### Task 3: Add motion hooks and verify behavior

**Files:**
- Modify: `docs/prototype/index.html`

**Interfaces:**
- Consumes: existing `render()`.
- Produces: `data-screen` state on `#phone` and replayable `.screen-enter` content entry class.

- [x] Update `render()` to expose the current screen and replay entry motion after each screen render.
- [x] Open the prototype through localhost and test lean light/dark themes, page navigation, sheets and dialogs, then verify full mode visually remains unchanged.
- [x] Validate 1440px, 768px and 360px layouts, keyboard focus, reduced motion and zero console errors.
- [x] Commit only the redesigned prototype and its two planning documents.
