#!/usr/bin/env bash
set -uo pipefail

VAULT="${VAULT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SNAPDIR="$VAULT/outputs/vitals"
STAMP="$(date -u +%Y-%m-%dT%H%M%SZ)"

MODE="markdown"; SNAPSHOT=1; ONE_METRIC=""; DIFF_A=""; DIFF_B=""; TAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json)          MODE="json"; shift ;;
    --markdown|--md) MODE="markdown"; shift ;;
    --both)          MODE="both"; shift ;;
    --no-snapshot)   SNAPSHOT=0; shift ;;
    --tag)           TAG="${2:?--tag needs a name}"; shift 2 ;;
    --metric)        ONE_METRIC="${2:?--metric needs a key}"; MODE="metric"; SNAPSHOT=0; shift 2 ;;
    --list)          ls -1 "$SNAPDIR"/vitals-*.json 2>/dev/null; exit 0 ;;
    --help|-h)
      cat <<'EOHELP'
Usage: brain-vitals.sh [options]

  brain-vitals.sh                      measure, snapshot, print markdown
  brain-vitals.sh --json               measure, snapshot, print JSON
  brain-vitals.sh --both               both renderings
  brain-vitals.sh --no-snapshot        measure, print, write nothing
  brain-vitals.sh --metric KEY         print one bare value (for pass/fail gates)
  brain-vitals.sh --diff A B           what moved between two snapshots
  brain-vitals.sh --diff last          latest snapshot vs the one before it
  brain-vitals.sh --list               list snapshots
  brain-vitals.sh --tag NAME           label this snapshot (vitals-NAME.json)
EOHELP
      exit 0 ;;
    --diff)
      if [ "${2:-}" = "last" ]; then
        _pair="$(SNAPDIR="$SNAPDIR" python3 - <<'PY'
import glob, json, os
snaps = []
for p in sorted(glob.glob(os.path.join(os.environ["SNAPDIR"], "vitals-*.json"))):
    try:
        snaps.append((json.load(open(p)).get("taken_at", ""), p))
    except Exception:
        pass  # an unreadable snapshot is skipped, not fatal — see the set -e note
snaps.sort()
if len(snaps) >= 2:
    print(snaps[-2][1]); print(snaps[-1][1])
PY
)"
        DIFF_A="$(printf '%s\n' "$_pair" | sed -n 1p)"
        DIFF_B="$(printf '%s\n' "$_pair" | sed -n 2p)"
        if [ -z "$DIFF_A" ] || [ "$DIFF_A" = "$DIFF_B" ]; then
          echo "need >=2 snapshots to diff" >&2; exit 1
        fi
        shift 2
      else
        DIFF_A="${2:?--diff needs BEFORE}"; DIFF_B="${3:?--diff needs AFTER}"; shift 3
      fi
      MODE="diff" ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ "$MODE" = "diff" ]; then
  A="$DIFF_A" B="$DIFF_B" python3 - <<'PY'
import json, os
a = json.load(open(os.environ["A"])); b = json.load(open(os.environ["B"]))
am = {m["key"]: m for m in a["metrics"]}; bm = {m["key"]: m for m in b["metrics"]}
print("\nbrain-vitals diff")
print(f"  before: {a['taken_at']}  ({os.path.basename(os.environ['A'])})")
print(f"  after : {b['taken_at']}  ({os.path.basename(os.environ['B'])})\n")
print(f"{'':4}{'metric':42}{'before':>14}{'after':>14}{'delta':>18}")
print("-" * 92)
moved = 0
for k in sorted(set(am) | set(bm)):
    av = am.get(k, {}).get("value"); bv = bm.get(k, {}).get("value")
    if av == bv:
        continue
    moved += 1
    try:
        d = f"{float(bv) - float(av):+g}"
        if float(av):
            d += f" ({(float(bv)-float(av))/abs(float(av))*100:+.1f}%)"
    except (TypeError, ValueError):
        d = "changed"
    mark = "NEW " if av is None else ("GONE" if bv is None else "    ")
    print(f"{mark}{k:42}{str(av):>14}{str(bv):>14}{d:>18}")
print(f"\n{moved} metric(s) moved, {len(set(am)|set(bm))-moved} unchanged.")
for tag, snap in (("before", a), ("after", b)):
    if snap.get("verdict") != "OK":
        print(f"  !! {tag} verdict={snap.get('verdict')}: {snap.get('verdict_reason')}")
PY
  exit 0
fi

TSV="$(mktemp -t vitals)"; NOTE="$(mktemp -t vitalsnote)"
trap 'rm -f "$TSV" "$NOTE" 2>/dev/null' EXIT
: > "$NOTE"

VAULT="$VAULT" DECKS="${DECKS:-$HOME/.claude/html-mode/sessions}" \
TSV="$TSV" NOTE="$NOTE" python3 - <<'PY'
import json, os, re, glob, collections

V     = os.environ["VAULT"]
SS    = os.path.join(V, "outputs/session-summaries")
WS    = os.path.join(V, "wiki/summaries")
TPL   = os.path.join(V, ".claude/templates")
KNOW  = os.path.join(V, "wiki/knowledge")
LOGS  = os.path.join(V, "wiki/logs")
DECKS = os.environ["DECKS"]
PROBE = os.path.join(V, "outputs/standup/probe-trend.jsonl")
GAUGE = os.path.join(V, "outputs/.ingest-status.json")
CM    = os.path.join(V, "CLAUDE.md")

tsv  = open(os.environ["TSV"], "w")
note_f = open(os.environ["NOTE"], "w")

def emit(key, value, prov, section, meaning, command=""):
    tsv.write("\t".join(str(x).replace("\t", " ") for x in
                        (key, value, prov, section, meaning, command)) + "\n")

def note(msg):
    note_f.write(msg + "\n")

def pct(a, b):
    return round(100.0 * a / b, 1) if b else 0.0

def read(p, n=None):
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            return f.read() if n is None else f.read(n)
    except OSError:
        return ""

SYN_RE = re.compile(
    r"^(validation|tmp|cwd|judge-cwd|p3c.*|phase3.*|p0-.*|gate[0-9]+.*|"
    r"ensemble-.*|demo-.*|cwd-.*|p4-.*|p4cal|p4probe|abl-test[0-9]*|.*-tmp)$")
REAL_RE = re.compile(
    os.environ.get("BRAIN_REAL_PROJECT_RE", r"^(master|personal|notes|default)$"))

TERMINAL = {"promoted", "skipped"}
KNOWN = {"promoted", "skipped", "draft", "captured", "orphaned"}

FENCE_KEYS = ("status", "project", "entrypoint", "synthetic", "synthetic_reason")

def frontmatter(text):
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    if end < 0:
        return {}
    fm, dupes = {}, set()
    for line in text[3:end].split("\n"):
        m = re.match(r"^([a-z_]+):\s*(.*)$", line)
        if not m:
            continue
        k, val = m.group(1), m.group(2).strip()
        if k in FENCE_KEYS:
            if k in fm:
                dupes.add(k)
            else:
                fm[k] = val
    fm["_dupes"] = dupes
    return fm

files = sorted(glob.glob(os.path.join(SS, "*.md")))
rows, ambiguous = [], 0
for p in files:
    t = read(p)
    fm = frontmatter(t)
    if fm.get("_dupes"):
        ambiguous += 1
    rows.append({
        "path": p,
        "project": fm.get("project") or "?",
        "status": fm.get("status") or "?",
        "entrypoint": fm.get("entrypoint") or "",
        "synthetic": fm.get("synthetic") or "",
        "syn_reason": fm.get("synthetic_reason") or "",
        "text": t,
    })

TOTAL = len(rows)
emit("corpus_total", TOTAL, "measured", "pipeline",
     "Layer 3/4 raw volume", "ls outputs/session-summaries/*.md | wc -l")
emit("corpus_ambiguous_frontmatter", ambiguous, "measured", "pipeline",
     "frontmatter boundaries: files with >1 status/project line INSIDE the fence — nonzero means a parser must refuse",
     "position-scoped frontmatter parse")
if ambiguous:
    note(f"AMBIGUOUS FRONTMATTER in {ambiguous} file(s) — fence holds duplicate keys")

hist = collections.Counter(r["status"] for r in rows)
unknown_labels, unknown_n = [], 0
for label, n in sorted(hist.items(), key=lambda kv: -kv[1]):
    safe = re.sub(r"[^a-zA-Z0-9_]", "_", label)
    emit(f"status_{safe}", n, "measured", "pipeline",
         f"sessions with status '{label}'", "frontmatter-fence histogram")
    if label not in KNOWN:
        unknown_labels.append(f"{label}={n}")
        unknown_n += n

emit("status_unknown_count", unknown_n, "measured", "pipeline",
     "sessions in a status the pipeline does not model — nonzero MUST alarm",
     "complement of KNOWN over the live histogram")
emit("status_unknown_labels", ";".join(unknown_labels) or "none", "measured", "pipeline",
     "the actual unrecognised labels, named not dropped", "same")
if unknown_n:
    note("UNKNOWN STATUS present: " + ";".join(unknown_labels))

terminal_n = sum(n for s, n in hist.items() if s in TERMINAL)
BACKLOG = TOTAL - terminal_n
emit("backlog_by_complement", BACKLOG, "measured", "pipeline",
     "total minus terminal states — backlog regardless of label",
     "total - count(promoted) - count(skipped)")

try:
    g = json.load(open(GAUGE))
except Exception:
    g = {}
gp = g.get("pending", "?")
emit("gauge_pending", gp, "measured", "pipeline",
     "what .ingest-status.json claims", "read outputs/.ingest-status.json")
emit("gauge_healthy", str(g.get("healthy", "?")).lower(), "measured", "pipeline",
     "self-reported health", "same")
emit("gauge_auth_skip_streak", g.get("auth_skip_streak", "?"), "measured", "pipeline",
     "consecutive authentication or route-check skips", "same")
emit("gauge_selfcheck_ok", str(g.get("gauge_selfcheck_ok", "?")).lower(), "measured", "pipeline",
     "status-accounting self-check result", "same")
if isinstance(gp, int):
    gps = g.get("pending_synthetic", 0)
    gps = gps if isinstance(gps, int) else 0
    err = BACKLOG - (gp + gps)
    emit("gauge_error_abs", abs(err), "measured", "pipeline",
         "how far the gauge is from the complement — target 0. Compares against "
         "gauge_pending + pending_synthetic; pending counts non-synthetic sessions",
         "|backlog_by_complement - (gauge_pending + gauge_pending_synthetic)|")
    if err:
        note(f"gauge disagrees with complement by {err}")

syn  = [r for r in rows if r["synthetic"] == "true"]
real = [r for r in rows if r["synthetic"] == "false"]
uncl = [r for r in rows if r["synthetic"] not in ("true", "false")]
SYN_N, REAL_N = len(syn), len(real)
emit("corpus_synthetic", SYN_N, "measured", "purity",
     "harness/ablation runs — the flag the ingester and recall actually branch on",
     "frontmatter synthetic: true")
emit("corpus_real", REAL_N, "measured", "purity",
     "genuine work sessions", "frontmatter synthetic: false")
emit("corpus_unclassified", len(uncl), "measured", "purity",
     "no synthetic: field at all — pre-Rx-3 residue, surfaced not swept",
     "frontmatter synthetic: absent or unparseable")
emit("corpus_purity_pct", pct(REAL_N, TOTAL), "measured", "purity",
     "real share of the search namespace", "corpus_real / corpus_total")
if uncl:
    names = sorted({r["project"] for r in uncl})
    note("UNFLAGGED SESSIONS: %d carry no synthetic: field — " % len(uncl) +
         "projects: " + " ".join(names[:15]) +
         (f" (+{len(names)-15} more)" if len(names) > 15 else ""))

emit("synthetic_flag_coverage_pct", pct(TOTAL - len(uncl), TOTAL), "measured", "purity",
     "share of the corpus carrying the synthetic-session classification flag at all — coverage, not accuracy",
     "count(frontmatter has synthetic:) / corpus_total")
for reason, n in sorted(collections.Counter(
        r["syn_reason"] for r in syn if r["syn_reason"]).items()):
    emit(f"syn_reason_{reason.replace(':','_').replace('-','_')}", n, "measured", "purity",
         f"synthetic sessions flagged by '{reason}' "
         f"({'DECLARED by the harness — the only measured tier' if reason == 'env' else 'INFERRED from ' + ('the launch path' if reason.startswith('cwd:') else 'a prompt signature')})",
         "frontmatter synthetic_reason:")

p_syn  = [r for r in rows if SYN_RE.match(r["project"])]
p_real = [r for r in rows if REAL_RE.match(r["project"])]
emit("corpus_synthetic_by_project", len(p_syn), "measured", "purity",
     "cross-check: harness runs per the project-name allowlist", "project matches SYN_RE")
emit("corpus_real_by_project", len(p_real), "measured", "purity",
     "cross-check: real sessions per the project-name allowlist", "project matches REAL_RE")
dis_hidden = sum(1 for r in rows if r["synthetic"] == "false" and SYN_RE.match(r["project"]))
dis_kept   = sum(1 for r in rows if r["synthetic"] == "true" and REAL_RE.match(r["project"]))
emit("classifier_disagreement", dis_hidden + dis_kept, "measured", "purity",
     "files the two independent classifiers rank differently — the honest error bar",
     "flag XOR project allowlist")
emit("classifier_disagreement_dangerous", dis_hidden, "measured", "purity",
     "flag says REAL, project allowlist says harness — the direction that could hide work",
     "synthetic:false AND SYN_RE matches")
if dis_hidden + dis_kept:
    note(f"CLASSIFIER DISAGREEMENT: {dis_hidden + dis_kept} file(s) "
         f"({dis_hidden} in the direction that could hide real work)")

for q in os.environ.get("BRAIN_RECALL_TEST_QUERIES", "notes,research,project").split(","):
    ql = q.lower()
    hits = [r for r in rows if ql in r["text"].lower()]
    returned = [r for r in hits if r["synthetic"] != "true"]
    bad = sum(1 for r in returned if SYN_RE.match(r["project"]))
    emit(f"recall_precision_{q}_pct", pct(len(returned) - bad, len(returned) or 1),
         "measured", "purity",
         f"of what recall RETURNS for '{q}' (n={len(returned)} of {len(hits)} raw hits), "
         "share the independent project classifier also calls real",
         "substring scan, drop synthetic:true, score by SYN_RE")

for st in ("promoted", "skipped", "draft", "captured"):
    emit(f"real_{st}", sum(1 for r in real if r["status"] == st), "measured", "yield",
         f"real sessions at status '{st}'", "REAL_RE x status")
RP = sum(1 for r in real if r["status"] == "promoted")
emit("real_promoted_pct", pct(RP, REAL_N or 1), "measured", "yield",
     "promoted share among sessions classified as substantive activity",
     "real_promoted / corpus_real")
syn_promoted = sum(1 for r in syn if r["status"] == "promoted")
emit("promoted_synthetic_leak", syn_promoted, "measured", "yield",
     "harness sessions that reached the wiki — the entrypoint gate's error rate",
     "SYN_RE x status==promoted")

tp_ok = tp_missing = tp_nopointer = tp_bad = 0
ep = collections.Counter()
for r in rows:
    m = re.search(r"Transcript:\s*`?([^\s`\n]+)", r["text"])
    if not m:
        tp_nopointer += 1
        continue
    path = os.path.expanduser(m.group(1))
    if not os.path.exists(path):
        tp_missing += 1
        continue
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            head = "".join(next(f, "") for _ in range(40))
        m2 = re.search(r'"entrypoint"\s*:\s*"([^"]*)"', head)
        ep[m2.group(1) if m2 else "«none»"] += 1
        tp_ok += 1
    except Exception:
        tp_bad += 1

emit("transcripts_resolvable", tp_ok, "measured", "yield",
     "summaries whose transcript still exists on disk and parses", "Provenance pointer + stat")
emit("transcripts_missing", tp_missing, "measured", "yield",
     "source availability: summaries pointing at a deleted transcript — unreopenable by construction",
     "pointer present, file absent")
emit("transcripts_no_pointer", tp_nopointer, "measured", "yield",
     "summaries with no Transcript: line at all", "regex over Provenance")
emit("transcripts_resolvable_pct", pct(tp_ok, TOTAL or 1), "measured", "yield",
     "share of the whole corpus that could still be reopened", "transcripts_resolvable / corpus_total")

EP_KNOWN = {"cli", "sdk-cli", "«none»"}
ep_unknown = []
for label, n in sorted(ep.items(), key=lambda kv: -kv[1]):
    safe = re.sub(r"[^a-zA-Z0-9_]", "_", label)
    emit(f"transcript_entrypoint_{safe}", n, "measured", "yield",
         f"resolvable transcripts recorded as entrypoint '{label}' "
         f"(denominator = transcripts_resolvable = {tp_ok}, NOT corpus_total)",
         "json first line of the transcript")
    if label not in EP_KNOWN:
        ep_unknown.append(f"{label}={n}")
emit("transcript_entrypoint_unknown_labels", ";".join(ep_unknown) or "none", "measured", "yield",
     "entrypoint values the capture accounting gate does not model — it fails open, so surface them", "same")
if ep_unknown:
    note("UNKNOWN ENTRYPOINT: " + ";".join(ep_unknown))

SECTIONS = ("Prompt Summary", "Key Outputs", "Ledger", "Files Changed",
            "Decisions Made", "Follow-up Tasks", "Open Questions")
for s in SECTIONS:
    filled = placeholder = absent = 0
    pat = re.compile(r"^## " + re.escape(s) + r"\s*\n+(.{0,40})", re.M)
    for r in rows:
        m = pat.search(r["text"])
        if not m:
            absent += 1
        elif m.group(1).startswith("_To be filled"):
            placeholder += 1
        else:
            filled += 1
    key = s.lower().replace(" ", "_").replace("-", "_")
    emit(f"section_{key}_filled_pct", pct(filled, TOTAL or 1), "measured", "capture",
         f"'## {s}' carrying real content (placeholder={placeholder}, absent={absent})",
         "per-section head scan")
    if filled == 0 and absent == 0:
        note(f"DEAD SECTION: '## {s}' is placeholder in all {TOTAL} files — never once filled")

ledger = sum(1 for r in rows if re.search(r"^## Ledger", r["text"], re.M))
emit("ledger_sections", ledger, "measured", "capture",
     "files carrying a tool ledger section",
     "regex ^## Ledger")
dm = sum(1 for r in rows if re.search(r"^## Decisions Made", r["text"], re.M))
emit("decisions_made_sections", dm, "measured", "capture",
     "files carrying a Decisions Made section",
     "regex ^## Decisions Made")
cs = sum(1 for r in rows if re.search(r"^### Compaction", r["text"], re.M))
emit("compaction_sections", cs, "measured", "capture",
     "files carrying ### Compaction", "regex ^### Compaction")

sclog = os.path.join(LOGS, "session-capture.log")
if os.path.exists(sclog):
    lg = read(sclog)
    pc   = len(re.findall(r"PostCompact: trigger=", lg))
    pcok = len(re.findall(r"PostCompact: session file updated successfully", lg))
    se   = len(re.findall(r"SessionEnd", lg))
    emit("hook_postcompact_fires", pc, "measured", "capture",
         "PostCompact events in the retained hook log", "grep -c 'PostCompact: trigger='")
    emit("hook_postcompact_ok", pcok, "measured", "capture",
         "…that reported a successful write", "grep -c 'updated successfully'")
    emit("hook_sessionend_events", se, "measured", "capture",
         "SessionEnd events, same window", "grep -c SessionEnd")
    emit("hook_compaction_rate_pct", pct(pc, se or 1), "measured", "capture",
         "compaction rate per the HOOK — the remedy verification question asked of the right log",
         "hook_postcompact_fires / hook_sessionend_events")
    if pcok > cs:
        note(f"LEAK: {pcok} successful PostCompact writes vs only {cs} "
             f"'### Compaction' sections corpus-wide (compaction tracking)")

wfiles = sorted(glob.glob(os.path.join(WS, "*.md")))
wtexts = {p: read(p) for p in wfiles}
WT = len(wfiles)
emit("wiki_summaries_total", WT, "measured", "layer2", "Layer 2 volume", "ls wiki/summaries")
for key, pat in (("compiled_false", r"^compiled: false"),
                 ("links_empty",    r"^links: \[\]"),
                 ("reviewed_false", r"^reviewed: false"),
                 ("status_draft",   r"^status: draft")):
    n = sum(1 for t in wtexts.values() if re.search(pat, t, re.M))
    emit(f"wiki_{key}", n, "measured", "layer2", f"Layer 2 pages matching '{pat}'", "regex")
    emit(f"wiki_{key}_pct", pct(n, WT or 1), "measured", "layer2", "as a share of Layer 2", "same")

linked = [p for p, t in wtexts.items()
          if re.search(r"^compiled: true", t, re.M) and not re.search(r"^links: \[\]", t, re.M)]
emit("wiki_compiled_and_linked", len(linked), "measured", "layer2",
     "pages that are BOTH compiled and reachable", "compiled:true AND links non-empty")

allwiki = {}
for p in glob.glob(os.path.join(V, "wiki/**/*.md"), recursive=True):
    if "/wiki/indexes/" in p:
        continue
    allwiki[p] = read(p)
idx_only = 0
for p in wfiles:
    b = os.path.basename(p)[:-3]
    if not any(b in t for q, t in allwiki.items() if q != p):
        idx_only += 1
emit("wiki_index_only_reachable", idx_only, "measured", "layer2",
     "inbound-link coverage: Layer-2 pages with no inbound reference outside wiki/indexes/",
     "inbound basename scan, indexes excluded")

know_total, empty_folders = 0, []
for folder in ("concepts", "entities", "decisions", "projects", "values",
               "goals", "areas", "reviews", "vault-registry"):
    n = len(glob.glob(os.path.join(KNOW, folder, "*.md")))
    know_total += n
    if n == 0:
        empty_folders.append(folder)
    emit(f"knowledge_{folder.replace('-', '_')}", n, "measured", "layer2",
         f"semantic pages in wiki/knowledge/{folder}/", "ls")
emit("knowledge_total", know_total, "measured", "layer2",
     "the entire semantic layer the 6-tier cascade is built to feed", "sum of folders")
emit("knowledge_empty_folders", len(empty_folders), "measured", "layer2",
     "knowledge folders with zero pages — includes the constitutional values/ tier",
     "count of folders with 0 *.md")
if empty_folders:
    note("EMPTY KNOWLEDGE FOLDERS: " + " ".join(empty_folders))

emit("semantic_yield_pct", pct(len(linked), REAL_N or 1), "measured", "headline",
     "compiled+linked Layer-2 pages per real work session — the one number",
     "wiki_compiled_and_linked / corpus_real")

if os.path.isdir(DECKS):
    dirs = [d for d in glob.glob(os.path.join(DECKS, "*")) if os.path.isdir(d)]
    pages = [f for f in glob.glob(os.path.join(DECKS, "*", "turn-*.md"))
             if not f.endswith(".progress.md")]
    ge2 = tested = found = 0
    wikiblob = "\n".join(allwiki.values())
    for d in dirs:
        turns = sorted(f for f in glob.glob(os.path.join(d, "turn-*.md"))
                       if not f.endswith(".progress.md"))
        if len(turns) >= 2:
            ge2 += 1
        if not turns:
            continue
        m = re.search(r"[A-Za-z][A-Za-z ]{40,60}", read(turns[0]))
        if not m:
            continue
        tested += 1
        if m.group(0).strip() in wikiblob:
            found += 1
    emit("decks_total", len(dirs), "measured", "decks", "html-mode decks on disk", "ls -d")
    emit("deck_pages", len(pages), "measured", "decks", "authored turn-*.md pages", "glob")
    emit("decks_ge2_turns", ge2, "measured", "decks", "decks with >=2 authored turns", "per-deck count")
    emit("decks_content_in_wiki", found, "measured", "decks",
         f"decks whose CONTENT reached the wiki (authored-source coverage) (n tested={tested})",
         "distinctive-phrase scan over wiki/")
    emit("deck_ingestion_rate_pct", pct(found, tested or 1), "estimated", "decks",
         "phrase-probe heuristic: one 40-60 char phrase per deck, first turn only", "same")

tpls = glob.glob(os.path.join(TPL, "*.md"))
ttexts = {p: read(p) for p in tpls}
emit("templates_total", len(tpls), "measured", "schema", "page templates", "ls .claude/templates")
emit("templates_last_verified",
     sum(1 for t in ttexts.values() if re.search(r"last_verified|verified_at|checked_at", t)),
     "measured", "schema",
     "verification freshness: templates that can say when a page was CHECKED (verification freshness). "
     "See wiki_verified_coverage_pct for page-level coverage", "regex")
emit("templates_verified_by",
     sum(1 for t in ttexts.values() if re.search(r"^verified_by:", t, re.M)),
     "measured", "schema", "verification freshness: templates naming the check that ran", "regex ^verified_by:")
emit("templates_verified_field",
     sum(1 for t in ttexts.values() if re.search(r"^verified:", t, re.M)),
     "measured", "schema", "remedy verification: templates with a remedy-verification field (claim verification)",
     "regex ^verified:")
emit("templates_confidence_marks",
     sum(1 for t in ttexts.values() if "✅" in t and "⚠️" in t),
     "measured", "schema",
     "claim verification: templates carrying the measured/estimated marker convention", "both glyphs present")

wpages = glob.glob(os.path.join(V, "wiki/**/*.md"), recursive=True)
wv = sum(1 for p in wpages if re.search(r"^last_verified:", read(p, 4000), re.M))
emit("wiki_pages_total", len(wpages), "measured", "schema", "all wiki pages", "find wiki -name '*.md'")
emit("wiki_last_verified_pct", pct(wv, len(wpages) or 1), "measured", "schema",
     "pages carrying last_verified", "regex ^last_verified: in frontmatter window")

ISO_RE = re.compile(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$')

def yscalar(s):
    """Read a YAML scalar while preserving hash characters inside quotes."""
    s = s.strip()
    if s[:1] in ("'", '"'):
        q, i, out = s[0], 1, []
        while i < len(s):
            if s[i] == q:
                if q == "'" and s[i + 1:i + 2] == "'":   # '' is a literal quote
                    out.append("'"); i += 2; continue
                break
            out.append(s[i]); i += 1
        return "".join(out)
    return s.split("#")[0].strip()
earned = typed = unparse = nulls = 0
ext_pages, ext_earned, longfence = 0, 0, 0
for p in wpages:
    try:
        txt = open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    if not txt.startswith("---"):
        continue
    e = txt.find("\n---", 3)
    if e == -1:
        continue
    if e > 8000:
        longfence += 1
    fence, pbody = txt[3:e], txt[e:]
    fc = re.search(r'^freshness_class:[ \t]*(\S+)', fence, re.M)
    external = bool(fc and fc.group(1) in ("volatile", "fast-changing")) \
               and "/workbench/" in p
    lv = re.search(r'^last_verified:[ \t]*(.*)$', fence, re.M)
    vb = re.search(r'^verified_by:[ \t]*(.*)$', fence, re.M)
    if external:
        ext_pages += 1
    if not lv:
        continue
    raw = yscalar(lv.group(1))
    vbv = yscalar(vb.group(1)) if vb else ""
    if raw in ("", "null", "~"):
        nulls += 1
    elif not ISO_RE.match(raw):
        unparse += 1
    elif vbv and vbv not in ("null", "~") and f"- **Command**: `{vbv}`" in pbody:
        earned += 1
        if external:
            ext_earned += 1
    else:
        typed += 1

emit("wiki_last_verified_earned", earned, "measured", "schema",
     "verification freshness: stamps written BY verify-page.sh — the only writer of verified_by",
     "fence-scoped: ISO last_verified AND a non-null verified_by")
emit("wiki_last_verified_typed", typed, "measured", "schema",
     "pre-Rx-4 legacy: a date with no named check beside it — unrepeatable",
     "fence-scoped: ISO last_verified, verified_by absent/null")
emit("wiki_last_verified_unparseable", unparse, "measured", "schema",
     "verification freshness recurring: the date field drifted into prose. TARGET 0",
     "fence-scoped: last_verified set but not ISO8601")
emit("wiki_last_verified_null", nulls, "measured", "schema",
     "honestly never checked — this is the GOOD default, not a gap", "fence-scoped")
emit("wiki_external_fact_pages", ext_pages, "measured", "schema",
     "verification freshness's real denominator: volatile/fast-changing workbench pages, the only "
     "ones asserting a fact the outside world can contradict",
     "fence-scoped freshness_class in {volatile,fast-changing} AND path under wiki/workbench/")
emit("wiki_pages_long_fence", longfence, "measured", "schema",
     "pages whose frontmatter exceeds 8 KB — surfaced because a truncating reader "
     "miscounts them silently; this block reads whole files", "fence end offset > 8000")
emit("wiki_verified_coverage_pct", pct(ext_earned, ext_pages or 1), "measured", "schema",
     "SUBSTITUTE GATE for the voided templates_last_verified==16: share of "
     "external-fact pages whose stamp was earned by a check that ran",
     "wiki_last_verified_earned restricted to wiki_external_fact_pages")

cm = read(CM)
cmlines = cm.split("\n")
emit("claudemd_lines", len(cmlines), "measured", "tier0", "hot-cache length", "wc -l CLAUDE.md")
emit("claudemd_words", len(cm.split()), "measured", "tier0", "hot-cache words", "wc -w CLAUDE.md")
KEYWORD_COLS = {"tech surface"}
longest = longest_prose = over200 = prose_over200 = keyword_over200 = tablewords = 0
header = []
prev_was_row = False
for line in cmlines:
    if not line.startswith("|"):
        header, prev_was_row = [], False
        continue
    cells = [c.strip() for c in line.replace(r"\|", "§").split("|")[1:]]
    is_sep = bool(cells) and all(set(c) <= set("-: ") and c for c in cells[:-1] or [""])
    if not prev_was_row and not is_sep:
        header = [c.lower() for c in cells]        # first row of a fresh table
    prev_was_row = True
    if is_sep:
        continue
    for i, c in enumerate(cells):
        col = header[i] if i < len(header) else ""
        tablewords += len(c.split())
        longest = max(longest, len(c))
        if col not in KEYWORD_COLS:
            longest_prose = max(longest_prose, len(c))
        if len(c) > 200:
            over200 += 1
            if col in KEYWORD_COLS:
                keyword_over200 += 1
            else:
                prose_over200 += 1
emit("claudemd_longest_cell", longest, "measured", "tier0",
     "table readability: the real density problem, not line count", "escape-aware cell scan")
emit("claudemd_longest_prose_cell", longest_prose, "measured", "tier0",
     "longest cell OUTSIDE the keyword columns — the one a human has to read",
     "escape-aware cell scan, column excluded: Tech Surface")
emit("claudemd_cells_over_200", over200, "measured", "tier0",
     "every oversized cell, keyword lists included — descriptive, NOT the gate", "same")
emit("claudemd_prose_cells_over_200", prose_over200, "measured", "tier0",
     "table readability's GATE (target 0): oversized cells in columns a human reads. Excludes "
     "Tech Surface, whose long keyword lists are the matching mechanism working",
     "escape-aware, column-aware cell scan")
emit("claudemd_keyword_cells_over_200", keyword_over200, "measured", "tier0",
     "what the gate excluded, stated out loud so the exclusion cannot hide (reported scope)",
     "cells >200 chars in Tech Surface columns")
emit("claudemd_table_word_share_pct", pct(tablewords, len(cm.split()) or 1), "measured", "tier0",
     "share of the hot cache spent on the workbench table", "table words / total words")

import glob as _glob, re as _re2
def _norm2(s):
    return _re2.sub(r"\s+", " ", s).strip()
_cands = set()
for _ln in cmlines:
    if _ln.startswith("|") or _ln.lstrip().startswith("#"):
        continue
    for _sent in _re2.split(r"(?<=[.!?])\s+", _ln.strip()):
        _n = _norm2(_sent)
        if len(_n) >= 100:
            _cands.add(_n)
_paths = _glob.glob(os.path.join(V, "wiki/**/*.md"), recursive=True)
_paths += _glob.glob(os.path.expanduser(
    "~/.claude/projects/*brains-master*/memory/*.md"))
_corpus = []
for _p in _paths:
    try:
        _corpus.append(_norm2(open(_p, encoding="utf-8").read()))
    except Exception:
        pass
_corpus_txt = " \n ".join(_corpus)
_dups = sorted(p for p in _cands if p in _corpus_txt)
emit("claudemd_dup_passages", len(_dups), "measured", "tier0",
     "starting-context size GATE (target 0): hot-cache prose sentences (>=100 chars) that appear "
     "verbatim in a wiki/ or memory/ file — content above the tier where it belongs",
     "normalized-whitespace substring scan of CLAUDE.md sentences vs wiki+memory")
_dup_ex = (_dups[0][:70] + "...") if _dups else "none"
emit("claudemd_dup_passages_example", _dup_ex, "measured", "tier0",
     "first duplicated passage, named not dropped (reported scope) so the count is actionable", "same scan")
_SECT_EXEMPT = {"## Active Workbench"}
_secs = []
_cur = None
_buf = 0
for _ln in cmlines:
    if _ln.startswith("## "):
        if _cur is not None:
            _secs.append((_cur, _buf))
        _cur = _ln.strip()
        _buf = 0
    else:
        _buf += len(_ln) + 1
if _cur is not None:
    _secs.append((_cur, _buf))
_over = [(n, b) for (n, b) in _secs if b > 3000 and n not in _SECT_EXEMPT]
emit("claudemd_sections_over_3kb", len(_over), "measured", "tier0",
     "container detector: non-index ## sections >3KB — the inlined-block failure "
     "mode (Operating Rules was 10.8KB). Surfaces for review; workbench exempt (it is an index)",
     "per-section byte scan of CLAUDE.md, Active Workbench excluded by name")
_over_names = ", ".join(f"{n.lstrip('# ')} ({b//1000}KB)" for n, b in sorted(_over, key=lambda x:-x[1])) or "none"
emit("claudemd_sections_over_3kb_names", _over_names, "measured", "tier0",
     "which sections tripped the container detector, named not dropped (reported scope)", "same scan")

try:
    mcp = len(json.load(open(os.path.expanduser("~/.claude.json"))).get("mcpServers", {}))
except Exception:
    mcp = "?"
emit("mcp_servers_user_scoped", mcp, "measured", "tier0",
     "MCP servers declared in ~/.claude.json ONLY — plugin-provided servers are NOT counted, "
     "so this is not the session's total tool surface",
     "jq '.mcpServers | length' ~/.claude.json")

if os.path.exists(PROBE):
    pr = [json.loads(l) for l in open(PROBE) if l.strip()]
    if pr:
        last = pr[-1]
        emit("probe_runs", len(pr), "measured", "cost",
             "standup probe data points", "wc -l probe-trend.jsonl")
        emit("brain_tax_last", last.get("cache_creation_tokens", 0), "measured", "cost",
             "cache_creation on the latest probe run", "tail -1 probe-trend.jsonl")
        emit("brain_tax_date", last.get("date", "?"), "measured", "cost",
             "date of that run", "same")
        n = min(3, len(pr))
        emit("brain_tax_avg3", round(sum(r.get("cache_creation_tokens", 0) for r in pr[-n:]) / n),
             "estimated", "cost", f"mean over the last {n} runs (small n)", "mean of tail -3")

wlog = os.path.join(V, "outputs/.writes.jsonl")
if os.path.exists(wlog):
    emit("writes_log_entries", sum(1 for _ in open(wlog)), "measured", "crosssession",
         "vault writes logged (write tracking)", "wc -l outputs/.writes.jsonl")
else:
    emit("writes_log_entries", 0, "measured", "crosssession",
         "write tracking not implemented — file absent", "ls outputs/.writes.jsonl")

tsv.close(); note_f.close()
PY

mkdir -p "$SNAPDIR"
if [ -n "$TAG" ]; then OUT="$SNAPDIR/vitals-${TAG}.json"; else OUT="$SNAPDIR/vitals-${STAMP}.json"; fi

TSV="$TSV" NOTE="$NOTE" OUT="$OUT" STAMP="$STAMP" MODE="$MODE" \
ONE="$ONE_METRIC" SNAP="$SNAPSHOT" python3 - <<'PY'
import json, os, sys

rows, seen = [], set()
for line in open(os.environ["TSV"]):
    p = line.rstrip("\n").split("\t")
    if len(p) < 6:
        continue
    k, v, prov, sec, mean, cmd = p[:6]
    if k in seen:
        continue
    seen.add(k)
    try:
        v = int(v)
    except ValueError:
        try:
            v = float(v)
        except ValueError:
            pass
    rows.append(dict(key=k, value=v, provenance=prov, section=sec, meaning=mean, command=cmd))

notes = [n.rstrip("\n") for n in open(os.environ["NOTE"]) if n.strip()]
verdict, reason = "OK", ""
for n in notes:
    if n.startswith(("UNKNOWN STATUS", "UNKNOWN ENTRYPOINT", "UNCLASSIFIED", "AMBIGUOUS")):
        verdict, reason = "DEGRADED", n
        break
if verdict == "OK" and notes:
    verdict, reason = "ATTENTION", notes[0]

doc = dict(taken_at=os.environ["STAMP"], verdict=verdict, verdict_reason=reason,
           notes=notes, metrics=rows)

if os.environ["MODE"] == "metric":
    for r in rows:
        if r["key"] == os.environ["ONE"]:
            print(r["value"]); sys.exit(0)
    print(f"no such metric: {os.environ['ONE']}", file=sys.stderr)
    print("available: " + ", ".join(sorted(r["key"] for r in rows)), file=sys.stderr)
    sys.exit(1)

if os.environ["SNAP"] == "1":
    with open(os.environ["OUT"], "w") as f:
        json.dump(doc, f, indent=2)

if os.environ["MODE"] in ("json", "both"):
    print(json.dumps(doc, indent=2))

if os.environ["MODE"] in ("markdown", "both"):
    print(f"\n| Metric | {os.environ['STAMP'][:10]} | | Meaning |")
    print("|---|---:|:-:|---|")
    order = ["headline", "pipeline", "purity", "yield", "capture", "layer2",
             "decks", "schema", "tier0", "cost", "crosssession"]
    last = None
    for sec in order:
        for r in [x for x in rows if x["section"] == sec]:
            if sec != last:
                print(f"| **— {sec} —** | | | |")
                last = sec
            tick = "✅" if r["provenance"] == "measured" else "⚠️"
            print(f"| `{r['key']}` | {r['value']} | {tick} | {r['meaning']} |")
    print(f"\n> verdict: **{verdict}**" + (f" — {reason}" if reason else ""))
    for n in notes:
        print(f"> - {n}")
    if os.environ["SNAP"] == "1":
        print(f"\n_Snapshot: `{os.environ['OUT']}`_")
PY
