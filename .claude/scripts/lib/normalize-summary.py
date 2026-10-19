#!/usr/bin/env python3


























import sys


def is_fence(line: str) -> bool:
    s = line.strip()
    return s.startswith("```")


def is_fm_key(line: str) -> bool:
    s = line.strip()
    if ":" not in s:
        return False
    key = s.split(":", 1)[0]
                                                                                 
    return (
        len(key) > 0
        and (key[0].islower() or key[0] == "_")
        and all(c.isalnum() or c in "_.-" for c in key)
    )


def main() -> int:
    lines = sys.stdin.read().splitlines()

                                          
    fm_start = None
    for i, line in enumerate(lines):
        if line.strip() != "---":
            continue
                                                       
        j = i + 1
        while j < len(lines) and not lines[j].strip():
            j += 1
        if j < len(lines) and is_fm_key(lines[j]):
            fm_start = i
            break

    if fm_start is None:
        sys.stderr.write("normalize-summary: no YAML frontmatter found\n")
        sys.stdout.write("\n".join(lines))
        if lines:
            sys.stdout.write("\n")
        return 1

    body = lines[fm_start:]

                                                      
    while body and not body[-1].strip():
        body.pop()
    if body and is_fence(body[-1]):
        body.pop()
        while body and not body[-1].strip():
            body.pop()
                                                                                 
    while body and is_fence(body[0]):
        body.pop(0)
        while body and not body[0].strip():
            body.pop(0)

    sys.stdout.write("\n".join(body))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
