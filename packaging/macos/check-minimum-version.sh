#!/usr/bin/env bash
# Fail unless a built WispTerm.app declares the expected minimum macOS in both
# places the OS reads it: the Mach-O LC_BUILD_VERSION `minos` (dyld refuses to
# load an older OS) and Info.plist LSMinimumSystemVersion (Launch Services
# refuses to open on an older OS). Run through `zig build check-macos-minimum`,
# which passes the minimum declared in build.zig.
set -euo pipefail

usage="usage: check-minimum-version.sh <path/to/WispTerm.app> <expected-version>"
app_path="${1:?$usage}"
expected="${2:?$usage}"
plist="$app_path/Contents/Info.plist"
binary="$app_path/Contents/MacOS/WispTerm"

if [[ ! -f "$plist" || ! -f "$binary" ]]; then
  echo "invalid app bundle layout: $app_path" >&2
  exit 1
fi

minos="$(otool -l "$binary" | awk '$1 == "cmd" && $2 == "LC_BUILD_VERSION" { found = 1 } found && $1 == "minos" { print $2; exit }')"
plist_minimum="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$plist" 2>/dev/null || true)"

status=0
if [[ "$minos" != "$expected" ]]; then
  echo "binary minos is ${minos:-missing}, expected $expected: $binary" >&2
  status=1
fi
if [[ "$plist_minimum" != "$expected" ]]; then
  echo "Info.plist LSMinimumSystemVersion is ${plist_minimum:-missing}, expected $expected: $plist" >&2
  status=1
fi

if [[ "$status" -eq 0 ]]; then
  echo "macOS minimum $expected: binary minos and Info.plist agree"
fi
exit "$status"
