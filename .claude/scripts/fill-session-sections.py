#!/usr/bin/env python3






















import argparse
import glob
import json
import os
import re
import sys

HOME = os.path.expanduser("~")
PROJECTS_DIR = os.path.join(HOME, ".claude", "projects")

LEDGER_MAX = 30                                                       
FILES_MAX = 40                                                      
RESULT_CHARS = 100                           
TARGET_CHARS = 90                            
PROMPT_CHARS = 500                               
CLOSING_CHARS = 800                               

WRITE_TOOLS = {"Edit", "Write", "NotebookEdit", "MultiEdit"}
PLACEHOLDER_RE = re.compile(r"^_To be (filled|linked)", re.M)


                                            

def fm(text, field):
    m = re.search(r"^%s:[ \t]*(.*)$" % re.escape(field), text, re.M)
    return m.group(1).strip() if m else ""


def session_id_of(path, text):
    sid = fm(text, "id")
    if sid:
        return sid
    return re.sub(r"^\d{4}-\d{2}-\d{2}-", "", os.path.basename(path)[:-3])


def cwd_of(text):
    m = re.search(r"^- Working Directory: `(.*)`[ \t]*$", text, re.M)
    return m.group(1) if m else ""


def resolve_transcript(text, sid):
    m = re.search(r"^- Transcript: `(.*)`[ \t]*$", text, re.M)
    if m and m.group(1) and os.path.isfile(m.group(1)):
        return m.group(1)
    hits = sorted(glob.glob(os.path.join(PROJECTS_DIR, "*", sid + "*.jsonl")))
    return hits[0] if hits else None


                                          

def iter_records(path):
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def block_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        out = []
        for b in content:
            if isinstance(b, str):
                out.append(b)
            elif isinstance(b, dict) and b.get("type") == "text":
                out.append(b.get("text") or "")
        return "\n".join(x for x in out if x)
    return ""


def one_line(s, limit):
    s = re.sub(r"\s+", " ", (s or "")).strip().replace("`", "'")
    if len(s) > limit:
        s = s[:limit - 1].rstrip() + "…"
    return s


def short_tool(name):
    if name.startswith("mcp__"):
        parts = name.split("__")
        return parts[-1] if len(parts) > 1 else name
    return name


def target_of(tool, inp):
    inp = inp if isinstance(inp, dict) else {}
    for key in ("file_path", "notebook_path", "path"):
        if inp.get(key):
            return str(inp[key])
    if tool == "Bash":
        return str(inp.get("description") or inp.get("command") or "")
    if tool in ("Grep", "Glob"):
        pat = str(inp.get("pattern") or "")
        where = str(inp.get("path") or "")
        return (pat + (" in " + where if where else "")).strip()
    if tool in ("Task", "Agent"):
        return str(inp.get("description") or inp.get("subagent_type") or "")
    if tool == "WebFetch":
        return str(inp.get("url") or "")
    if tool == "WebSearch":
        return str(inp.get("query") or "")
    for key in ("query", "prompt", "command", "url", "name",
                "summary", "issueIdOrKey", "pattern", "cloudId"):
        if inp.get(key):
            return str(inp[key])
    for v in inp.values():
        if isinstance(v, str) and v.strip():
            return v
    return ""


def extract(transcript_path):

    calls = []                                         
    writes = []                                          
    seen = set()
    results = {}                                           
    first_prompt = ""
    closing = ""

    for rec in iter_records(transcript_path):
        rtype = rec.get("type")
        msg = rec.get("message") or {}
        content = msg.get("content")

        if rtype == "user" and not first_prompt:
            t = block_text(content).strip()
            if t and not t.startswith("<"):
                first_prompt = t

        if rtype == "assistant":
            t = block_text(content).strip()
            if t:
                closing = t

        if not isinstance(content, list):
            continue
        for b in content:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "tool_use":
                tool = b.get("name") or "?"
                inp = b.get("input") or {}
                calls.append((tool, target_of(tool, inp), b.get("id")))
                if tool in WRITE_TOOLS:
                    fp = inp.get("file_path") or inp.get("notebook_path")
                    if fp and fp not in seen:
                        seen.add(fp)
                        writes.append(fp)
            elif b.get("type") == "tool_result":
                results[b.get("tool_use_id")] = (
                    block_text(b.get("content")), bool(b.get("is_error"))
                )

    return calls, writes, first_prompt, closing, results


                                 

def rel(p, cwd):
    if cwd and p.startswith(cwd):
        return p[len(cwd):].lstrip("/") or p
    return p


def render_key_outputs(calls, results, cwd):
    if not calls:
        return None
    items = []
    for tool, target, tuid in calls[:LEDGER_MAX]:
        txt, err = results.get(tuid, ("", False))
        res = one_line(txt, RESULT_CHARS)
        if err:
            res = "ERROR: " + res
        line = "- `%s`" % short_tool(tool)
        tgt = one_line(rel(target, cwd), TARGET_CHARS)
        if tgt:
            line += " · %s" % tgt
        if res:
            line += " — %s" % res
        items.append(line)
    if len(calls) > LEDGER_MAX:
        items.append("- _…and %d more tool calls_" % (len(calls) - LEDGER_MAX))
    return "\n".join(items)


def render_files(writes, cwd):
    if not writes:
        return "_No files changed_"
    ordered = sorted(rel(p, cwd) for p in writes)
    items = ["- `%s`" % p for p in ordered[:FILES_MAX]]
    if len(ordered) > FILES_MAX:
        items.append("- _…and %d more files_" % (len(ordered) - FILES_MAX))
    return "\n".join(items)


def render_ledger(calls, closing):
    if not calls and not closing:
        return None
    lines = []
    if calls:
        tally = {}
        for tool, _, _ in calls:
            k = short_tool(tool)
            tally[k] = tally.get(k, 0) + 1
        ordered = sorted(tally.items(), key=lambda kv: (-kv[1], kv[0]))
        lines.append("**Tool trail:** " +
                     " · ".join("%s×%d" % (k, v) for k, v in ordered))
        lines.append("")
    lines.append("**Closing statement:**")
    lines.append("")
    if closing:
        body = closing
        if len(body) > CLOSING_CHARS:
            body = body[:CLOSING_CHARS].rstrip() + "\n\n_[truncated]_"
        lines.extend(("> " + ln) if ln else ">" for ln in body.split("\n"))
    else:
        lines.append("> _No closing assistant message in transcript._")
    return "\n".join(lines)


                                       

def replace_section(text, heading, body, no_clobber=False):
    m = re.search(r"^## %s[ \t]*$" % re.escape(heading), text, re.M)
    if not m:
        return text, False
    start = m.end()
    nxt = re.search(r"^## ", text[start:], re.M)
    end = start + (nxt.start() if nxt else len(text) - start)
    current = text[start:end]
    if no_clobber and current.strip() and not PLACEHOLDER_RE.search(current):
        return text, False
    new = text[:start] + "\n\n" + body.rstrip() + "\n\n" + text[end:]
    return new, (new != text)


def rename_decisions(text):
    if re.search(r"^## Ledger[ \t]*$", text, re.M):
        return text, False
    new, n = re.subn(r"^## Decisions Made[ \t]*$", "## Ledger",
                     text, count=1, flags=re.M)
    return new, bool(n)


                              

def process(path, transcript=None, cwd=None, no_clobber=False, dry_run=False):
    with open(path, "r", errors="replace") as fh:
        text = fh.read()

    sid = session_id_of(path, text)
    use_cwd = cwd if cwd is not None else cwd_of(text)
    tx = transcript if (transcript and os.path.isfile(transcript))\
        else resolve_transcript(text, sid)
    if not tx:
        return "no-transcript", 0, 0

    calls, writes, first_prompt, closing, results = extract(tx)
    if not calls:
        return "no-tool-calls", 0, 0

    new = text
    new, _ = rename_decisions(new)

    if first_prompt:
        p = first_prompt
        if len(p) > PROMPT_CHARS:
            p = p[:PROMPT_CHARS] + "\n\n_[truncated]_"
        new, _ = replace_section(new, "Prompt Summary", p, no_clobber=True)

    for heading, body in (
        ("Key Outputs", render_key_outputs(calls, results, use_cwd)),
        ("Files Changed", render_files(writes, use_cwd)),
        ("Ledger", render_ledger(calls, closing)),
    ):
        if body is None:
            continue
        new, _ = replace_section(new, heading, body, no_clobber=no_clobber)

    if new == text:
        return "no-change", len(calls), len(writes)
    if dry_run:
        return "would-change", len(calls), len(writes)

    tmp = path + ".fill.tmp"
    with open(tmp, "w") as fh:
        fh.write(new)
    os.replace(tmp, path)
    return "changed", len(calls), len(writes)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--dir", default=None,
                    help="summaries dir for --all (default: vault outputs/session-summaries)")
    ap.add_argument("--transcript", default=None)
    ap.add_argument("--cwd", default=None)
    ap.add_argument("--no-clobber", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    targets = list(args.files)
    if args.all:
        d = args.dir or os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "..", "..",
            "outputs", "session-summaries")
        targets += sorted(glob.glob(os.path.join(os.path.abspath(d), "*.md")))
    if not targets:
        ap.error("no files (pass paths or --all)")
    if args.limit:
        targets = targets[:args.limit]

    tally = {}
    for p in targets:
        try:
            outcome, ncalls, nfiles = process(
                p, transcript=args.transcript, cwd=args.cwd,
                no_clobber=args.no_clobber, dry_run=args.dry_run)
        except Exception as exc:                                            
            outcome, ncalls, nfiles = "error:%s" % type(exc).__name__, 0, 0
        tally[outcome] = tally.get(outcome, 0) + 1
        if len(targets) == 1 or outcome.startswith(("changed", "would-change", "error")):
            print("%-14s calls=%-4d files=%-3d %s"
                  % (outcome, ncalls, nfiles, os.path.basename(p)))
    print("--- " + " | ".join("%s=%d" % kv for kv in sorted(tally.items())))


if __name__ == "__main__":
    main()
