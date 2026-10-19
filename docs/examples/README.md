# A small fictional memory trail

This example shows how a past investigation can become useful context for future sessions. All names, events, and evidence below are invented. They are not benchmark results or a real project history.

## 1. Preserve the original note

In a private vault, a source might live at `raw/conversations/demo-cache-investigation.md`:

> During a disposable test, the proposed response cache served a signed-in page after sign-out. We decided to defer the cache change until invalidation was addressed. The experiment is incomplete; it has not shipped.

The original note stays available so an agent can check what was said.

## 2. Summarize the event

A page in `wiki/summaries/` could record:

> **Outcome:** Cache change deferred. **Reason stated:** Sign-out behavior failed in the experiment. **Unresolved:** Invalidation design and repeat test. **Source:** `raw/conversations/demo-cache-investigation.md`.

This accounts for one event. It does not establish that every cache design has the same problem.

## 3. Record the decision and its scope

A decision page in `wiki/knowledge/decisions/` could state:

> **Decision:** Keep existing behavior while a revised cache design is evaluated. **Alternative considered:** Enable the experimental response cache. **Rationale:** The observed sign-out failure. **Authority:** The owner accepted deferral in the source note. **Scope:** This experiment. **Revisit when:** A revised design passes an appropriate sign-out test. **Verification:** No independent result is attached to this fictional example.

A real decision should cite the evidence and name who accepted it. A model's suggested decision stays labeled as a proposal until accepted.

## 4. Make the context discoverable

A workbench page might begin:

```yaml
---
name: demo-cache
type: work-item
status: active
tech_surface: [demo-cache, postgres]
last_verified: null
---
```

Its body would link to the current decision, summary, and next steps.

A prompt containing `demo-cache` can trigger an exact-tag pointer to that page. The assistant must then read it and its sources. A prompt saying only “the sign-out optimization” may miss this tag entirely.

## 5. Ask the question that matters

“Can we enable the demo-cache change?”

A useful answer would recover the deferral, explain its scope, and identify the missing check. It would not call the feature shipped, assume the old result is current, or treat the question as permission to deploy it.

[Back to the overview](../../README.md)
