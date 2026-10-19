# Walk-Away Runs: Clipping Distillation Recipe

## Overview

The walk-away pattern executes bounded, asynchronous tasks via subagents with an automated gate command and structured output schema. Rather than babysitting an agent interactively while it summarizes a long document, you launch the task in the background and review the gated result once it completes.

## The Recipe

### 1. Launch Invocation

When distilling a file from `raw/clippings/` into `wiki/summaries/`:
- **Mode**: Asynchronous subagent (`async: true`)
- **Isolation**: Single-clipping target, bounded output
- **Gate Command**: `.claude/scripts/check-source-summary.sh wiki/summaries/<source-id>.md`
- **Output Schema**: Structured output verifying frontmatter fields, summary sections, and claims

### 2. The Verification Gate

The host runs `.claude/scripts/check-source-summary.sh` automatically when the child agent completes:
- Verifies YAML frontmatter structure
- Verifies presence of `## Key Concepts`, `## Important Claims`, and `## Provenance`
- Fails on non-zero exit if the output is malformed or incomplete

### 3. Review Ritual (Per Completed Run)

1. **Check Evidence**: Read the runtime gate evidence and `structuredOutput` (recorded by harness runtime, not self-reported by child).
2. **Inspect Content**: Review the generated summary in `wiki/summaries/`.
3. **Log the Run**: Record one entry in your walk-away log:
   - Date
   - Target source
   - Gate result (`PASS` / `FAIL`)
   - Verdict (`accepted` / `needs-fix`)
   - Review duration
4. **On Needs-Fix**: Resume the subagent with targeted feedback; do not hand-edit the draft.

## Log Table Template

```markdown
| # | Date | Task | Launched-then-yielded? | Gate result | structuredOutput ok | Human verdict | Review minutes |
|---|------|------|------------------------|-------------|--------------------|---------------|----------------|
| 1 | YYYY-MM-DD | distill: <Document Name> | yes | GATE PASS | ok | accepted | 2 min |
```
