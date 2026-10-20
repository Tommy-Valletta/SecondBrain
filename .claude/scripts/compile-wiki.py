#!/usr/bin/env python3


















import argparse
import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

VAULT_DIR = Path(os.environ.get(
    "VAULT_PATH",
    str(Path(__file__).resolve().parent.parent.parent),
))
sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from frontmatter import set_field, split_fence                                     

                                                                                     
                                                                                      
                                                                                     
                                             
MAX_COMPILE_ATTEMPTS = 3
LOG_FILE = VAULT_DIR / "wiki" / "logs" / "compile.log"
TIMESTAMP = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg: str):
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(LOG_FILE, "a") as f:
        f.write(f"[{TIMESTAMP}] {msg}\n")
    print(f"  {msg}")


def parse_frontmatter(filepath: Path) -> dict:








    fm_lines, _, ok = split_fence(filepath.read_text())
    if not ok:
        return {}
    fm_text = "\n".join(fm_lines).strip()
    result = {}
    current_key = None
    current_list = None
    for line in fm_text.split("\n"):
        if line.startswith("  - "):
            if current_list is not None:
                current_list.append(line.strip()[2:])
            continue
        if ":" in line:
            if current_key and current_list is not None:
                result[current_key] = current_list
            key, _, val = line.partition(":")
            key = key.strip()
            val = val.strip()
            if val == "" or val == "[]":
                current_key = key
                current_list = []
            else:
                current_key = None
                current_list = None
                result[key] = val
        elif current_list is None:
            current_key = None
    if current_key and current_list is not None:
        result[current_key] = current_list
    return result


def extract_title(filepath: Path) -> str:

    try:
        with open(filepath) as f:
            in_fm = False
            for line in f:
                s = line.strip()
                if s == "---":
                    in_fm = not in_fm
                    continue
                if in_fm:
                    continue
                if s.startswith("# "):
                    return s[2:]
        return filepath.stem
    except Exception:
        return filepath.stem


def extract_wiki_links(filepath: Path) -> set:

    text = filepath.read_text()
    if text.startswith("---"):
        end = text.find("---", 3)
        if end > 0:
            text = text[end + 3:]
                                                                 
    return set(re.findall(r"\[\[(wiki/[^\]|]+?)(?:\|[^\]]+?)?\]\]", text))


def extract_frontmatter_links(filepath: Path) -> set:

    fm = parse_frontmatter(filepath)
    links = fm.get("links", [])
    if isinstance(links, list):
        return set(links)
    return set()


                                                                                

def do_backlinks(dry_run: bool):

    print("\n=== Backlinks ===")

    sources_dir = VAULT_DIR / "wiki" / "summaries"
    if not sources_dir.exists():
        print("  No summaries directory found")
        return

                                                                          
    backlinks: dict[str, list[tuple[str, str]]] = defaultdict(list)

    for src_file in sorted(sources_dir.glob("*.md")):
                                                           
        body_links = extract_wiki_links(src_file)
        fm_links = extract_frontmatter_links(src_file)
        all_links = body_links | fm_links

        src_rel = f"wiki/summaries/{src_file.name}"
        src_title = extract_title(src_file)

        for link in all_links:
                                              
            link_clean = link.replace(".md", "")
            backlinks[link_clean].append((src_rel, src_title))

    print(f"  Found {len(backlinks)} backlink targets across {len(list(sources_dir.glob('*.md')))} sources")

                                                                       
    updated = 0
    for target_dir in ["wiki/knowledge/concepts", "wiki/knowledge/entities"]:
        full_dir = VAULT_DIR / target_dir
        if not full_dir.exists():
            continue
        for page_file in sorted(full_dir.glob("*.md")):
            page_rel = f"{target_dir}/{page_file.name}".replace(".md", "")
            sources = backlinks.get(page_rel, [])
            if not sources:
                continue

                                 
            sorted_sources = sorted(set(sources), key=lambda x: x[0])
            links_md = "\n".join(
                f"- [[{src_path.replace('.md', '')}|{title}]]"
                for src_path, title in sorted_sources
            )

            if dry_run:
                print(f"  [dry-run] Would update {page_rel}: {len(sorted_sources)} sources")
                continue

                                                
            content = page_file.read_text()
            changed = False

            for section_name in ["Mentioned In", "Sources"]:
                pattern = rf"(## {re.escape(section_name)}\n)(.*?)(\n## |\Z)"
                match = re.search(pattern, content, re.DOTALL)
                if match:
                    new_section = match.group(1) + links_md + "\n" + match.group(3)
                    content = content[:match.start()] + new_section + content[match.end():]
                    changed = True

            if changed:
                page_file.write_text(content)
                updated += 1
                log(f"BACKLINKS: {page_rel} ({len(sorted_sources)} sources)")

    print(f"  Updated {updated} pages")


                                                                               

def do_indexes(dry_run: bool):

    print("\n=== Indexes ===")

    _regen_concept_index(dry_run)
    _regen_entity_index(dry_run)
    _regen_source_index(dry_run)


def _regen_concept_index(dry_run: bool):
    concepts_dir = VAULT_DIR / "wiki" / "knowledge" / "concepts"
    if not concepts_dir.exists():
        return

                                            
    topic_map = {
        "Architecture": ["architecture"],
        "Automation & Pipelines": ["automation", "pipeline"],
        "Memory & Maintenance": ["memory", "maintenance", "freshness"],
        "Quality & Evaluation": ["quality", "evaluation"],
        "Retrieval": ["retrieval"],
        "Governance": ["governance"],
    }

    entries = []
    for f in sorted(concepts_dir.glob("*.md")):
        fm = parse_frontmatter(f)
        title = extract_title(f)
        tags = fm.get("tags", [])
        slug = f.stem
        entries.append((slug, title, tags))

                           
    lines = [
        "---",
        "id: index-concepts",
        "type: index",
        "status: active",
        f"updated_at: {TIMESTAMP}",
        "tags:",
        "  - index",
        "---",
        "",
        "# Concepts",
        "",
        f"{len(entries)} concept pages in the vault.",
        "",
    ]

    categorized = set()
    for topic, keywords in topic_map.items():
        matches = [
            (slug, title) for slug, title, tags in entries
            if any(kw in tags for kw in keywords)
        ]
        if matches:
            lines.append(f"## {topic}")
            for slug, title in sorted(matches, key=lambda x: x[1]):
                lines.append(f"- [[wiki/knowledge/concepts/{slug}|{title}]]")
                categorized.add(slug)
            lines.append("")

                   
    uncategorized = [(s, t) for s, t, _ in entries if s not in categorized]
    if uncategorized:
        lines.append("## Other")
        for slug, title in sorted(uncategorized, key=lambda x: x[1]):
            lines.append(f"- [[wiki/knowledge/concepts/{slug}|{title}]]")
        lines.append("")

    content = "\n".join(lines)
    idx_file = VAULT_DIR / "wiki" / "indexes" / "concepts.md"

    if dry_run:
        print(f"  [dry-run] Would regenerate concepts index ({len(entries)} entries)")
        return

    idx_file.write_text(content)
    log(f"INDEX: concepts ({len(entries)} entries)")
    print(f"  Regenerated concepts index ({len(entries)} entries)")


def _regen_entity_index(dry_run: bool):
    entities_dir = VAULT_DIR / "wiki" / "knowledge" / "entities"
    if not entities_dir.exists():
        return

    type_groups: dict[str, list[tuple[str, str]]] = defaultdict(list)
    for f in sorted(entities_dir.glob("*.md")):
        fm = parse_frontmatter(f)
        title = extract_title(f)
        entity_type = fm.get("entity_type", "other")
        type_groups[entity_type].append((f.stem, title))

    total = sum(len(v) for v in type_groups.values())

    lines = [
        "---",
        "id: index-entities",
        "type: index",
        "status: active",
        f"updated_at: {TIMESTAMP}",
        "tags:",
        "  - index",
        "---",
        "",
        "# Entities",
        "",
        f"{total} entity pages in the vault.",
        "",
    ]

    type_labels = {"tool": "Tools & Systems", "person": "People", "organization": "Organizations"}
    for etype in ["tool", "person", "organization", "other"]:
        items = type_groups.get(etype, [])
        if not items:
            continue
        label = type_labels.get(etype, etype.title())
        lines.append(f"## {label}")
        for slug, title in sorted(items, key=lambda x: x[1]):
            lines.append(f"- [[wiki/knowledge/entities/{slug}|{title}]]")
        lines.append("")

    content = "\n".join(lines)
    idx_file = VAULT_DIR / "wiki" / "indexes" / "entities.md"

    if dry_run:
        print(f"  [dry-run] Would regenerate entities index ({total} entries)")
        return

    idx_file.write_text(content)
    log(f"INDEX: entities ({total} entries)")
    print(f"  Regenerated entities index ({total} entries)")


def _regen_source_index(dry_run: bool):
    summaries_dir = VAULT_DIR / "wiki" / "summaries"
    if not summaries_dir.exists():
        return

    type_groups: dict[str, list[tuple[str, str, str]]] = defaultdict(list)
    for f in sorted(summaries_dir.glob("*.md")):
        fm = parse_frontmatter(f)
        title = extract_title(f)
        source_type = fm.get("source_type", "other")
        created = fm.get("created_at", "")
        type_groups[source_type].append((f.stem, title, created))

    total = sum(len(v) for v in type_groups.values())

    lines = [
        "---",
        "id: index-sources",
        "type: index",
        "status: active",
        f"updated_at: {TIMESTAMP}",
        "tags:",
        "  - index",
        "---",
        "",
        "# Sources",
        "",
        f"{total} source summaries in the vault.",
        "",
    ]

    type_labels = {
        "claude_code_session": "Claude Code Sessions",
        "web_clipping": "Web Clippings",
        "markdown_document": "Markdown Documents",
        "research_paper": "Research Papers",
        "specification": "Specifications",
        "research_synthesis": "Research Syntheses",
    }

    for stype, items in sorted(type_groups.items(), key=lambda x: x[0]):
        label = type_labels.get(stype, stype.replace("_", " ").title())
        lines.append(f"## {label}")
        for slug, title, _ in sorted(items, key=lambda x: x[1]):
            lines.append(f"- [[wiki/summaries/{slug}|{title}]]")
        lines.append("")

    content = "\n".join(lines)
    idx_file = VAULT_DIR / "wiki" / "indexes" / "summaries.md"

    if dry_run:
        print(f"  [dry-run] Would regenerate summaries index ({total} entries)")
        return

    idx_file.write_text(content)
    log(f"INDEX: summaries ({total} entries)")
    print(f"  Regenerated summaries index ({total} entries)")


                                                                               

def do_promote(dry_run: bool, limit: int = 0, retry_failed: bool = False):

    print("\n=== Promote ===")

    summaries_dir = VAULT_DIR / "wiki" / "summaries"
    if not summaries_dir.exists():
        print("  No summaries directory found")
        return

                                                                                     
                                                                                        
    uncompiled, quarantined, unreadable = [], [], []
    for f in sorted(summaries_dir.glob("*.md")):
        if not split_fence(f.read_text())[2]:
            unreadable.append(f)                                                           
            continue
        fm = parse_frontmatter(f)
        if fm.get("compiled") in ("true", True):
            continue
        try:
            attempts = int(str(fm.get("compile_attempts", 0)))
        except (TypeError, ValueError):
            attempts = 0
        if fm.get("compiled") == "failed" and attempts >= MAX_COMPILE_ATTEMPTS\
                and not retry_failed:
            quarantined.append(f)
            continue
        uncompiled.append(f)

    if quarantined:
        print(f"  ⚠️  {len(quarantined)} quarantined after {MAX_COMPILE_ATTEMPTS} failed "
              f"attempts — rerun with --retry-failed to force:")
        for f in quarantined[:10]:
            err = str(parse_frontmatter(f).get("compile_error", "?"))
            if len(err) > 1 and err[0] == err[-1] == "'":
                err = err[1:-1].replace("''", "'")                                      
            print(f"        {f.name}: {err}")
        if len(quarantined) > 10:
            print(f"        … and {len(quarantined) - 10} more")
    if unreadable:
        print(f"  ⚠️  {len(unreadable)} sources have no usable frontmatter fence, skipped:")
        for f in unreadable[:10]:
            print(f"        {f.name}")

    if limit and len(uncompiled) > limit:
        print(f"  --limit {limit}: processing {limit} of {len(uncompiled)} eligible "
              f"sources (the other {len(uncompiled) - limit} remain uncompiled)")
        uncompiled = uncompiled[:limit]

    if not uncompiled:
        print("  No eligible sources to compile")
        return

    print(f"  {len(uncompiled)} sources to process")
    n_created_pages = n_ok = n_failed = 0

                                                                 
    existing_pages = []
    for subdir in ["knowledge/concepts", "knowledge/entities"]:
        d = VAULT_DIR / "wiki" / subdir
        if not d.exists():
            continue
        for f in sorted(d.glob("*.md")):
            fm = parse_frontmatter(f)
            title = extract_title(f)
            aliases = fm.get("aliases", [])
            page_id = fm.get("id", f.stem)
            entry = f"- {page_id}: {title}"
            if aliases:
                entry += f" (aliases: {', '.join(aliases)})"
            existing_pages.append(entry)

    for src_file in uncompiled:
                                                                                          
                                                                                          
                                                                                       
                                                                                      
                                                                                      
                                                                                        
                                                                                         
                                                                            
                                                                                         
                                                              
        existing_list = "\n".join(existing_pages)
        src_content = src_file.read_text()
        src_title = extract_title(src_file)
        print(f"\n  Processing: {src_title}")

        if dry_run:
            print(f"    [dry-run] Would call claude -p for promotion check")
            continue

        prompt = f"""You are a wiki page promoter. Read this source summary and decide if any NEW concept or entity pages should be created.

## Existing Pages (do NOT create duplicates)
{existing_list}

## Source to Analyze
{src_content}

## Rules
1. Only propose pages that DON'T already exist in the list above.
2. Apply the promotion threshold: concepts need definition + relevance; entities need substantive discussion in 2+ sources.
3. Output a JSON array of create operations. If nothing to create, output `[]`.
4. Each operation: {{"action": "create", "path": "wiki/knowledge/concepts/slug.md" or "wiki/knowledge/entities/slug.md", "content": "full file content"}}
5. Use timestamp {TIMESTAMP} for created_at/updated_at.
6. Frontmatter MUST include `id:` and it MUST equal the filename stem exactly — for
   `wiki/knowledge/concepts/foo-bar.md`, `id: foo-bar`. No `concept-` prefix, no other
   decoration. The dedup list above is keyed on `id`, so an id that does not match its
   own filename advertises a page name that no file has, and the next run cannot tell
   whether it exists.
7. Frontmatter MUST include a `links:` list and a `sources:` list naming this source.
   A page with `links: []` does not count as compiled-and-linked by the health harness,
   so an unlinked page is invisible work.
8. First character must be `[`, last must be `]`. No commentary.
"""

        try:
            result = subprocess.run(
                ["claude", "-p", "--no-session-persistence",
                 "--dangerously-skip-permissions"],
                input=prompt,
                capture_output=True,
                text=True,
                timeout=300,
            )
            output = result.stdout.strip()
                                                                                      
                                                                                         
                                                                                      
                                                                                          
            if result.returncode != 0:
                n_failed += 1
                err = (result.stderr or "").strip()[:200] or "no stderr"
                print(f"    claude -p exited {result.returncode} — recorded as failed")
                _mark_failed(src_file, f"claude -p rc={result.returncode}: {err}")
                continue
        except subprocess.TimeoutExpired:
            n_failed += 1
            print(f"    TIMEOUT after 300s — recorded as failed")
            _mark_failed(src_file, "timeout after 300s")
            continue
        except Exception as e:
            n_failed += 1
            print(f"    ERROR: {e} — recorded as failed")
            _mark_failed(src_file, f"{type(e).__name__}: {e}")
            continue

                      
        output = re.sub(r"```json\s*\n?", "", output)
        output = re.sub(r"```\s*\n?", "", output)
        start = output.find("[")
        end = output.rfind("]")
        if start == -1 or end == -1:
            n_failed += 1
            print(f"    No JSON found in output — recorded as failed")
            _mark_failed(src_file, f"no JSON array in output ({len(output)} B): "
                                   f"{output[:120]}")
            continue

        try:
            operations = json.loads(output[start:end + 1])
        except json.JSONDecodeError as e:
            n_failed += 1
            print(f"    Invalid JSON — recorded as failed")
            _mark_failed(src_file, f"JSONDecodeError: {e}")
            continue

                                 
        created = 0
        for op in operations:
            if op.get("action") != "create":
                continue
            path = VAULT_DIR / op["path"]
            if path.exists():
                print(f"    SKIP (exists): {op['path']}")
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(op["content"])
            print(f"    CREATE: {op['path']}")
            log(f"PROMOTE: created {op['path']} from {src_file.name}")
            created += 1
                                                                                      
            new_fm = parse_frontmatter(path)
            entry = f"- {new_fm.get('id', path.stem)}: {extract_title(path)}"
            if new_fm.get("aliases"):
                entry += f" (aliases: {', '.join(new_fm['aliases'])})"
            existing_pages.append(entry)

        print(f"    {created} pages created, {len(operations) - created} skipped")
        n_ok += 1
        n_created_pages += created
        _mark_compiled(src_file)

                                                                                         
                                                                                        
                                                                                 
    print(f"\n  --- promote summary ---")
    print(f"  succeeded : {n_ok}  ({n_created_pages} pages created)")
    print(f"  failed    : {n_failed}" + ("  🔴 see compile_error: in their frontmatter"
                                         if n_failed else ""))
    if quarantined:
        print(f"  quarantined: {len(quarantined)} (>= {MAX_COMPILE_ATTEMPTS} attempts)")
    log(f"PROMOTE: summary ok={n_ok} failed={n_failed} pages={n_created_pages} "
        f"quarantined={len(quarantined)}")


def _mark_compiled(filepath: Path):







    content = filepath.read_text()
    new, changed = set_field(content, "compiled", "true")
    if not changed and new == content:
                                                                                 
        log(f"WARN: could not mark compiled (no usable frontmatter fence): {filepath}")
        return
    filepath.write_text(new)


def _yaml_quote(s) -> str:


    return "'" + " ".join(str(s).split())[:300].replace("'", "''") + "'"


def _mark_failed(filepath: Path, reason: str):













    content = filepath.read_text()
    try:
        attempts = int(str(parse_frontmatter(filepath).get("compile_attempts", 0)))
    except (TypeError, ValueError):
        attempts = 0
    attempts += 1
    for key, val in (
        ("compiled", "failed"),
        ("compile_error", _yaml_quote(reason)),
        ("compile_attempts", str(attempts)),
        ("compile_last_attempt", TIMESTAMP),
    ):
        content, _ = set_field(content, key, val)
    if content == filepath.read_text():
        log(f"WARN: could not mark failed (no usable frontmatter fence): {filepath}")
        return
    filepath.write_text(content)
                                                                                      
    log(f"PROMOTE: FAILED {filepath.name} attempt={attempts} "
        f"reason={' '.join(str(reason).split())[:300]}")


                                                                               

def main():
    parser = argparse.ArgumentParser(description="Incremental wiki compilation")
    parser.add_argument("modes", nargs="+",
                        choices=["backlinks", "indexes", "promote", "all"],
                        help="Compilation modes to run")
    parser.add_argument("--dry-run", action="store_true",
                        help="Preview without writing files")
    parser.add_argument("--limit", type=int, default=0, metavar="N",
                        help="promote: process at most N sources this run (0 = no limit). "
                             "Promotion may call a model for each eligible source; "
                             "review a small run before processing the full library.")
    parser.add_argument("--retry-failed", action="store_true",
                        help="promote: also retry sources quarantined after "
                             f"{MAX_COMPILE_ATTEMPTS} failed attempts")
    args = parser.parse_args()

    modes = set(args.modes)
    if "all" in modes:
        modes = {"backlinks", "indexes", "promote"}

    print(f"=== Wiki Compilation ({', '.join(sorted(modes))}) ===")
    print(f"Started: {TIMESTAMP}")
    log(f"Compilation started: modes={','.join(sorted(modes))} dry_run={args.dry_run}")

    if "backlinks" in modes:
        do_backlinks(args.dry_run)

    if "indexes" in modes:
        do_indexes(args.dry_run)

    if "promote" in modes:
        do_promote(args.dry_run, limit=args.limit, retry_failed=args.retry_failed)

    print(f"\n=== Done ===")
    log("Compilation complete")


if __name__ == "__main__":
    main()
