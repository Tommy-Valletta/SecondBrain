#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
P=wiki/workbench/brain-friction-log.md
python3 - "$P" <<'PY'
import io, re, sys
t = io.open(sys.argv[1], encoding='utf-8').read()
nums = [int(n) for n in re.findall(r'^## F-(\d+)', t, re.M)]
last = re.findall(r'^## (F-\d+[^\n]*)', t, re.M)[-1]
stated = re.search(r'\*\*(\d+) findings\*\*', t)
dupes = sorted({n for n in nums if nums.count(n) > 1})
print("count=%d max=%d stated=%s" % (len(nums), max(nums), stated.group(1) if stated else '?'))
print("last-heading=%s" % last)
print("duplicates=%s" % (dupes or 'none'))
assert not dupes, "duplicate F-numbers: %s" % dupes
stated_num = int(stated.group(1)) if stated else 0
if stated_num == 0 and len(nums) == 0:
    print("OK (empty log)")
else:
    assert stated_num == len(nums), "frontmatter count disagrees with headings"
    print("OK")
PY
