---
id: decision-{{slug}}-{{date}}
type: decision
status: active
confidence: {{confidence}}
confidence_sources: []
superseded_by: null
supersedes: []
created_at: {{created_at}}
updated_at: {{updated_at}}  # DERIVED — stamped by .claude/hooks/stop-stamp.sh. Means: a tool WROTE this page. Never type it.
decision_date: {{decision_date}}
# Typed relationships
caused_by: []
enables: []
blocks: []
related_to: []
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
  - decision
---

# Decision: {{title}}

## Decision

{{decision}}

## Context

{{context}}

## Alternatives Considered

{{alternatives}}

## Rationale

{{rationale}}

## Consequences

{{consequences}}

## Related Decisions

{{related_decisions}}

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
