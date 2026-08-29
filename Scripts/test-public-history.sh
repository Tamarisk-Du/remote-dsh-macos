#!/bin/bash

set -euo pipefail
umask 077

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
verifier="$script_directory/verify-public-history.sh"
temporary_root="$(mktemp -d)"

cleanup() {
  case "$temporary_root" in
    "${TMPDIR%/}"/*|/tmp/*|/private/tmp/*|/var/folders/*)
      rm -rf -- "$temporary_root"
      ;;
    *)
      printf 'PUBLIC_HISTORY_TEST_FAIL rule=unsafe-cleanup\n' >&2
      return 1
      ;;
  esac
}
trap cleanup EXIT

fixture="$temporary_root/repository"
denylist="$temporary_root/denylist.txt"
output="$temporary_root/verifier.output"
marker_prefix='historical-identity-'
marker_suffix='marker-9a2d6e'
marker="${marker_prefix}${marker_suffix}"

printf '%s\n' "$marker" > "$denylist"
git -C "$temporary_root" init -q -b main repository
git -C "$fixture" config user.name 'Fixture Test'
git -C "$fixture" config user.email 'fixture@example.invalid'

printf 'safe\n' > "$fixture/safe.txt"
git -C "$fixture" add safe.txt
git -C "$fixture" commit -qm 'safe baseline'

mv "$fixture/safe.txt" "$fixture/${marker}-notes.md"
git -C "$fixture" add -A
git -C "$fixture" commit -qm 'historical path fixture'

mv "$fixture/${marker}-notes.md" "$fixture/safe.txt"
git -C "$fixture" add -A
git -C "$fixture" commit -qm 'remove historical path fixture'

if git -C "$fixture" ls-files | grep -Fq "$marker"; then
  printf 'PUBLIC_HISTORY_TEST_FAIL rule=fixture-current-tree\n' >&2
  exit 1
fi

status=0
REMOTE_DSH_ADDITIONAL_DENYLIST="$denylist" \
  /bin/bash "$verifier" "$fixture" > "$output" 2>&1 || status=$?
if [[ $status -eq 0 ]]; then
  printf 'PUBLIC_HISTORY_TEST_FAIL rule=historical-path-accepted\n' >&2
  exit 1
fi
if ! grep -Fq 'PUBLIC_TREE_FAIL rule=denylist' "$output"; then
  printf 'PUBLIC_HISTORY_TEST_FAIL rule=unexpected-verifier-output\n' >&2
  exit 1
fi
if grep -Fq "$marker" "$output"; then
  printf 'PUBLIC_HISTORY_TEST_FAIL rule=historical-path-disclosed\n' >&2
  exit 1
fi

printf 'PUBLIC_HISTORY_TEST_PASS\n'
