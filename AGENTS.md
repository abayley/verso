# Agent Instructions

## Visual Work

Do not use strict TDD for exploratory visual work, including styling changes,
toolbar layout experiments, and UI control comparisons.

For visual work:

- Iterate browser-first with the running TestApp.
- Use screenshots, DOM inspection, and console checks to evaluate the result.
- Add or update tests only when an interaction contract stabilises.
- Do not add brittle tests for colours, spacing, shadows, borders, exact control
  ordering, right-or-left alignment, or general visual taste.

Behaviour changes still need the normal test discipline. Examples include mode
selection changing editor state, toolbar commands modifying Markdown, generated
assets being served, explicit Save submitting content through htmx, and editor
content being preserved across view changes.
