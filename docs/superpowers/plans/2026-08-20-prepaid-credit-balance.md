# Prepaid Credit Balance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make claudebar display and meter exact prepaid Claude credits separately from the monthly spending limit.

**Architecture:** The Bash collector fetches and caches the prepaid balance beside the existing usage response, normalizes both into structured JSON, and retains an explicit unknown state. The QML panel renders the normalized values and never derives progress from the monthly limit.

**Tech Stack:** Bash, curl, jq, shell integration tests, QML/Quickshell.

**Spec:** `docs/superpowers/specs/2026-08-20-prepaid-credit-balance.md`

## Global Constraints

- Preserve all pre-existing uncommitted changes.
- Do not print or persist OAuth credentials outside Claude's credential store.
- Do not modify `/usr/share/omarchy`.
- Do not commit changes.
- A missing balance must never fall back to the monthly limit.

---

### Task 1: Normalize cached prepaid balance

**Files:**
- Modify: `tests/lib.sh`
- Modify: `tests/test_extra_usage.sh`
- Modify: `tests/test_json.sh`
- Modify: `claudebar`

**Interfaces:**
- Consumes: `/api/oauth/usage` fields `extra_usage.used_credits`, `extra_usage.monthly_limit`, and `extra_usage.disabled_reason`; cached prepaid response field `amount`.
- Produces: `extra_usage.available_credit_cents`, `extra_usage.funded_credit_cents`, `extra_usage.balance_known`, and real-funds `extra_usage.used_pct`.

- [ ] **Step 1: Write failing shell tests**

Add fixtures with a cached balance of 2500 cents and assert that 3750 cents
spent produces 7505 funded cents and 67%; add an out-of-credits fixture that
asserts an inferred zero balance and 100%; add an unknown-balance fixture that
asserts null funded amount and percentage.

- [ ] **Step 2: Run tests to verify RED**

Run: `bash tests/test_extra_usage.sh && bash tests/test_json.sh`

Expected: FAIL because the structured output lacks the new balance fields and
still calculates percentage against `monthly_limit`.

- [ ] **Step 3: Implement minimal normalization**

Read a valid cached prepaid response, otherwise infer zero only for
`out_of_credits`. Derive funded cents and rounded/clamped percentage only when
the balance is known. Emit nulls for unknown values.

- [ ] **Step 4: Run tests to verify GREEN**

Run: `bash tests/test_extra_usage.sh && bash tests/test_json.sh`

Expected: all assertions pass.

### Task 2: Fetch and cache the exact balance

**Files:**
- Modify: `tests/lib.sh`
- Modify: `tests/test_extra_usage.sh`
- Modify: `claudebar`

**Interfaces:**
- Consumes: `~/.claude.json.oauthAccount.organizationUuid`, current OAuth access token, and Claude's prepaid credits endpoint.
- Produces: atomic `~/.cache/claudebar/credits.json`, reusable under the existing cache lock.

- [ ] **Step 1: Write a failing fetch-boundary test**

Use a deterministic curl test double that returns a complete usage response
and `{ "amount": 2500, "currency": "USD" }` for the prepaid endpoint. Assert
that `--refresh --json` emits the exact available balance and 67% real-funds
usage.

- [ ] **Step 2: Run the test to verify RED**

Run: `bash tests/test_extra_usage.sh`

Expected: FAIL because claudebar never calls or caches the prepaid endpoint.

- [ ] **Step 3: Implement the balance request**

When an organization UUID is present and usage credits exist, issue a
read-only authenticated request with the same OAuth headers as usage, validate
numeric `amount`, and atomically update `credits.json`. Balance failure must not
discard a successful usage response or a valid recent balance cache.

- [ ] **Step 4: Run the test to verify GREEN**

Run: `bash tests/test_extra_usage.sh`

Expected: all assertions pass.

### Task 3: Render separate credit facts in Quickshell

**Files:**
- Modify: `omarchy/Panel.qml`
- Modify: `README.md`

**Interfaces:**
- Consumes: normalized `usage.extra_usage` fields produced by Task 1.
- Produces: separate Spent, Credit available, and Monthly limit rows; meter visibility based on `balance_known`.

- [ ] **Step 1: Capture the failing UI contract**

Use the structured-output assertions from Task 1 as the behavioral boundary:
the QML consumes only normalized values. Before the QML edit, inspect the live
panel to confirm it still renders one `spent of limit` row.

- [ ] **Step 2: Implement the minimal QML rendering**

Replace the combined row with three plain-text fact rows. Add a `Used of funded
credits` percentage row and meter that are visible only for a known balance.

- [ ] **Step 3: Validate QML and documentation**

Run QML formatting/parsing, `qmllint` with the established Quickshell warning
allowances, and `omarchy plugin validate mryll.claudebar`. Document the balance,
limit, and fallback semantics in README.

Expected: all validators exit 0, apart from known Quickshell type warnings that
are explicitly filtered by the existing validation command.

### Task 4: Regression verification

**Files:**
- Test: all `tests/test_*.sh`

**Interfaces:**
- Consumes: completed collector and QML changes.
- Produces: evidence that existing Waybar and structured JSON behavior remains valid.

- [ ] **Step 1: Run the complete shell suite**

Run: `for test in tests/test_*.sh; do bash "$test" || exit; done`

Expected: every test reports zero failures.

- [ ] **Step 2: Run syntax and plugin validation**

Run: `bash -n claudebar tests/*.sh`, QML parser/linter commands, and
`omarchy plugin validate mryll.claudebar`.

Expected: every required validator exits 0.

- [ ] **Step 3: Refresh the live plugin and inspect output**

Run `claudebar --json --refresh` against a live account and verify the three
figures line up with the usage page: spent cents, available cents, and the
monthly-limit cents, with `used_pct` computed from spend plus balance. Then
rescan the plugin so the live panel picks up the QML change.

Expected: values match the account response and no plugin-load error appears.
