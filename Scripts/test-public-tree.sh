#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
verifier="$script_directory/verify-public-tree.sh"
temporary_root="$(mktemp -d)"
denylist="$temporary_root/denylist.txt"

cleanup() {
  find "$temporary_root" -type f -name unreadable.txt -exec chmod 600 {} + 2>/dev/null || true
  rm -rf "$temporary_root"
}
trap cleanup EXIT

printf '%s\n' 'identity-marker-7f1e2c' > "$denylist"

expect_pass() {
  local label="$1"
  shift
  "$@" || { printf 'EXPECTED_PASS_FAILED %s\n' "$label" >&2; exit 1; }
}

expect_fail() {
  local label="$1"
  shift
  if "$@"; then
    printf 'EXPECTED_FAILURE_MISSING %s\n' "$label" >&2
    exit 1
  fi
}

create_fixture() {
  fixture="$(mktemp -d "$temporary_root/fixture.XXXXXX")"
  git -C "$fixture" init -q
  git -C "$fixture" config user.name "Fixture Test"
  git -C "$fixture" config user.email "fixture@example.invalid"
  printf '%s\n' safe > "$fixture/tracked.txt"
  git -C "$fixture" add tracked.txt
}

create_fixture
expect_pass safe env REMOTE_DSH_ADDITIONAL_DENYLIST="$denylist" \
  "$verifier" "$fixture"

create_fixture
printf '%s%s%s%s\n' '/' 'Users' '/' '`' > "$fixture/tracked.txt"
git -C "$fixture" add tracked.txt
expect_pass bare-home-prefix "$verifier" "$fixture"

create_fixture
printf '%s\n' 'identity-marker-7f1e2c' > "$fixture/tracked.txt"
git -C "$fixture" add tracked.txt
expect_fail personal-identifier env REMOTE_DSH_ADDITIONAL_DENYLIST="$denylist" \
  "$verifier" "$fixture"

create_fixture
marker_prefix='identity-marker-'
marker_suffix='7f1e2c'
mv "$fixture/tracked.txt" "$fixture/${marker_prefix}${marker_suffix}-notes.md"
git -C "$fixture" add -A
expect_fail personal-identifier-filename env REMOTE_DSH_ADDITIONAL_DENYLIST="$denylist" \
  "$verifier" "$fixture"

create_fixture
printf '%s%s\n' '-----BEGIN ' 'PRIVATE KEY-----' > "$fixture/tracked.txt"
git -C "$fixture" add tracked.txt
expect_fail private-key "$verifier" "$fixture"

create_fixture
ln -s tracked.txt "$fixture/link.txt"
git -C "$fixture" add link.txt
expect_fail tracked-symlink "$verifier" "$fixture"

create_fixture
printf '%s\n' safe > "$fixture/unsupported.txt"
git -C "$fixture" add unsupported.txt
rm "$fixture/unsupported.txt"
mkfifo "$fixture/unsupported.txt"
expect_fail tracked-fifo "$verifier" "$fixture"

create_fixture
printf '%s\n' safe > "$fixture/unreadable.txt"
git -C "$fixture" add unreadable.txt
chmod 000 "$fixture/unreadable.txt"
expect_fail unreadable-file "$verifier" "$fixture"
