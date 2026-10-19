#!/usr/bin/env python3








































import re

__all__ = ["split_fence", "set_field", "sub_body_once", "edit_fence"]


def split_fence(text):






    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return [], lines, False
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return lines[1:i], lines[i + 1:], True
    return [], lines, False                                       


def set_field(text, key, value, add_if_missing=True):






    fm, body, ok = split_fence(text)
    if not ok:
        return text, False

    pat = re.compile(r"^\s*" + re.escape(key) + r"\s*:")
    for i, line in enumerate(fm):
        if pat.match(line):
            new = f"{key}: {value}"
            if line == new:
                return text, False
            fm[i] = new
            return "---\n" + "\n".join(fm) + "\n---\n" + "\n".join(body), True

    if not add_if_missing:
        return text, False
    fm.append(f"{key}: {value}")
    return "---\n" + "\n".join(fm) + "\n---\n" + "\n".join(body), True


def edit_fence(text, fn):







    fm, body, ok = split_fence(text)
    if not ok:
        return text, False
    new_fm = list(fn(list(fm)))
    if new_fm == fm:
        return text, False
    return "---\n" + "\n".join(new_fm) + "\n---\n" + "\n".join(body), True


def sub_body_once(text, pattern, repl):






    fm, body, ok = split_fence(text)
    if not ok:
        new_body, n = re.subn(pattern, repl, text, count=1)
        return new_body, bool(n)
    joined = "\n".join(body)
    new_body, n = re.subn(pattern, repl, joined, count=1)
    if not n:
        return text, False
    return "---\n" + "\n".join(fm) + "\n---\n" + new_body, True
