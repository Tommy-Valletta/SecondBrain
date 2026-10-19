---
name: brain-friction-log
title: Brain friction log — roadblocks, bumps, and architectural debt
type: work-item
status: "Accumulating — **0 findings**"
freshness_class: volatile
created_at: null
updated_at: null
last_verified: null
verified_by: '.claude/scripts/checks/friction-log-count.sh'
tags:
  - work-item
  - brain-architecture
  - meta
---

# Brain friction log

> **Purpose.** Record capture, indexing, retrieval, and agent-integration issues with evidence.
> Keep observations, proposed fixes, and accepted decisions distinct.
>
> **Use.** Review recurring issues to prioritize improvements and record the resulting decisions on their own pages.
>
> **How to add.** Append an `F-NN` entry. Date it, cite the evidence, name the layer. Don't dedupe eagerly —
> a repeat occurrence is itself the signal that the class is real.

---

## Standing metrics

Re-measure at the top of each re-evaluation session; the trend matters more than the absolute.

| Metric | Baseline | Meaning |
|---|---:|---|
| Summaries in `wiki/summaries/` | 0 | Layer 3 volume |
| `compiled: false` | 0 | Never promoted Layer 3 → Layer 2 |
| `links: []` | 0 | Unreachable by graph traversal |
| `reviewed: false` | 0 | Human review status |
| `CLAUDE.md` size | 0 lines | Under the ~300-line target |

---
