#!/bin/bash

set -euo pipefail
umask 077

if [[ $# -ne 1 ]]; then
  printf 'BUILD_APP_FAIL rule=arguments\n' >&2
  exit 64
fi

destination="$1"
if [[ "$destination" != /* ]]; then
  printf 'BUILD_APP_FAIL rule=absolute-destination\n' >&2
  exit 64
fi
if [[ "$destination" != *.app ]]; then
  printf 'BUILD_APP_FAIL rule=app-suffix\n' >&2
  exit 64
fi
if [[ -L "$destination" ]]; then
  printf 'BUILD_APP_FAIL rule=symlink-destination\n' >&2
  exit 1
fi
if [[ -e "$destination" && ! -d "$destination" ]]; then
  printf 'BUILD_APP_FAIL rule=directory-destination\n' >&2
  exit 1
fi

destination_parent="$(dirname "$destination")"
if [[ -L "$destination_parent" || ! -d "$destination_parent" ]]; then
  printf 'BUILD_APP_FAIL rule=real-destination-parent\n' >&2
  exit 1
fi

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
backups="$destination_parent/.remote-dsh-backups"
candidate=""
candidate_identity=""
candidate_state=unallocated

candidate_is_original_directory() {
  [[ -n "$candidate" && ! -L "$candidate" && -d "$candidate" ]] || return 1
  [[ "$(/usr/bin/stat -f '%d:%i' "$candidate")" == "$candidate_identity" ]]
}

cleanup() {
  local original_status=$?
  if [[ -n "$candidate" && ( -e "$candidate" || -L "$candidate" ) ]]; then
    case "$candidate:$candidate_state" in
      "$destination_parent"/.Remote-DSH.candidate.*:building)
        rm -rf -- "$candidate"
        ;;
      "$destination_parent"/.Remote-DSH.candidate.*:*)
        printf 'BUILD_APP_RECOVERY candidate=%s state=%s\n' "$candidate" "$candidate_state" >&2
        ;;
      *)
        printf 'BUILD_APP_FAIL rule=unsafe-candidate-cleanup\n' >&2
        ;;
    esac
  fi
  return "$original_status"
}
trap cleanup EXIT

if [[ -L "$backups" || ( -e "$backups" && ! -d "$backups" ) ]]; then
  printf 'BUILD_APP_FAIL rule=backup-directory\n' >&2
  exit 1
fi
if [[ ! -d "$backups" ]]; then
  mkdir -m 700 "$backups"
else
  chmod 700 "$backups"
fi

candidate="$(/usr/bin/mktemp -d "$destination_parent/.Remote-DSH.candidate.XXXXXX")" || {
  printf 'BUILD_APP_FAIL rule=create-candidate\n' >&2
  exit 1
}
if [[ -L "$candidate" || ! -d "$candidate" ]]; then
  printf 'BUILD_APP_FAIL rule=real-candidate-directory\n' >&2
  exit 1
fi
candidate_state=building
chmod 700 "$candidate"
candidate_identity="$(/usr/bin/stat -f '%d:%i' "$candidate")"

cd "$repository_root"
/usr/bin/swift build -c release --product RemoteDSHApp --arch arm64
release_bin_directory="$(/usr/bin/swift build -c release --product RemoteDSHApp --arch arm64 --show-bin-path)"
release_executable="$release_bin_directory/RemoteDSHApp"
if [[ -L "$release_executable" || ! -f "$release_executable" || ! -x "$release_executable" ]]; then
  printf 'BUILD_APP_FAIL rule=release-executable\n' >&2
  exit 1
fi

if ! candidate_is_original_directory; then
  printf 'BUILD_APP_FAIL rule=candidate-replaced\n' >&2
  exit 1
fi
mkdir -m 700 "$candidate/Contents"
mkdir -m 700 "$candidate/Contents/MacOS"
cp "$release_executable" "$candidate/Contents/MacOS/RemoteDSHApp"
cp "$repository_root/Resources/Info.plist" "$candidate/Contents/Info.plist"
chmod 755 "$candidate" "$candidate/Contents" "$candidate/Contents/MacOS"
chmod 755 "$candidate/Contents/MacOS/RemoteDSHApp"
chmod 644 "$candidate/Contents/Info.plist"

/usr/bin/plutil -lint "$candidate/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$candidate"
/bin/bash "$repository_root/Scripts/verify-bundle.sh" "$candidate"
if ! candidate_is_original_directory; then
  printf 'BUILD_APP_FAIL rule=candidate-replaced\n' >&2
  exit 1
fi
candidate_state=verified

/usr/bin/swift "$repository_root/Scripts/AtomicBundleInstall.swift" \
  "$candidate" "$destination" "$backups"
candidate_state=installed
/bin/bash "$repository_root/Scripts/verify-bundle.sh" "$destination"

if [[ -e "$candidate" || -L "$candidate" ]]; then
  printf 'BUILD_APP_FAIL rule=candidate-remains\n' >&2
  exit 1
fi

printf 'BUILD_APP_PASS destination=%s\n' "$destination"
