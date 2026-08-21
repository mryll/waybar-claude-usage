# Prepaid credit balance design

## Goal

Show Claude usage-credit spending, the exact prepaid balance, and the monthly
spending limit as three distinct values. Progress must measure consumed real
funds, never the monthly limit.

## Data contract

- Continue reading month-to-date spend and the monthly limit from
  `/api/oauth/usage`.
- Read the exact prepaid balance from Claude Code's read-only endpoint
  `/api/oauth/organizations/{organizationUuid}/prepaid/credits` and cache it.
- Obtain `organizationUuid` from `~/.claude.json` without persisting account
  identifiers in the repository.
- When the balance endpoint is unavailable and usage reports
  `disabled_reason: "out_of_credits"`, treat the balance as exactly zero.
- Otherwise represent the balance as unknown; never substitute the monthly
  limit.

## Derived values

- `funded_credit_cents = used_credit_cents + available_credit_cents` when the
  balance is known.
- `used_pct = round(used_credit_cents / funded_credit_cents * 100)`, clamped to
  0–100. When both values are zero, use 0%.
- When the balance is unknown, `funded_credit_cents` and `used_pct` are null.

## Presentation

The Omarchy panel shows separate `Spent`, `Credit available`, and
`Monthly limit` rows. Its meter and percentage are visible only when the
balance is known and use `used_pct` from the real funded pool.

For an account that has spent its whole prepaid balance this reads, for
example, USD 37.50 spent, USD 0.00 available, USD 100.00 monthly limit, and a
100% meter.

## Compatibility

Waybar output remains valid JSON. Existing extra-usage placeholders remain,
but `{extra_pct}` and `{extra_bar}` use the real funded pool. If the balance is
unknown, `{extra_pct}` is empty and `{extra_bar}` is empty.
