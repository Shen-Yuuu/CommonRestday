# Style Directions Comparison Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone responsive page that compares three visual directions for the simplified CommonRestday prototype.

**Architecture:** Add one dependency-free HTML document containing semantic markup, scoped CSS design tokens for each direction, and a small script for focus mode. Leave the existing prototype untouched so the comparison page can be reviewed independently.

**Tech Stack:** HTML5, CSS custom properties, vanilla JavaScript

**Spec:** `docs/plans/2026-09-21-style-directions-design.md`

## Global Constraints

- Do not modify `docs/prototype/index.html`.
- Do not load remote fonts, icons, images, or JavaScript.
- Support viewport widths from 360px upward without horizontal scrolling.
- Animate only `transform` and `opacity`; honor `prefers-reduced-motion`.

---

### Task 1: Build and verify the comparison page

**Files:**
- Create: `docs/prototype/style-directions.html`
- Test: `docs/prototype/style-directions.html`

**Interfaces:**
- Consumes: no project runtime code; copy and sample data are self-contained.
- Produces: three `.direction-card` elements with `data-theme` values `editorial`, `structural`, and `glass`; `setFocus(card)` and `clearFocus()` interactions.

- [ ] **Step 1: Create the semantic comparison layout**

Add a header, three accessible direction cards, equal-content phone previews, token swatches, and concise design rationale.

- [ ] **Step 2: Implement responsive visual systems**

Use scoped custom properties for each direction, an asymmetric desktop comparison grid, single-column mobile fallback, concentric card radii, visible focus states, and no horizontal overflow.

- [ ] **Step 3: Implement focus-mode interaction**

Add pointer and keyboard activation. `setFocus(card)` applies `.is-focused` to the selected card and `.has-focus` to the page; `clearFocus()` restores the comparison view. Escape exits focus mode.

- [ ] **Step 4: Validate markup and behavior**

Run a local HTTP server, open the page in a browser, inspect desktop and 360px layouts, activate every direction, exit with Escape, and confirm the console has no errors.

- [ ] **Step 5: Commit the isolated exploration artifact**

```bash
git add docs/plans/2026-09-21-style-directions-design.md docs/superpowers/plans/2026-09-21-style-directions.md docs/prototype/style-directions.html
git commit -m "docs: add visual direction comparison prototype"
```
