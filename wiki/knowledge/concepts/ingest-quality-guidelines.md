---
id: ingest-quality-guidelines
type: concept
status: active
confidence: high
confidence_sources: []
last_accessed: null
superseded_by: null
created_at: null
updated_at: null
aliases:
  - quality guidelines
  - ingest guidelines
uses: []
depends_on: []
contradicts: []
related_to: []
reviewed: true
tags:
  - concept
  - quality
---

# Ingest Quality Guidelines

## Definition

Standards for producing high-quality source summaries during the ingest pipeline. These guidelines are injected into LLM prompts via `{{QUALITY_GUIDELINES}}` and evolve over time via `review-ingest-quality.sh`.

## Summary Structure

- **2-3 sentence overview**: What the source is, who created it, why it matters
- **Structured breakdown**: Key Concepts, Entities, Claims, Provenance sections
- **Self-contained**: A reader should understand the source's contribution without reading the original
- **Information density**: Target 90%+ token reduction while preserving key knowledge

## Linking Rules

- Link aggressively using `[[wiki/knowledge/concepts/slug|Display Name]]` format
- Every concept/entity with an existing wiki page should be linked on first mention
- Concepts without a page should be **bolded** (signals promotion opportunity)
- More links are better than fewer links

## Entities Section

- Categorize: People, Organizations, Tools/Systems
- For tools/systems: include enough context to bootstrap an entity page from the description alone
- Only include entities substantively discussed, not just name-dropped

## Important Claims

- Specific, falsifiable, and surprising claims only
- Attribute to source, not to yourself
- Prefer quantitative claims when available
- Focus on 5-15 most important, ranked by specificity and surprise value

## Confidence Scoring

- `high`: Peer-reviewed research, official documentation, primary sources
- `medium`: Well-reasoned analysis, credible authors, corroborated reporting
- `low`: Speculation, opinion, single-source claims, outdated information

## Mentioned In
_Empty; populated as sources are compiled._

## Sources
_Empty; populated as sources are compiled._
