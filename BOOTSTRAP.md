# Setup guide

[Overview](README.md) · [Technical README](README.technical.md)

Use this template and engine to create a personal knowledge library, connect an AI agent, and automate capture and retrieval. The included integration scripts target Claude Code/Pi and macOS-oriented utilities. Adapt and test Linux, Windows/Codex, or other integrations for your environment.

## 1. Explore without installing

```sh
git clone https://github.com/Tommy-Valletta/SecondBrain.git
cd SecondBrain
python3 -m unittest discover -s tests -v
```

The tests use temporary fictional data. They do not register hooks, start a server, call a model, or configure scheduling. Read [the examples](docs/examples/README.md) for the intended information flow.

## 2. Prepare a private working copy

Before adding real notes, use a separate directory and a private repository, or remove the public Git remote from the working copy. Ignore rules reduce accidental commits of generated records; they are not a data-loss-prevention system. Existing tracked files can still acquire private content.

Review `.claude/`, `brain.env.example`, `CLAUDE.md.template`, and `AGENTS.md.template`. Personalize the templates for your preferred agent behavior and knowledge structure.

The scripts use Bash, Python, `jq`, Git, and Unix utilities. Python 3.11+ is recommended for evaluation. Model ingestion additionally needs a configured Claude Code or Pi CLI. Optional MCP access needs the Python `mcp` package and `grep`; direct file access does not require it.

## 3. Understand installer effects

`bootstrap.sh` can:

- Render `CLAUDE.md` and `AGENTS.md` inside the vault.
- Write `brain.env`; the current implementation rewrites this file even on a repeat run.
- Create global instruction symlinks at `~/.claude/CLAUDE.md` and/or `~/.pi/agent/AGENTS.md`.
- Merge hooks into `~/.claude/settings.json`, backing up existing settings first. Matching event keys can be replaced by that merge.
- Render a launchd file or print a cron entry when a scheduler is selected.

`--force` can replace existing rendered files and instruction links. `--verify` runs checks that can modify generated vault files. Selecting `--scheduler none` does not suppress agent-setting changes.

Some ingestion/promotion paths use model permission-bypass flags. Inspect their tool access and use a controlled environment before running them over real content. Model calls can transmit that content to the configured provider.

## 4. Configure intentionally

In a private copy on a suitable Unix environment, inspect help first:

```sh
bash bootstrap.sh --help
```

After reviewing the effects, a Claude-only configuration can be rendered with:

```sh
bash bootstrap.sh --vault "$PWD" --owner "$USER" --harnesses claude --scheduler none
```

This changes the settings described above. Verify hook compatibility with your agent version in a disposable session before regular use.

Configure authentication and a default model in your chosen agent. Leave `INGEST_MODEL` blank to use Pi's configured default, or set it to a model available from your provider. `INGEST_FALLBACK_MODEL` is an optional second choice for raw-source ingestion. `MODEL` overrides the Claude model for session ingestion. Use `BRAIN_UNSET_ENV` only when you deliberately want named environment variables omitted from Claude calls.

Register optional MCP separately after reviewing its scope; bootstrap prints a suggested command but does not register it.

For scheduling, inspect `schedulers/launchd.plist.template` or `schedulers/crontab.template`. Enable a job after one manual ingestion cycle works. A scheduler file is not proof that the job is installed, running, or healthy.

## 5. Seed useful context

Start with one active project and one recurring decision:

1. Keep a concise pointer to the project in `CLAUDE.md`.
2. Create its `wiki/workbench/` page with specific unquoted inline tags, such as `tech_surface: [demo-cache, postgres]`.
3. Add an explicitly sourced decision when its rationale is known.
4. Add original notes under `raw/`; use source ingestion when appropriate.

There is no minimum corpus size. Test whether the first page can be retrieved before adding more information.

## 6. Check behavior, one path at a time

| Path | Evidence to inspect |
| --- | --- |
| Session capture | A disposable supported session produces a correctly linked capture record |
| Session ingestion | One capture produces a readable summary with the right source reference |
| Raw-source ingestion | One fictional clipping produces a faithful summary |
| Mechanical compilation | `python3 .claude/scripts/compile-wiki.py backlinks indexes` has stable content on a second run, allowing for generated timestamps and logs |
| Prompt retrieval | An exact tag surfaces the intended pointer; then test synonyms and known misses |
| Claim verification | A check that actually tests a written claim records its result; a failure does not earn a stamp |
| Scheduled ingestion | Scheduler status and a completed job log show the expected run |

Use temporary data. `compile-wiki.py all` also invokes model promotion; use explicit `backlinks indexes` for mechanical paths only.

## 7. Measure usefulness

Ask recurring questions in fresh sessions. Check whether the assistant retrieves the right evidence, recognizes superseded decisions, applies constraints correctly, and acknowledges uncertainty. The technical README describes a comparison protocol.

Keep human review, recorded checks, and authority separate. A successful command or healthy workflow report cannot validate every statement in a knowledge page.
