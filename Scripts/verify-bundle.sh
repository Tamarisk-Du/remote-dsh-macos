#!/bin/bash

set -euo pipefail
umask 077

fail() {
  printf 'BUNDLE_VERIFY_FAIL rule=%s\n' "$1" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  printf 'BUNDLE_VERIFY_FAIL rule=arguments\n' >&2
  exit 64
fi

bundle="$1"
[[ "$bundle" == /* ]] || fail absolute-path
[[ ! -L "$bundle" && -d "$bundle" ]] || fail real-bundle-directory

temporary_directory="$(mktemp -d)"
chmod 700 "$temporary_directory"
entry_list="$temporary_directory/bundle-entries.txt"
scanner_binary="$temporary_directory/PublicTreeScanner"
denylist_path="$temporary_directory/denylist.txt"
strings_path="$temporary_directory/RemoteDSHApp.strings.txt"
: > "$entry_list"
: > "$denylist_path"
: > "$strings_path"
chmod 600 "$entry_list" "$denylist_path" "$strings_path"

cleanup() {
  case "$temporary_directory" in
    "${TMPDIR%/}"/*|/tmp/*|/private/tmp/*|/var/folders/*)
      rm -rf -- "$temporary_directory"
      ;;
    *)
      printf 'BUNDLE_VERIFY_FAIL rule=unsafe-cleanup\n' >&2
      return 1
      ;;
  esac
}
trap cleanup EXIT

contents="$bundle/Contents"
plist="$contents/Info.plist"
executable="$contents/MacOS/RemoteDSHApp"
[[ ! -L "$contents" && -d "$contents" ]] || fail contents-directory
[[ ! -L "$plist" && -f "$plist" ]] || fail info-plist
[[ ! -L "$executable" && -f "$executable" && -x "$executable" ]] || fail regular-executable

find "$bundle" -mindepth 1 -print0 > "$entry_list" || fail entry-enumeration
while IFS= read -r -d '' entry; do
  relative_path="${entry#"$bundle"/}"
  case "$relative_path" in
    Contents|Contents/MacOS|Contents/_CodeSignature)
      [[ ! -L "$entry" && -d "$entry" ]] || fail bundle-directory-shape
      ;;
    Contents/Info.plist|Contents/MacOS/RemoteDSHApp|Contents/_CodeSignature/CodeResources)
      [[ ! -L "$entry" && -f "$entry" ]] || fail bundle-file-shape
      ;;
    *)
      fail extra-entry
      ;;
  esac
done < "$entry_list"

[[ "$(stat -f %Lp "$plist")" == 644 ]] || fail info-plist-mode
[[ "$(stat -f %Lp "$executable")" == 755 ]] || fail executable-mode
/usr/bin/plutil -lint "$plist" >/dev/null || fail plist-lint

assert_plist_value() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(/usr/bin/plutil -extract "$key" raw "$plist" 2>/dev/null)" || fail "plist-$key"
  [[ "$actual" == "$expected" ]] || fail "plist-$key"
}

assert_plist_value CFBundleExecutable RemoteDSHApp
assert_plist_value CFBundleIdentifier org.example.remote-dsh-macos
assert_plist_value CFBundleName 'Remote DSH for macOS'
assert_plist_value CFBundleDisplayName 'Remote DSH for macOS'
assert_plist_value CFBundlePackageType APPL
assert_plist_value LSMinimumSystemVersion 14.0
assert_plist_value LSUIElement false

/usr/bin/codesign --verify --deep --strict --verbose=2 "$bundle" >/dev/null 2>&1 || fail signature-validity
signature_details="$(/usr/bin/codesign -d --verbose=4 "$bundle" 2>&1)" || fail signature-details
grep -Fq 'Signature=adhoc' <<< "$signature_details" || fail ad-hoc-signature
grep -Fq 'Identifier=org.example.remote-dsh-macos' <<< "$signature_details" || fail signature-identifier

architectures="$(/usr/bin/lipo -archs "$executable")" || fail architecture-read
[[ "$architectures" == arm64 ]] || fail arm64-only

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

append_discovered_value() {
  local value="$1"
  if [[ -n "$value" && ${#value} -ge 4 ]]; then
    printf '%s\n' "$value" >> "$denylist_path"
  fi
}

append_discovered_value "$(id -un)"
append_discovered_value "$(hostname -s)"
append_discovered_value "$(scutil --get ComputerName 2>/dev/null || true)"
append_discovered_value "$(git config --global --get user.name 2>/dev/null || true)"
append_discovered_value "$(git config --global --get user.email 2>/dev/null || true)"

if [[ -n "${REMOTE_DSH_ADDITIONAL_DENYLIST:-}" ]]; then
  additional_denylist="$REMOTE_DSH_ADDITIONAL_DENYLIST"
  [[ ! -L "$additional_denylist" && -f "$additional_denylist" && -r "$additional_denylist" ]] || fail additional-denylist
  while IFS= read -r value || [[ -n "$value" ]]; do
    [[ -z "$value" ]] || printf '%s\n' "$value" >> "$denylist_path"
  done < "$additional_denylist"
fi

/usr/bin/swiftc "$script_directory/PublicTreeScanner.swift" -o "$scanner_binary" || fail scanner-build
/usr/bin/strings -a "$executable" > "$strings_path" || fail executable-strings
[[ ! -L "$strings_path" && -f "$strings_path" && -r "$strings_path" ]] || fail strings-file
"$scanner_binary" 'Contents/Info.plist' "$plist" "$denylist_path"
"$scanner_binary" 'Contents/MacOS/RemoteDSHApp.printable-strings' "$strings_path" "$denylist_path"

printf 'BUNDLE_VERIFY_PASS identifier=org.example.remote-dsh-macos architecture=arm64 signature=adhoc\n'
