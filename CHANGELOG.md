# Changelog

Release history for the SecondBrain template and engine.
See the [validation guide](docs/VALIDATION.md) for checks and integration guidance.

## 3.0.0 (2026-10-03)

Expanded the personal knowledge template with session capture, retrieval hooks,
verification records, and background ingestion.

### Added
- **Real-Time Lifecycle Hooks**: 7 hooks intercepting session events (`SessionStart`, `SessionEnd`, `PostCompact`, `PreToolUse`, `PostToolUse`, `Stop`, `UserPromptSubmit`).
- **Ambient Cross-Pollination Matcher**: `UserPromptSubmit` hook scans workbench `tech_surface:` tags and injects targeted file pointers using deterministic matching.
- **Earned Verification Framework**: `verify-page.sh` enforces that `last_verified:` stamps can only be written if an actual command runs and exits with code 0. `pre-tool-guard-verified.sh` blocks manual hand-edits to date stamps.
- **Automated Freshness Stamping**: `post-tool-record.sh` and `stop-stamp.sh` batch-update `updated_at:` timestamps without breaking agent file-read tracking.
- **Self-Healing Background Daemon**: `auto-ingest.sh` runs every 10 minutes with PID liveness lock recovery (`kill -0`), complement-counted status tracking, and planted `banana` self-checks.
- **Self-Healing Draft Reconciliation**: `reconcile-drafts.py` automatically flips unfinalized, idle drafts (>6h) to `captured` for batch processing.
- **Subagent Transcript Discovery**: `discover-transcripts.py` finds unstubbed subagent runs and injects valid queue stubs.
- **Standing Metrics Telemetry**: `brain-vitals.sh` provides single-pass multi-tier health monitoring.
- **Maintenance Staleness Audits**: `maintenance.sh` audits broken links, orphan pages, missing frontmatter, and detects unearned or decaying claims.
- **Synthetic Corpus Partitioning**: `recall.sh` automatically filters out test harness and automation sessions.
- **Decoupled Architecture**: All environment variables, proxy routes, CA bundles, and paths parameterized via `brain.env`.

## 2.0.0 (2026-05-20)
Initial knowledge-library template with page schemas and navigation structure.
