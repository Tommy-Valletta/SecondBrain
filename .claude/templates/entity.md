---
id: entity-{{slug}}
type: entity
entity_type: {{entity_type}}
status: active
confidence_sources: []
last_accessed: null
superseded_by: null
created_at: {{created_at}}
updated_at: {{updated_at}}  # DERIVED — stamped by .claude/hooks/stop-stamp.sh. Means: a tool WROTE this page. Never type it.
last_verified: null            # Means: these claims were CHECKED AGAINST THE LIVE WORLD (the live state of the person/tool/system this page describes).
                               # Written ONLY by .claude/scripts/verify-page.sh, which runs the check and refuses to
                               # stamp on a nonzero exit. A PreToolUse hook denies hand-edits. null = never checked,
                               # which is honest — an unearned date is worse than no date (verification freshness).
verified_by: null              # The named check that produced the stamp. An unnamed verification is unrepeatable.
aliases: []
# Typed relationships
uses: []
used_by: []
member_of: []
owns: []
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
  - entity
  - {{entity_type}}
---

# {{name}}

## Description

{{description}}

## Role/Purpose

{{role}}

## Relationships

{{relationships}}

## Mentioned In

{{backlinks}}

## Timeline

{{timeline}}

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
