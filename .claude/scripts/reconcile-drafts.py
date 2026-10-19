#!/usr/bin/env python3











































import argparse
import glob
import os
import re
import sys
from datetime import datetime, timezone

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(SCRIPT_DIR, "lib"))
from frontmatter import split_fence, set_field              

VAULT_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
SUMMARY_DIR = os.path.join(VAULT_DIR, "outputs", "session-summaries")
PROJECTS_DIR = os.path.expanduser("~/.claude/projects")


def fm_status_lines(fm):
    return [l for l in fm if re.match(r"^\s*status\s*:", l)]


def fm_get(fm, key):
    pat = re.compile(r"^\s*" + re.escape(key) + r"\s*:\s*(.*?)\s*$")
    for l in fm:
        m = pat.match(l)
        if m:
            return m.group(1)
    return None


def resolve_transcript(text, stub_path):


    m = re.search(r"^- Transcript:\s*`([^`]+)`", text, re.MULTILINE)
    if m and os.path.isfile(m.group(1)):
        return m.group(1)
    fm, _, ok = split_fence(text)
    sid = None
    if ok:
        sid = fm_get(fm, "id") or fm_get(fm, "session_id")
    if not sid:
        base = os.path.basename(stub_path)[:-3]
        sid = re.sub(r"^\d{4}-\d{2}-\d{2}-", "", base)
    if sid and os.path.isdir(PROJECTS_DIR):
        hits = glob.glob(os.path.join(PROJECTS_DIR, "**", f"{sid}*.jsonl"), recursive=True)
        for h in hits:
            if os.path.isfile(h):
                return h
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--idle-hours", type=float, default=6.0,
                    help="a draft whose transcript changed within this window is treated as an active session and skipped")
    ap.add_argument("--dry-run", action="store_true", help="report what would flip; write nothing")
    ap.add_argument("--limit", type=int, default=0, help="cap the number of flips this run (0 = no cap)")
    args = ap.parse_args()

    now = datetime.now(timezone.utc)
    ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    now_epoch = now.timestamp()

    counts = dict(flipped=0, synthetic=0, missing_transcript=0, fresh=0,
                  refused_multi_status=0, no_fence=0, not_draft=0)
    flipped_files = []

    for stub in sorted(glob.glob(os.path.join(SUMMARY_DIR, "*.md"))):
        try:
            text = open(stub, encoding="utf-8").read()
        except Exception:
            continue
        fm, _, ok = split_fence(text)
        if not ok:
            counts["no_fence"] += 1
            continue
        st_lines = fm_status_lines(fm)
        if len(st_lines) != 1:
                                                                               
            counts["refused_multi_status" if len(st_lines) > 1 else "not_draft"] += 1
            continue
        if fm_get(fm, "status") != "draft":
            counts["not_draft"] += 1
            continue
        if (fm_get(fm, "synthetic") or "").lower() == "true":
            counts["synthetic"] += 1
            continue
        tx = resolve_transcript(text, stub)
        if not tx:
            counts["missing_transcript"] += 1
            continue
        try:
            idle_h = (now_epoch - os.path.getmtime(tx)) / 3600.0
        except OSError:
            counts["missing_transcript"] += 1
            continue
        if idle_h < args.idle_hours:
            counts["fresh"] += 1
            continue
        if args.limit and counts["flipped"] >= args.limit:
            break
        if not args.dry_run:
            new, ch1 = set_field(text, "status", "captured")
            new, _ = set_field(new, "updated_at", ts)
            if ch1:
                open(stub, "w", encoding="utf-8").write(new)
        counts["flipped"] += 1
        flipped_files.append(os.path.basename(stub))

    tag = "[dry-run] " if args.dry_run else ""
    print(f"{tag}reconcile-drafts: flipped={counts['flipped']} "
          f"skipped(synthetic={counts['synthetic']}, missing_transcript={counts['missing_transcript']}, "
          f"active/fresh={counts['fresh']}, refused_multi_status={counts['refused_multi_status']}, "
          f"no_fence={counts['no_fence']})")
                                                                         
    if counts["missing_transcript"]:
        print(f"{tag}note: {counts['missing_transcript']} draft(s) have no resolvable transcript — "
              f"they cannot be ingested and were left as draft (see Decision 3 for deletion policy).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
