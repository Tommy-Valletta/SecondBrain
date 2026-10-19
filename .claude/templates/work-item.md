---
name: {{slug}}
title: {{title}}
type: work-item
status: {{status}}  # active | blocked | paused | done
freshness_class: volatile
reference: {{reference}}
apps: [{{apps}}]
tech_surface: [{{tech_surface}}]
created_at: {{created_at}}
updated_at: {{updated_at}}  # DERIVED — stamped by .claude/hooks/stop-stamp.sh. Means: a tool WROTE this page. Never type it.
last_verified: null            # The latest recorded check of the page's claims against their sources.
                               # Written ONLY by .claude/scripts/verify-page.sh, which runs the check and refuses to
                               # stamp on a nonzero exit. A PreToolUse hook denies hand-edits. null = never checked,
                               # which is honest — an unearned date is worse than no date (verification freshness).
verified_by: null              # The named check that produced the stamp. An unnamed verification is unrepeatable.
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
  - work-item
---

# {{title}}

## What

{{what_is_this_work}}

## Tech Surface

{{why_these_tags_matter}}

## Related Findings

<!-- Append signals here as they're discovered. Format:
### YYYY-MM-DD — {{short title}}
**Source**: {{where you found it — document, conversation, article}}
**Relevant because**: {{why it matters to this work item}}
**Actionable insight**: {{what to check or do}}
-->

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
