#!/usr/bin/env python3









import os
import re
import subprocess
from pathlib import Path

from mcp.server.fastmcp import FastMCP

VAULT_DIR = Path(os.environ.get(
    "VAULT_PATH",
    str(Path(__file__).resolve().parent.parent.parent),
))

VAULT_NAME = os.environ.get("MCP_SERVER_NAME", VAULT_DIR.name)

mcp = FastMCP(
    f"{VAULT_NAME}-vault",
    instructions=(
        f"Knowledge base server for the {VAULT_NAME} vault. "
        "Use tiered retrieval: start with vault_context (cheapest), "
        "then vault_indexes for navigation, vault_search to find specifics, "
        "and vault_read only when you need a full page. "
        "Every claim should trace back to a source in this vault."
    ),
)


@mcp.tool()
def vault_context() -> str:






    claude_md = VAULT_DIR / "CLAUDE.md"
    if not claude_md.exists():
        return "ERROR: CLAUDE.md not found at " + str(claude_md)
    return claude_md.read_text()


@mcp.tool()
def vault_status() -> str:






    claude_md = VAULT_DIR / "CLAUDE.md"
    if not claude_md.exists():
        return "ERROR: CLAUDE.md not found at " + str(claude_md)

    text = claude_md.read_text()
    target_headings = {
        "Current Season",
        "Active Goals",
        "Active Projects",
        "Areas of Responsibility",
    }
    sections = []
    current_heading = None
    current_lines: list[str] = []

    for line in text.split("\n"):
        if line.startswith("## "):
            if current_heading in target_headings:
                sections.append("\n".join(current_lines))
            heading_text = line[3:].strip()
            current_heading = heading_text
            current_lines = [line]
        else:
            current_lines.append(line)

    if current_heading in target_headings:
        sections.append("\n".join(current_lines))

    if not sections:
        return "No matching sections found in CLAUDE.md"
    return "\n\n".join(sections)


@mcp.tool()
def vault_indexes(index_name: str = "") -> str:







    index_dir = (VAULT_DIR / "wiki" / "indexes").resolve()
    try:
        index_dir.relative_to(VAULT_DIR.resolve())
    except ValueError:
        return "ERROR: Index directory is outside the vault directory"
    if not index_dir.is_dir():
        return "ERROR: wiki/indexes/ directory not found"

    def contained_file(path: Path) -> bool:
        try:
            path.resolve().relative_to(index_dir)
        except (ValueError, OSError, RuntimeError):
            return False
        return path.is_file()

    if not index_name:
        indexes = sorted(index_dir.glob("*.md"))
        lines = ["Available indexes:"]
        for idx in indexes:
            if not contained_file(idx):
                continue
            name = idx.stem
                                                               
            desc = _extract_title(idx)
            lines.append(f"  - {name}: {desc}")
        lines.append("")
        lines.append("Call vault_indexes(index_name='concepts') to read one.")
        return "\n".join(lines)

    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", index_name):
        return "ERROR: Invalid index name. Use vault_indexes() to list."
    index_file = index_dir / f"{index_name}.md"
    if not contained_file(index_file):
        return f"ERROR: No index named '{index_name}'. Use vault_indexes() to list."
    return index_file.read_text()


@mcp.tool()
def vault_search(query: str, scope: str = "wiki", max_results: int = 20) -> str:









    scope_map = {
        "wiki": "wiki",
        "summaries": "wiki/summaries",
        "concepts": "wiki/knowledge/concepts",
        "entities": "wiki/knowledge/entities",
        "decisions": "wiki/knowledge/decisions",
        "values": "wiki/knowledge/values",
        "goals": "wiki/knowledge/goals",
        "areas": "wiki/knowledge/areas",
        "reviews": "wiki/knowledge/reviews",
        "vault-registry": "wiki/knowledge/vault-registry",
        "raw": "raw",
        "outputs": "outputs",
        "all": ".",
    }
    search_dir = VAULT_DIR / scope_map.get(scope, "wiki")
    if not search_dir.exists():
        return f"ERROR: Scope '{scope}' not found at {search_dir}"

    try:
        result = subprocess.run(
            [
                "grep", "-r", "-i", "-l",
                "--include=*.md",
                query,
                str(search_dir),
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except subprocess.TimeoutExpired:
        return "ERROR: Search timed out"

    if not result.stdout.strip():
        return f"No results for '{query}' in {scope}/"

    files = result.stdout.strip().split("\n")[:max_results]

                                              
    lines = [f"Found {len(files)} file(s) matching '{query}' in {scope}/:\n"]
    for fpath in files:
        rel = os.path.relpath(fpath, VAULT_DIR)
        title = _extract_title(Path(fpath))
        snippet = _extract_snippet(Path(fpath), query)
        lines.append(f"### {title}")
        lines.append(f"**Path**: {rel}")
        if snippet:
            lines.append(f"**Snippet**: ...{snippet}...")
        lines.append("")

    lines.append("Use vault_read(path='wiki/...') to read a full page.")
    return "\n".join(lines)


@mcp.tool()
def vault_read(path: str) -> str:






    if not path.endswith(".md"):
        path += ".md"

    target = VAULT_DIR / path
    if not target.exists():
                                  
        alt = VAULT_DIR / "wiki" / path
        if alt.exists():
            target = alt
        else:
            return f"ERROR: File not found: {path}"

                                      
    try:
        target.resolve().relative_to(VAULT_DIR.resolve())
    except ValueError:
        return "ERROR: Path is outside the vault directory"

    return target.read_text()


def _extract_title(filepath: Path) -> str:

    try:
        with open(filepath) as f:
            in_frontmatter = False
            for line in f:
                stripped = line.strip()
                if stripped == "---":
                    in_frontmatter = not in_frontmatter
                    continue
                if in_frontmatter:
                    continue
                if stripped.startswith("# "):
                    return stripped[2:]
        return filepath.stem
    except Exception:
        return filepath.stem


def _extract_snippet(filepath: Path, query: str, context_chars: int = 150) -> str:

    try:
        text = filepath.read_text()
                          
        if text.startswith("---"):
            end = text.find("---", 3)
            if end > 0:
                text = text[end + 3:]

        match = re.search(re.escape(query), text, re.IGNORECASE)
        if not match:
            return ""
        start = max(0, match.start() - context_chars)
        end = min(len(text), match.end() + context_chars)
        snippet = text[start:end].replace("\n", " ").strip()
        return snippet
    except Exception:
        return ""


if __name__ == "__main__":
    mcp.run(transport="stdio")
