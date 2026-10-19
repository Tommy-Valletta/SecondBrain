---
id: review-{{slug}}
type: review
review_type: {{review_type}}
period_start: {{period_start}}
period_end: {{period_end}}
status: draft
constitutional: false
freshness_class: stable
created_at: {{created_at}}
updated_at: {{updated_at}}  # DERIVED — stamped by .claude/hooks/stop-stamp.sh. Means: a tool WROTE this page. Never type it.
reviewed: false
# --- Verification evidence -----------------------------------------
# A fix with no post-measurement reads identically to a fix that worked. Append
# ONE entry per remedy verified. Never edit an entry — append a superseding one.
# `after` must be a number a command produced, not a number you expect.
verified: []
#  - date: YYYY-MM-DD
#    claim: what was believed broken
#    metric: the name of the thing re-measured
#    before: <value>
#    after: <value>
#    by: the exact command that produced `after`
tags:
  - review
  - {{review_type}}
---

# {{title}}

## What Went Well

{{what_went_well}}

## What Didn't Go Well

{{what_didnt_go_well}}

## What I Learned

{{what_i_learned}}

## Goal Progress

{{goal_progress}}

## Adjustments for Next Period

{{adjustments}}

## Cross-Vault Insights

{{cross_vault_insights}}

## Verification

<!-- Claim labeling: every claim on this page is marked at the point it is made.
     ✅ measured  — a command or query produced this number; the command is shown
     ⚠️ estimated — heuristic, small-n, inferred, or remembered
     An unmarked claim is read as ⚠️.

     Remedy verification: if this page records a fix, it does not close until this
     section names what was re-measured, the before and after, and the command.
     Mirror it into the `verified:` frontmatter list. -->

_What was re-checked before writing this, and with what command._

## Sources

{{sources}}
