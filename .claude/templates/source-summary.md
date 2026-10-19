---
id: summary-{{slug}}
type: source_summary
source_type: {{source_type}}
status: draft
confidence: {{confidence}}
freshness_class: stable
compiled: false
last_accessed: null
superseded_by: null
created_at: {{created_at}}
updated_at: {{updated_at}}  # DERIVED — stamped by .claude/hooks/stop-stamp.sh. Means: a tool WROTE this page. Never type it.
raw_source: raw/{{filename}}
source_url: {{source_url}}
meta-relevant: false
links: []
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
  - source
  - {{source_type}}
---

# Source: {{title}}

## Summary

{{summary}}

## Key Concepts

{{key_concepts}}

## Entities Mentioned

### People
{{people}}

### Tools/Systems
{{tools}}

### Organizations
{{organizations}}

## Important Claims

{{claims}}

## Provenance

- **Source Type**: {{source_type}}
- **Raw Source**: `raw/{{filename}}`
- **URL**: {{source_url}}
- **Captured**: {{created_at}}

## Verification

<!-- Claim labeling: every claim on this page is marked at the point it is made.
     ✅ measured  — a command or query produced this number; the command is shown
     ⚠️ estimated — heuristic, small-n, inferred, or remembered
     An unmarked claim is read as ⚠️.

     Remedy verification: if this page records a fix, it does not close until this
     section names what was re-measured, the before and after, and the command.
     Mirror it into the `verified:` frontmatter list. -->

_What was re-checked before writing this, and with what command._

