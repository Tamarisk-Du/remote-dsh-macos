#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
installer_source="$script_directory/AtomicBundleInstall.swift"
temporary_root="$(mktemp -d)"
installer="$temporary_root/AtomicBundleInstall"

cleanup() {
  chmod 700 "$temporary_root/Applications/.remote-dsh-backups" 2>/dev/null || true
  case "$temporary_root" in
    "${TMPDIR%/}"/*|/tmp/*|/private/tmp/*|/var/folders/*)
      rm -rf -- "$temporary_root"
      ;;
    *)
      printf 'ATOMIC_INSTALL_TEST_FAIL rule=unsafe-cleanup\n' >&2
      return 1
      ;;
  esac
}
trap cleanup EXIT

expect_fail() {
  local label="$1"
  shift
  if "$@"; then
    printf 'ATOMIC_INSTALL_TEST_FAIL rule=expected-failure label=%s\n' "$label" >&2
    exit 1
  fi
}

assert_tree_equal() {
  local expected="$1"
  local actual="$2"
  diff -rq "$expected" "$actual" >/dev/null || {
    printf 'ATOMIC_INSTALL_TEST_FAIL rule=tree-mismatch\n' >&2
    exit 1
  }
  [[ "$(stat -f %Lp "$expected")" == "$(stat -f %Lp "$actual")" ]] || {
    printf 'ATOMIC_INSTALL_TEST_FAIL rule=mode-mismatch\n' >&2
    exit 1
  }
}

/usr/bin/swiftc "$installer_source" -o "$installer"

applications="$temporary_root/Applications"
backups="$applications/.remote-dsh-backups"
target="$applications/Remote DSH for macOS.app"
candidate="$applications/.Remote-DSH.candidate.test.app"
mkdir -p "$backups" "$candidate/Contents"
chmod 700 "$backups"
printf 'new-first\n' > "$candidate/Contents/marker.txt"

"$installer" "$candidate" "$target" "$backups"
[[ -f "$target/Contents/marker.txt" ]]
[[ "$(<"$target/Contents/marker.txt")" == new-first ]]
[[ ! -e "$candidate" && ! -L "$candidate" ]]

mkdir -p "$candidate/Contents" "$applications/unrelated-directory" "$backups/unrelated-backup"
printf 'new-second\n' > "$candidate/Contents/marker.txt"
printf 'keep sibling\n' > "$applications/unrelated-directory/sentinel.txt"
printf 'keep backup\n' > "$backups/unrelated-backup/sentinel.txt"

"$installer" "$candidate" "$target" "$backups"
[[ "$(<"$target/Contents/marker.txt")" == new-second ]]
[[ ! -e "$candidate" && ! -L "$candidate" ]]
[[ "$(<"$applications/unrelated-directory/sentinel.txt")" == 'keep sibling' ]]
[[ "$(<"$backups/unrelated-backup/sentinel.txt")" == 'keep backup' ]]
old_bundle="$(find "$backups" -mindepth 1 -maxdepth 1 -type d ! -name unrelated-backup -print -quit)"
[[ -n "$old_bundle" && "$(<"$old_bundle/Contents/marker.txt")" == new-first ]]

target_snapshot="$temporary_root/target-snapshot"
cp -R "$target" "$target_snapshot"
target_inode="$(stat -f %i "$target")"
other_parent="$temporary_root/OtherApplications"
rejected_candidate="$other_parent/.Remote-DSH.candidate.rejected.app"
mkdir -p "$rejected_candidate/Contents"
printf 'rejected\n' > "$rejected_candidate/Contents/marker.txt"
expect_fail other-parent "$installer" "$rejected_candidate" "$target" "$backups"
assert_tree_equal "$target_snapshot" "$target"
[[ "$(stat -f %i "$target")" == "$target_inode" ]]
[[ "$(<"$rejected_candidate/Contents/marker.txt")" == rejected ]]

mkdir -p "$candidate/Contents"
printf 'new-third\n' > "$candidate/Contents/marker.txt"
candidate_snapshot="$temporary_root/candidate-snapshot"
cp -R "$candidate" "$candidate_snapshot"
candidate_inode="$(stat -f %i "$candidate")"
chmod 500 "$backups"
expect_fail rollback-after-archive-failure "$installer" "$candidate" "$target" "$backups"
chmod 700 "$backups"
assert_tree_equal "$target_snapshot" "$target"
assert_tree_equal "$candidate_snapshot" "$candidate"
[[ "$(stat -f %i "$target")" == "$target_inode" ]]
[[ "$(stat -f %i "$candidate")" == "$candidate_inode" ]]
[[ "$(<"$applications/unrelated-directory/sentinel.txt")" == 'keep sibling' ]]
[[ "$(<"$backups/unrelated-backup/sentinel.txt")" == 'keep backup' ]]

printf 'ATOMIC_INSTALL_TEST_PASS\n'
