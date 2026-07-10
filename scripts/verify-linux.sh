#!/usr/bin/env bash
# Verification that can run on Linux (no Xcode/UIKit available here).
# The authoritative app build is the "App build" job in .github/workflows/ci.yml
# (macOS runner) — dispatch it after app-layer changes.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

echo "== 1. NotesCore tests (skipped when no swift toolchain) =="
if command -v swift >/dev/null 2>&1; then
    swift test --package-path NotesCore || fail=1
else
    echo "   swift not installed — NotesCore tests run in CI (notescore-tests job)"
fi

echo "== 2. Swift syntax check (parse-only; UIKit cannot be type-checked on Linux) =="
if command -v swiftc >/dev/null 2>&1; then
    find NotesApp -name '*.swift' -print0 | xargs -0 -n1 swiftc -parse -o /dev/null 2>/dev/null || fail=1
else
    echo "   swiftc not installed — skipped"
fi

echo "== 3. Property lists =="
python3 - <<'EOF' || fail=1
import plistlib, sys
for path in ["NotesApp/Info.plist", "NotesApp/NotesApp.entitlements"]:
    with open(path, "rb") as f:
        plistlib.load(f)
    print(f"   OK {path}")
EOF

echo "== 4. Asset catalog JSON =="
python3 - <<'EOF' || fail=1
import json, glob
for path in glob.glob("NotesApp/Assets.xcassets/**/Contents.json", recursive=True):
    json.load(open(path))
    print(f"   OK {path}")
EOF

echo "== 5. Xcode project file sanity (OpenStep format) =="
python3 - <<'EOF' || fail=1
import re
s = open("Notes.xcodeproj/project.pbxproj").read()
assert s.startswith("// !$*UTF8*$!"), "missing UTF8 header"
depth_b = depth_p = 0
i, n = 0, len(s)
while i < n:
    c = s[i]
    if c == "/" and i + 1 < n and s[i + 1] == "*":
        i = s.index("*/", i) + 2
        continue
    if c == '"':
        i += 1
        while s[i] != '"':
            if s[i] == "\\":
                i += 1
            i += 1
        i += 1
        continue
    if c == "{": depth_b += 1
    elif c == "}": depth_b -= 1
    elif c == "(": depth_p += 1
    elif c == ")": depth_p -= 1
    assert depth_b >= 0 and depth_p >= 0, f"unbalanced at offset {i}"
    i += 1
assert depth_b == 0 and depth_p == 0, (depth_b, depth_p)
ids = set(re.findall(r"D0C0FFEE00000000000000[0-9A-F]{2}", s))
defined = set(re.findall(r"^\t\t(D0C0FFEE00000000000000[0-9A-F]{2})", s, re.M))
missing = ids - defined
assert not missing, f"referenced but undefined object IDs: {missing}"
print(f"   OK project.pbxproj ({len(ids)} object IDs, braces balanced)")
EOF

echo
if [ "$fail" -eq 0 ]; then
    echo "verify-linux: all checks passed"
else
    echo "verify-linux: FAILURES (see above)"
    exit 1
fi
