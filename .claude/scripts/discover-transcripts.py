#!/usr/bin/env python3
















import argparse
import json
import os
import re
import sys
import time
from datetime import datetime, timezone

VAULT_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SUMMARIES_DIR = os.path.join(VAULT_DIR, "outputs", "session-summaries")
PROJECTS_DIR = os.path.expanduser("~/.claude/projects")

                                                                         
SYNTHETIC_CWD_RULES = [
    (re.compile(r"^/(private/)?tmp(/|$)"), "cwd:tmp"),
    (re.compile(re.escape(os.path.expanduser("~/.claude/jobs")) + r"(/|$)"), "cwd:claude-jobs"),
    (re.compile(re.escape(os.path.expanduser("~/.ablation-scratch")) + r"(/|$)"), "cwd:ablation-scratch"),
    (re.compile(re.escape(os.path.expanduser("~/.brain-tax")) + r"(/|$)"), "cwd:brain-tax"),
    (re.compile(re.escape(os.path.expanduser("~/outputs/validation")) + r"(/|$)"), "cwd:validation"),
    (re.compile(re.escape(os.path.expanduser("~/abl-test"))), "cwd:abl-test"),
]


def existing_stub_sids():
    sids = set()
    if not os.path.isdir(SUMMARIES_DIR):
        return sids
    for f in os.listdir(SUMMARIES_DIR):
        if not f.endswith(".md"):
            continue
        b = f[:-3]
                                                                      
        sids.add(b[11:] if len(b) > 11 and b[10] == "-" else b)
    return sids


def transcript_cwd(path):

    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for _ in range(5):
                line = fh.readline()
                if not line:
                    break
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                cwd = obj.get("cwd")
                if cwd:
                    return cwd
    except OSError:
        pass
    return None


def classify_synthetic(cwd):
    if not cwd:
        return False, ""
    for rx, reason in SYNTHETIC_CWD_RULES:
        if rx.search(cwd):
            return True, reason
    return False, ""


def walk_transcripts():

    seen = set()
    for root, _dirs, files in os.walk(PROJECTS_DIR):
        for f in files:
            if not f.endswith(".jsonl"):
                continue
            p = os.path.join(root, f)
            rp = os.path.realpath(p)
            if rp in seen:
                continue
            seen.add(rp)
            yield rp


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--idle-hours", type=float, default=6.0)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--limit", type=int, default=0, help="cap stubs created this run (0 = no cap)")
    args = ap.parse_args()

    sids = existing_stub_sids()
    now = time.time()
    counts = {"created": 0, "have_stub": 0, "fresh": 0, "empty": 0}

    for tx in sorted(walk_transcripts(), key=os.path.getmtime, reverse=True):
        sid = os.path.basename(tx)[:-6]
        if sid in sids:
            counts["have_stub"] += 1
            continue
        try:
            st = os.stat(tx)
        except OSError:
            continue
        if st.st_size == 0:
            counts["empty"] += 1
            continue
        if (now - st.st_mtime) / 3600.0 < args.idle_hours:
            counts["fresh"] += 1
            continue
        if args.limit and counts["created"] >= args.limit:
            break

        date_prefix = datetime.fromtimestamp(st.st_mtime, tz=timezone.utc).strftime("%Y-%m-%d")
        ts = datetime.fromtimestamp(st.st_mtime, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        cwd = transcript_cwd(tx)
        synthetic, reason = classify_synthetic(cwd)
        is_agent = sid.startswith("agent-")
        project = os.path.basename(cwd) if cwd else os.path.basename(os.path.dirname(tx)).split("-")[-1]
        stub_path = os.path.join(SUMMARIES_DIR, f"{date_prefix}-{sid}.md")

        stub = f"""---
id: {sid}
type: session_summary
project: {project}
synthetic: {str(synthetic).lower()}
synthetic_reason: {reason}
source_type: claude_code
status: captured
confidence: medium
created_at: {ts}
updated_at: {ts}
sources: []
links: []
reviewed: false
tags:
  - session
  - claude-code
  - discovered-from-transcript{chr(10) + '  - subagent' if is_agent else ''}
---

# Session: {sid}

## Prompt Summary

_To be filled at session end from transcript_

## Key Outputs

_To be filled by session end_

## Ledger

_To be filled by session end from the transcript (tool trail + closing statement)_

## Files Changed

_To be filled by session end_

## Follow-up Tasks

_To be filled by session end_

## Open Questions

_To be filled by session end_

## Provenance

- Transcript: `{tx}`
- Session ID: `{sid}`
- Working Directory: `{cwd or "unknown"}`
- Discovered: {datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")} by discover-transcripts.py (no SessionStart stub existed)
"""
        if not args.dry_run:
            with open(stub_path, "w", encoding="utf-8") as fh:
                fh.write(stub)
        counts["created"] += 1
        sids.add(sid)

    tag = "[dry-run] " if args.dry_run else ""
    print(f"{tag}discover-transcripts: created={counts['created']} "
          f"skipped(have_stub={counts['have_stub']}, active/fresh={counts['fresh']}, empty={counts['empty']})")


if __name__ == "__main__":
    main()
