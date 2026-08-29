#!/bin/bash

set -euo pipefail
umask 077

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
filename_output="$temporary_root/personal-identifier-filename.output"
filename_status=0
REMOTE_DSH_ADDITIONAL_DENYLIST="$denylist" \
  "$verifier" "$fixture" > "$filename_output" 2>&1 || filename_status=$?
if [[ $filename_status -eq 0 ]]; then
  printf 'EXPECTED_FAILURE_MISSING personal-identifier-filename\n' >&2
  exit 1
fi
if ! grep -Fq 'PUBLIC_TREE_FAIL rule=denylist' "$filename_output"; then
  printf 'PUBLIC_TREE_TEST_FAIL rule=unexpected-filename-output\n' >&2
  exit 1
fi
if grep -Fq "${marker_prefix}${marker_suffix}" "$filename_output"; then
  printf 'PUBLIC_TREE_TEST_FAIL rule=tracked-filename-disclosed\n' >&2
  exit 1
fi

create_fixture
real_git="$(command -v git)"
fake_git_directory="$temporary_root/fake-git"
fake_git="$fake_git_directory/git"
mkdir -m 700 "$fake_git_directory"
printf '%s\n' \
  '#!/bin/bash' \
  'set -eu' \
  'previous=' \
  'for argument in "$@"; do' \
  '  if [[ "$previous" == ls-files && "$argument" == -z && "${REMOTE_DSH_TEST_FAIL_LS_FILES:-}" == 1 ]]; then' \
  "    printf 'tracked.txt\\0'" \
  '    exit 73' \
  '  fi' \
  '  previous="$argument"' \
  'done' \
  'exec "$REMOTE_DSH_TEST_REAL_GIT" "$@"' > "$fake_git"
chmod 700 "$fake_git"
enumeration_output="$temporary_root/enumeration-failure.output"
enumeration_status=0
PATH="$fake_git_directory:$PATH" \
REMOTE_DSH_TEST_REAL_GIT="$real_git" \
REMOTE_DSH_TEST_FAIL_LS_FILES=1 \
  "$verifier" "$fixture" > "$enumeration_output" 2>&1 || enumeration_status=$?
if [[ $enumeration_status -eq 0 ]]; then
  printf 'PUBLIC_TREE_TEST_FAIL rule=enumeration-failure-accepted\n' >&2
  exit 1
fi
if ! grep -Fxq 'PUBLIC_TREE_FAIL rule=enumerate-tracked-files' "$enumeration_output"; then
  printf 'PUBLIC_TREE_TEST_FAIL rule=unexpected-enumeration-output\n' >&2
  exit 1
fi
if grep -Fq 'PUBLIC_TREE_PASS' "$enumeration_output"; then
  printf 'PUBLIC_TREE_TEST_FAIL rule=enumeration-failure-reported-pass\n' >&2
  exit 1
fi

create_fixture
printf '%s%s\n' '-----BEGIN ' 'PRIVATE KEY-----' > "$fixture/tracked.txt"
git -C "$fixture" add tracked.txt
expect_fail private-key "$verifier" "$fixture"

create_fixture
printf '%s%s\n' 'Authorization: Bearer ' 'do-not-display' > "$fixture/tracked.txt"
git -C "$fixture" add tracked.txt
expect_pass explicit-test-placeholder "$verifier" "$fixture"

create_fixture
printf '%s%s%s\n' 'Authorization: Bearer ' 'do-not-display' '.secret' > "$fixture/tracked.txt"
git -C "$fixture" add tracked.txt
expect_fail extended-dot-prefix "$verifier" "$fixture"

create_fixture
printf '%s%s%s\n' 'Authorization: Bearer ' 'do-not-display' '-extra' > "$fixture/tracked.txt"
git -C "$fixture" add tracked.txt
expect_fail extended-hyphen-prefix "$verifier" "$fixture"

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
