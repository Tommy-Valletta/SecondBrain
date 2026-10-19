# Vault Templates

Generic templates for knowledge pages. All templates use `{{variable}}` syntax for substitution.

## source-summary.md

**Location**: `wiki/summaries/`  
**Purpose**: Episodic memory — distilled summaries of raw sources  
**Created by**: `ingest-source.sh`, `ingest-session.sh`

Captures what happened in a source (session, paper, article, etc.) with key concepts, entities, and claims.

## concept.md

**Location**: `wiki/knowledge/concepts/`  
**Purpose**: Semantic memory — cross-source understanding  
**Created by**: Manual or synthesis scripts

Defines concepts that emerge across multiple sources. Examples: architectural patterns, methodologies, technical concepts.

## entity.md

**Location**: `wiki/knowledge/entities/`  
**Purpose**: Semantic memory — people, tools, systems, projects  
**Created by**: Manual or synthesis scripts

Tracks entities mentioned across sources. Examples: people, tools, organizations, codebases, libraries.

## decision.md

**Location**: `wiki/knowledge/decisions/`  
**Purpose**: Semantic memory — decisions with context  
**Created by**: Manual

Documents architectural, strategic, or tactical decisions with full context, alternatives, and rationale.

## index.md

**Location**: `wiki/indexes/`  
**Purpose**: Navigation layer  
**Created by**: `compile-wiki.py indexes`

Auto-maintained indexes for each knowledge type. Do not edit manually.

---

## Customizing Templates

1. Keep frontmatter structure (scripts depend on these fields)
2. Add domain-specific sections as needed
3. Use `{{variable}}` syntax for dynamic content
4. Test with your ingest scripts after changes

## Domain-Specific Examples

### Engineering Vault
- Add `service.md` template for microservices
- Add `api.md` template for API endpoints
- Add sections for: dependencies, deployment, runbooks

### Research Vault
- Add `paper.md` template for academic papers
- Add sections for: methodology, results, limitations

### Writing Vault
- Add `character.md` template for characters
- Add `theme.md` template for themes
- Add sections for: arc, motivation, conflict
