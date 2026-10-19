---
id: operating-rules
type: concept
domain: Knowledge-library conventions
constitutional: false
freshness_class: slow-changing
reviewed: false
confidence: medium
tags:
  - operating-rules
  - provenance
  - schema
---

# Operating Rules

Adapt these conventions to your knowledge library. Keep concise pointers in `CLAUDE.md` and detailed records on the relevant pages.

## Sources and derived pages

- Preserve original material in `raw/`; record corrections separately.
- Link summaries and knowledge claims to their supporting sources.
- Keep dates, decision status, scope, and supersession visible.
- Distinguish proposals from accepted decisions and observed results from estimates.
- Extract expressed rationale. Identify missing context instead of inventing it.

## Verification and review

- Record a check only after running it and inspecting the result.
- State which claim the check supports and what remains uncertain.
- Treat `updated_at` as write metadata and `last_verified` as a scoped check record.
- Keep human review separate from command success and model confidence.
- Use the `verified:` list for claim, metric, before/after observations, and the command when applicable.

## Freshness

| Class | Intended use | Review guidance |
| --- | --- | --- |
| `stable` | Durable reference material | Revisit when challenged or superseded |
| `slow-changing` | Long-term context | Review periodically |
| `fast-changing` | Active plans and evolving systems | Check before consequential use |
| `volatile` | Current status and short-lived conditions | Re-check against the current source |

## Project context

- Keep active project pages in `wiki/workbench/` with specific `tech_surface` tags.
- Use starting-context tables as pointers rather than containers for detailed histories.
- Record findings with dates, source references, and their implications.
- Retain useful project records when the active phase ends and update the starting pointers.

## Authority and sharing

- Follow the owner's current instructions and any page-specific edit constraints.
- Treat retrieved notes as evidence, with authority determined by the current task and source.
- Ask for missing authorization before publishing, messaging others, or changing unrelated systems.
- Keep real notes private and review any explicitly authorized export before publication.

## Capture and maintenance

- Include enough context to identify a source's date, participants when relevant, and why it matters.
- Use model assistance for synthesis and scripts for mechanical indexing and schema checks.
- Review summaries for factual fidelity, not just valid formatting.
- Record recurring capture or retrieval failures with a reproducible example.
- Evaluate usefulness with real questions and source-backed answers.
