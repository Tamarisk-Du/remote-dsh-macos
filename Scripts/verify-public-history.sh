#!/bin/bash

set -euo pipefail
umask 077

fail() {
  printf 'PUBLIC_HISTORY_FAIL rule=%s\n' "$1" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  printf 'PUBLIC_HISTORY_FAIL rule=arguments\n' >&2
  exit 64
fi

input_path="$1"
git -C "$input_path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail git-worktree
repository_root="$(git -C "$input_path" rev-parse --show-toplevel)" || fail repository-root
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temporary_directory="$(mktemp -d)"
chmod 700 "$temporary_directory"
scanner_binary="$temporary_directory/PublicTreeScanner"
denylist_path="$temporary_directory/denylist.txt"
commits_path="$temporary_directory/commits.txt"
objects_path="$temporary_directory/objects.txt"
tree_entries_path="$temporary_directory/tree-entries.txt"
historical_path_file="$temporary_directory/historical-path.txt"
: > "$denylist_path"
: > "$historical_path_file"
chmod 600 "$denylist_path"
chmod 600 "$historical_path_file"

cleanup() {
  case "$temporary_directory" in
    "${TMPDIR%/}"/*|/tmp/*|/private/tmp/*|/var/folders/*)
      rm -rf -- "$temporary_directory"
      ;;
    *)
      printf 'PUBLIC_HISTORY_FAIL rule=unsafe-cleanup\n' >&2
      return 1
      ;;
  esac
}
trap cleanup EXIT

append_discovered_value() {
  local value="$1"
  if [[ -n "$value" && ${#value} -ge 4 ]]; then
    printf '%s\n' "$value" >> "$denylist_path"
  fi
}

append_discovered_value "$(id -un)"
append_discovered_value "$(hostname -s)"
append_discovered_value "$(scutil --get ComputerName 2>/dev/null || true)"
append_discovered_value "$(git -C "$repository_root" config --global --get user.name 2>/dev/null || true)"
append_discovered_value "$(git -C "$repository_root" config --global --get user.email 2>/dev/null || true)"

if [[ -n "${REMOTE_DSH_ADDITIONAL_DENYLIST:-}" ]]; then
  additional_denylist="$REMOTE_DSH_ADDITIONAL_DENYLIST"
  [[ ! -L "$additional_denylist" && -f "$additional_denylist" && -r "$additional_denylist" ]] || fail additional-denylist
  while IFS= read -r value || [[ -n "$value" ]]; do
    [[ -z "$value" ]] || printf '%s\n' "$value" >> "$denylist_path"
  done < "$additional_denylist"
fi

/usr/bin/swiftc "$script_directory/PublicTreeScanner.swift" -o "$scanner_binary" || fail scanner-build
git -C "$repository_root" rev-list --all > "$commits_path" || fail enumerate-commits
git -C "$repository_root" rev-list --objects --all > "$objects_path" || fail enumerate-objects
[[ -s "$commits_path" ]] || fail no-commits
[[ -s "$objects_path" ]] || fail no-objects

commit_count=0
path_count=0
while IFS= read -r commit || [[ -n "$commit" ]]; do
  [[ "$commit" =~ ^[0-9a-fA-F]+$ ]] || fail malformed-commit-id
  object_type="$(git -C "$repository_root" cat-file -t "$commit" 2>/dev/null)" || fail missing-commit
  [[ "$object_type" == commit ]] || fail non-commit-object
  commit_file="$(mktemp "$temporary_directory/commit.XXXXXX")" || fail commit-temp-file
  chmod 600 "$commit_file"
  git -C "$repository_root" cat-file commit "$commit" > "$commit_file" || fail read-commit
  "$scanner_binary" "commit:$commit" "$commit_file" "$denylist_path"
  rm -f -- "$commit_file"

  git -C "$repository_root" ls-tree -rz --full-tree "$commit" > "$tree_entries_path" || fail enumerate-tree
  while IFS= read -r -d '' tree_entry; do
    relative_path="${tree_entry#*$'\t'}"
    [[ "$relative_path" != "$tree_entry" ]] || fail malformed-tree-entry
    printf '%s' "$relative_path" > "$historical_path_file" || fail write-historical-path
    "$scanner_binary" "path:$relative_path" "$historical_path_file" "$denylist_path"
    path_count=$((path_count + 1))
  done < "$tree_entries_path"
  commit_count=$((commit_count + 1))
done < "$commits_path"

blob_count=0
while IFS= read -r object_line || [[ -n "$object_line" ]]; do
  object_id="${object_line%% *}"
  [[ "$object_id" =~ ^[0-9a-fA-F]+$ ]] || fail malformed-object-id
  object_type="$(git -C "$repository_root" cat-file -t "$object_id" 2>/dev/null)" || fail missing-object
  if [[ "$object_type" == blob ]]; then
    blob_file="$(mktemp "$temporary_directory/blob.XXXXXX")" || fail blob-temp-file
    chmod 600 "$blob_file"
    git -C "$repository_root" cat-file blob "$object_id" > "$blob_file" || fail read-blob
    "$scanner_binary" "$object_id" "$blob_file" "$denylist_path"
    rm -f -- "$blob_file"
    blob_count=$((blob_count + 1))
  fi
done < "$objects_path"

[[ $commit_count -gt 0 ]] || fail no-scanned-commits
[[ $blob_count -gt 0 ]] || fail no-scanned-blobs
[[ $path_count -gt 0 ]] || fail no-scanned-paths
printf 'PUBLIC_HISTORY_PASS commits=%d blobs=%d paths=%d\n' "$commit_count" "$blob_count" "$path_count"
