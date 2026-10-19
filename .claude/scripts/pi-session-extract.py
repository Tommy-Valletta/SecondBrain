#!/usr/bin/env python3

































from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

VAULT = Path(__file__).resolve().parents[2]
OUT_DIR = VAULT / "outputs" / "session-summaries"

PLACEHOLDER = "_None recorded_"


                                                                            
         
                                                                            
def load(path: Path) -> list[dict]:
    entries = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                                                                               
                                                                            
                continue
    return entries


                                                                             
                                                                            
                                                                             
                                                                               
                                                    
BAD_TIMESTAMPS = 0


def iso(ts) -> str:
    global BAD_TIMESTAMPS
    if ts is None or ts == "":
        return ""
    if isinstance(ts, (int, float)):
        try:
            return datetime.fromtimestamp(ts / 1000, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        except Exception:
            BAD_TIMESTAMPS += 1
            return ""
    if isinstance(ts, str):
        try:
            dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        except Exception:
            BAD_TIMESTAMPS += 1
            return ""
    BAD_TIMESTAMPS += 1
    return ""


def blocks(msg: dict, kind: str):
    content = msg.get("content")
    if isinstance(content, list):
        for b in content:
            if isinstance(b, dict) and b.get("type") == kind:
                yield b


def text_of(msg: dict) -> str:
    content = msg.get("content")
    if isinstance(content, str):
        return content
    out = []
    if isinstance(content, list):
        for b in content:
            if isinstance(b, dict) and b.get("type") == "text":
                t = b.get("text")
                if isinstance(t, str):
                    out.append(t)
    return "\n".join(out)


                                                                            
                                                                   
                                                                            
                                                                               
                                                                             
SHELL_WRITE = [
                                                                              
                                                                      
    re.compile(r'(?<![->=\d&])>>?\s*(?![&(])(?:"([^"]+)"|\'([^\']+)\'|([^\s;&|>()]+))'),
    re.compile(r'\btee\s+(?:-a\s+)?(?:"([^"]+)"|\'([^\']+)\'|([^\s;&|]+))'),
    re.compile(r'\b(?:mv|cp|install)\s+[^;&|]*?\s(?:"([^"]+)"|\'([^\']+)\'|([^\s;&|]+))\s*(?:$|[;&|])'),
                                                                            
                                                                     
    re.compile(r'\b(?:touch|rm|rmdir|chmod|chown|ln)\s+(?:-\S+\s+)*(?:"([^"]+)"|\'([^\']+)\'|([^\s;&|]+))'),
]

                                                                              
                                                                          
                                                                             
                                                                     
HEREDOC = re.compile(r"<<-?\s*['\"]?(\w+)['\"]?\s*\n.*?^\s*\1\s*$", re.S | re.M)
SUBSHELL = re.compile(r'\$\([^)]*\)')

                                         
IGNORE_PATH = re.compile(r'^(/dev/|/proc/)|(^-)|(^\$)|(^\d+$)|(^&)')
                                                                          
VALID_PATH = re.compile(r'^[A-Za-z0-9._~/@+-]+$')


def norm_path(p: str) -> str | None:
    p = (p or "").strip().strip('"\'')
    if not p or len(p) < 3 or IGNORE_PATH.search(p):
        return None
    if "$" in p or "*" in p or "?" in p:                              
        return None
    if not VALID_PATH.match(p):                                                
        return None
                                                               
    if "/" not in p and not re.search(r'\.\w{1,5}$', p):
        return None
    if not re.search(r'[A-Za-z0-9]', p):
        return None
    home = str(Path.home())
    vault = str(VAULT)
    if p.startswith(vault + "/"):
        return p[len(vault) + 1:]
    if p.startswith(home + "/"):
        return "~/" + p[len(home) + 1:]
    return p


def files_from_shell(cmd: str) -> set[str]:
    cmd = HEREDOC.sub(" ", cmd or "")
    cmd = SUBSHELL.sub(" ", cmd)
    found = set()
    for pat in SHELL_WRITE:
        for m in pat.finditer(cmd):
            raw = next((g for g in m.groups() if g), None)
            n = norm_path(raw)
            if n:
                found.add(n)
    return found


                                                                            
            
                                                                            
def extract(entries: list[dict], session_path: Path) -> dict:
    d = {
        "session_id": "", "cwd": "", "version": "", "started": "", "ended": "",
        "model": "", "thinking": "",
        "prompts": [], "tools": {}, "errors": [], "written": [], "read": [],
        "user_bash": [], "compactions": [], "turns": 0, "thinking_blocks": 0,
        "assistant_chars": 0,
    }
    calls: dict[str, str] = {}                                   
    written, readf = [], []

    for e in entries:
        t = e.get("type")
        ts = iso(e.get("timestamp"))
        if ts:
            d["ended"] = ts
            if not d["started"]:
                d["started"] = ts

        if t == "session":
            d["session_id"] = e.get("id", "")
            d["cwd"] = e.get("cwd", "")
            d["version"] = str(e.get("version", ""))
        elif t == "model_change":
            d["model"] = f'{e.get("provider","")}/{e.get("modelId","")}'.strip("/")
        elif t == "thinking_level_change":
            d["thinking"] = e.get("thinkingLevel", "")
        elif t == "compaction":
            d["compactions"].append({
                "id": e.get("id", ""), "parentId": e.get("parentId", ""),
                "ts": ts, "firstKept": e.get("firstKeptEntryId", ""),
                "tokensBefore": e.get("tokensBefore", 0),
                "usage": e.get("usage") or {},
                "chars": len(e.get("summary") or ""),
            })
        elif t == "message":
            m = e.get("message") or {}
            role = m.get("role")

            if role == "user":
                txt = text_of(m).strip()
                if txt:
                    d["prompts"].append({"ts": ts, "text": txt})
            elif role == "assistant":
                d["turns"] += 1
                d["assistant_chars"] += len(text_of(m))
                d["thinking_blocks"] += sum(1 for _ in blocks(m, "thinking"))
                for b in blocks(m, "toolCall"):
                    name = b.get("name", "?")
                    d["tools"][name] = d["tools"].get(name, 0) + 1
                    calls[b.get("id", "")] = name
                    args = b.get("arguments")
                    if isinstance(args, str):
                        try:
                            args = json.loads(args)
                        except Exception:
                            args = {}
                    if not isinstance(args, dict):
                        continue
                                                                     
                    p = norm_path(args.get("path") or args.get("file_path") or "")
                    if p:
                        (written if name in ("write", "edit") else readf).append(p)
                    if name == "bash":
                        for f in files_from_shell(args.get("command", "")):
                            written.append(f)
            elif role == "toolResult":
                if m.get("isError"):
                    name = m.get("toolName") or calls.get(m.get("toolCallId", ""), "?")
                    body = m.get("content")
                    if isinstance(body, list):
                        body = " ".join(
                            str(b.get("text", "")) for b in body if isinstance(b, dict)
                        )
                                                                            
                                                                            
                                                                      
                    flat = re.sub(r"\s+", " ", str(body or "")).strip()
                    d["errors"].append({
                        "tool": name,
                        "msg": ("..." + flat[-200:]) if len(flat) > 200 else flat,
                    })
            elif role == "bashExecution":
                cmd = (m.get("command") or "").strip()
                if cmd:
                    d["user_bash"].append(cmd)
                    written.extend(files_from_shell(cmd))

                                        
    d["written"] = list(dict.fromkeys(written))
    d["read"] = [p for p in dict.fromkeys(readf) if p not in set(d["written"])]
    return d


                                                                            
           
                                                                            
def bullets(items, empty=PLACEHOLDER, limit=None):
    items = [i for i in items if i]
    if not items:
        return empty
    shown = items[:limit] if limit else items
    out = "\n".join(f"- {i}" for i in shown)
    if limit and len(items) > limit:
        out += f"\n- _...and {len(items) - limit} more_"
    return out


def render(d: dict, session_path: Path) -> str:
    sid = d["session_id"] or session_path.stem
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    project = Path(d["cwd"]).name if d["cwd"] else "unknown"

    tools = sorted(d["tools"].items(), key=lambda kv: -kv[1])
    ledger = [f"`{n}` x{c}" for n, c in tools]

                                                                       
    outputs = [f"`{p}`" for p in d["written"]]

    fm = [
        "---",
        f"id: {sid}",
        "type: session_summary",
        f"project: {project}",
        "synthetic: false",
        "synthetic_reason: ",
        "source_type: pi",
        "harness: pi",                                                      
        f"harness_session_version: {d['version']}",
        f"model: {d['model']}",
        f"thinking_level: {d['thinking']}",
                                                                           
                                                                               
                                                                             
                                                                       
                                                                              
                                                                                
                                                                         
                                                                   
                            
        "status: captured",
        "confidence: high",                                            
        f"created_at: {d['started'] or now}",
        f"updated_at: {now}",
        f"extracted_at: {now}",
        "extracted_by: .claude/scripts/pi-session-extract.py",
        "sources: []",
        "links: []",
        "reviewed: false",
        "tags:",
        "  - session",
        "  - pi",
        "---",
        "",
        f"# Session: {sid}",
        "",
        "> Deterministically extracted from the pi session file. No LLM was used to",
        "> produce anything below; every line is read off a typed entry.",
        "",
        "## Prompt Summary",
        "",
        bullets([re.sub(r"\s+", " ", p["text"])[:300] for p in d["prompts"]]),
        "",
        "## Key Outputs",
        "",
        bullets(outputs, limit=40),
        "",
        "## Ledger",
        "",
        f"- Turns: {d['turns']}",
        f"- Tool calls: {sum(d['tools'].values())} — {', '.join(ledger) if ledger else 'none'}",
        f"- Errors: {len(d['errors'])}",
        f"- Thinking blocks: {d['thinking_blocks']}",
        f"- Assistant prose: {d['assistant_chars']:,} chars",
        "",
        "## Files Changed",
        "",
        bullets([f"`{p}`" for p in d["written"]], limit=60),
        "",
        "## Files Read",
        "",
        bullets([f"`{p}`" for p in d["read"]], limit=40),
        "",
        "## Errors",
        "",
        bullets([f"`{e['tool']}` — {e['msg']}" for e in d["errors"]], limit=25),
        "",
        "## User Shell Commands",
        "",
        bullets([f"`{c[:200]}`" for c in d["user_bash"]], limit=25),
        "",
    ]

                                                                              
                                                                           
                                                                       
    fm += ["## Compaction Ledger", ""]
    if d["compactions"]:
        fm += [
            "| # | when | tokens before | summary chars | in/out tokens | entry id | parent |",
            "|---|------|--------------:|--------------:|---------------|----------|--------|",
        ]
        for i, c in enumerate(d["compactions"], 1):
            u = c["usage"] or {}
            fm.append(
                f"| {i} | {c['ts']} | {c['tokensBefore']:,} | {c['chars']:,} | "
                f"{u.get('input',u.get('inputTokens','?'))}/{u.get('output',u.get('outputTokens','?'))} | "
                f"`{c['id'][:12]}` | `{c['parentId'][:12]}` |"
            )
        fm += ["", "_Summary prose is in the session file, reachable by entry id._"]
    else:
        fm.append("_No compactions_")

    fm += [
        "",
        "## Follow-up Tasks",
        "",
        "_Not derivable without synthesis (Tier 2)_",
        "",
        "## Open Questions",
        "",
        "_Not derivable without synthesis (Tier 2)_",
        "",
        "## Provenance",
        "",
        f"- Session ID: {sid}",
        f"- Started: {d['started']}",
        f"- Ended: {d['ended']}",
        f"- Working Directory: {d['cwd']}",
        f"- Transcript: {session_path}",
        "",
    ]
    return "\n".join(fm)


                                                                
 
                                                                             
                                                                             
                                                                              
                                                                         
                                                                              
                                                                               
                                                                             
                                            
 
                                                                  
PIPELINE_KEYS = (
    "status", "promoted_to", "promoted_hash", "reviewed",
    "sources", "links", "synthetic_reason",
)


def existing_frontmatter(path: Path) -> dict:

    if not path.exists():
        return {}
    out, inside = {}, False
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for i, line in enumerate(fh):
                line = line.rstrip("\n")
                if i == 0 and line == "---":
                    inside = True
                    continue
                if inside and line == "---":
                    break
                if inside and re.match(r"^[A-Za-z_][\w-]*:", line):
                    k, _, v = line.partition(":")
                    out[k.strip()] = v.strip()
    except OSError:
        return {}
    return out


def preserve_pipeline_state(md: str, prior: dict) -> str:

    if not prior:
        return md
    lines = md.split("\n")
    try:
        end = lines.index("---", 1)
    except ValueError:
        return md
    kept = {k: prior[k] for k in PIPELINE_KEYS if k in prior}
    if not kept:
        return md
    out, seen = [], set()
    for idx, line in enumerate(lines):
        if 0 < idx < end:
            m = re.match(r"^([A-Za-z_][\w-]*):", line)
            if m and m.group(1) in kept:
                key = m.group(1)
                out.append(f"{key}: {kept[key]}")
                seen.add(key)
                continue
        if idx == end:
                                                                      
            for k, v in kept.items():
                if k not in seen:
                    out.append(f"{k}: {v}")
        out.append(line)
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("session", nargs="?", default=os.environ.get("PI_SESSION_FILE", ""))
    ap.add_argument("-o", "--out")
    ap.add_argument("--stdout", action="store_true")
    a = ap.parse_args()

    if not a.session:
        print("no session file (pass a path or set PI_SESSION_FILE)", file=sys.stderr)
        return 2
    sp = Path(a.session)
    if not sp.exists():
        print(f"no such session file: {sp}", file=sys.stderr)
        return 2

    d = extract(load(sp), sp)
    md = render(d, sp)

                                                                               
                                     
    if BAD_TIMESTAMPS:
        print(f"WARNING: {BAD_TIMESTAMPS} unparseable timestamps -- session"
              f" format may have changed", file=sys.stderr)
    if not d["started"]:
        print("WARNING: no session start time recovered; filename date will be"
              " today's, not the session's", file=sys.stderr)

    if a.stdout:
        sys.stdout.write(md)
        return 0

    if a.out:
        out = Path(a.out)
    else:
        day = (d["started"] or datetime.now(timezone.utc).isoformat())[:10]
        out = OUT_DIR / f"{day}-{d['session_id'] or sp.stem}.md"
    out.parent.mkdir(parents=True, exist_ok=True)
    prior = existing_frontmatter(out)
    md = preserve_pipeline_state(md, prior)
    out.write_text(md, encoding="utf-8")
    note = ""
    if prior.get("status") and prior["status"] != "captured":
        note = f"  [preserved status: {prior['status']}"
        if prior.get("promoted_hash"):
            note += f", promoted_hash: {prior['promoted_hash']}"
        note += "]"
    print(f"wrote {out} ({len(md):,} bytes){note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
