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

tag_fixture="$temporary_root/tag-repository"
tag_output="$temporary_root/tag-verifier.output"
tag_name="release-$marker"
git -C "$temporary_root" init -q -b main tag-repository
git -C "$tag_fixture" config user.name 'Fixture Test'
git -C "$tag_fixture" config user.email 'fixture@example.invalid'
printf 'safe\n' > "$tag_fixture/safe.txt"
git -C "$tag_fixture" add safe.txt
git -C "$tag_fixture" commit -qm 'safe tag baseline'
git -C "$tag_fixture" tag -a "$tag_name" -m 'safe annotated tag'

tag_status=0
REMOTE_DSH_ADDITIONAL_DENYLIST="$denylist" \
  /bin/bash "$verifier" "$tag_fixture" > "$tag_output" 2>&1 || tag_status=$?
if [[ $tag_status -eq 0 ]]; then
  printf 'PUBLIC_HISTORY_TEST_FAIL rule=annotated-tag-accepted\n' >&2
  exit 1
fi
if ! grep -Fq 'PUBLIC_TREE_FAIL rule=denylist' "$tag_output"; then
  printf 'PUBLIC_HISTORY_TEST_FAIL rule=unexpected-tag-output\n' >&2
  exit 1
fi
if grep -Fq "$marker" "$tag_output"; then
  printf 'PUBLIC_HISTORY_TEST_FAIL rule=annotated-tag-disclosed\n' >&2
  exit 1
fi

unsupported_fixture="$temporary_root/unsupported-repository"
unsupported_output="$temporary_root/unsupported-verifier.output"
git -C "$temporary_root" init -q -b main unsupported-repository
git -C "$unsupported_fixture" config user.name 'Fixture Test'
git -C "$unsupported_fixture" config user.email 'fixture@example.invalid'
printf 'safe\n' > "$unsupported_fixture/safe.txt"
git -C "$unsupported_fixture" add safe.txt
git -C "$unsupported_fixture" commit -qm 'safe unsupported-type baseline'
unsupported_object="$(git -C "$unsupported_fixture" rev-parse 'HEAD^{tree}')"
real_git="$(command -v git)"
fake_git_directory="$temporary_root/fake-git"
fake_git="$fake_git_directory/git"
mkdir -m 700 "$fake_git_directory"
printf '%s\n' \
  '#!/bin/bash' \
  'set -eu' \
  'previous=' \
  'for argument in "$@"; do' \
  '  if [[ "$previous" == -t && "$argument" == "$REMOTE_DSH_TEST_OBJECT_ID" ]]; then' \
  '    printf "future-object-type\n"' \
  '    exit 0' \
  '  fi' \
  '  previous="$argument"' \
  'done' \
  'exec "$REMOTE_DSH_TEST_REAL_GIT" "$@"' > "$fake_git"
chmod 700 "$fake_git"

unsupported_status=0
PATH="$fake_git_directory:$PATH" \
REMOTE_DSH_TEST_REAL_GIT="$real_git" \
REMOTE_DSH_TEST_OBJECT_ID="$unsupported_object" \
  /bin/bash "$verifier" "$unsupported_fixture" > "$unsupported_output" 2>&1 \
  || unsupported_status=$?
if [[ $unsupported_status -eq 0 ]]; then
  printf 'PUBLIC_HISTORY_TEST_FAIL rule=unsupported-object-accepted\n' >&2
  exit 1
fi
if ! grep -Fxq 'PUBLIC_HISTORY_FAIL rule=unsupported-object-type' "$unsupported_output"; then
  printf 'PUBLIC_HISTORY_TEST_FAIL rule=unexpected-unsupported-object-output\n' >&2
  exit 1
fi
if grep -Fq 'PUBLIC_HISTORY_PASS' "$unsupported_output"; then
  printf 'PUBLIC_HISTORY_TEST_FAIL rule=unsupported-object-reported-pass\n' >&2
  exit 1
fi

printf 'PUBLIC_HISTORY_TEST_PASS\n'
