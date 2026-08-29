#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
builder="$script_directory/build-app.sh"
temporary_root="$(mktemp -d)"

cleanup() {
  case "$temporary_root" in
    "${TMPDIR%/}"/*|/tmp/*|/private/tmp/*|/var/folders/*)
      rm -rf -- "$temporary_root"
      ;;
    *)
      printf 'BUILD_APP_TEST_FAIL rule=unsafe-cleanup\n' >&2
      return 1
      ;;
  esac
}
trap cleanup EXIT

expect_rejection() {
  local label="$1"
  local expected="$2"
  shift 2
  local output_file="$temporary_root/$label.output"
  local status=0
  DEVELOPER_DIR="$temporary_root/missing-developer-directory" \
    /bin/bash "$builder" "$@" >"$output_file" 2>&1 || status=$?
  if [[ $status -eq 0 ]]; then
    printf 'BUILD_APP_TEST_FAIL rule=accepted-invalid label=%s\n' "$label" >&2
    exit 1
  fi
  if ! grep -Fxq "$expected" "$output_file"; then
    printf 'BUILD_APP_TEST_FAIL rule=unexpected-error label=%s\n' "$label" >&2
    exit 1
  fi
  if grep -Eiq 'xcrun|toolchain|swift-driver|build complete' "$output_file"; then
    printf 'BUILD_APP_TEST_FAIL rule=build-ran-before-validation label=%s\n' "$label" >&2
    exit 1
  fi
}

expect_rejection zero-arguments 'BUILD_APP_FAIL rule=arguments'
expect_rejection relative-path 'BUILD_APP_FAIL rule=absolute-destination' 'Relative.app'
expect_rejection non-app 'BUILD_APP_FAIL rule=app-suffix' "$temporary_root/RemoteDSH"

real_destination="$temporary_root/Real.app"
symlink_destination="$temporary_root/Symlink.app"
mkdir -p "$real_destination"
ln -s "$real_destination" "$symlink_destination"
expect_rejection symlink-destination 'BUILD_APP_FAIL rule=symlink-destination' "$symlink_destination"

victim="$temporary_root/candidate-victim"
sentinel="$victim/sentinel.txt"
precreator="$temporary_root/precreate-predictable-candidate.sh"
candidate_record="$temporary_root/precreated-candidate.txt"
race_output="$temporary_root/precreated-candidate.output"
mkdir -m 700 "$victim"
printf 'untouched\n' > "$sentinel"
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'destination_parent="$1"' \
  'victim="$2"' \
  'builder="$3"' \
  'destination="$4"' \
  'record="$5"' \
  'candidate="$destination_parent/.Remote-DSH.candidate.$$.app"' \
  'ln -s "$victim" "$candidate"' \
  'printf "%s\n" "$candidate" > "$record"' \
  'exec env DEVELOPER_DIR="$destination_parent/missing-developer-directory" /bin/bash "$builder" "$destination"' \
  > "$precreator"
chmod 700 "$precreator"

race_status=0
/bin/bash "$precreator" \
  "$temporary_root" "$victim" "$builder" "$temporary_root/Race.app" "$candidate_record" \
  > "$race_output" 2>&1 || race_status=$?
if [[ $race_status -eq 0 ]]; then
  printf 'BUILD_APP_TEST_FAIL rule=unexpected-build-success\n' >&2
  exit 1
fi
if grep -Fq 'BUILD_APP_FAIL rule=candidate-collision' "$race_output"; then
  printf 'BUILD_APP_TEST_FAIL rule=predictable-candidate-selected\n' >&2
  exit 1
fi
precreated_candidate="$(<"$candidate_record")"
if [[ ! -L "$precreated_candidate" ]]; then
  printf 'BUILD_APP_TEST_FAIL rule=precreated-symlink-replaced\n' >&2
  exit 1
fi
if [[ "$(<"$sentinel")" != untouched || -e "$victim/Contents" ]]; then
  printf 'BUILD_APP_TEST_FAIL rule=precreated-symlink-followed\n' >&2
  exit 1
fi

printf 'BUILD_APP_TEST_PASS\n'
