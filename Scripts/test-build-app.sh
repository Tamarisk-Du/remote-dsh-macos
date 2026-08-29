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

printf 'BUILD_APP_TEST_PASS\n'
