#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'PUBLIC_TREE_FAIL rule=arguments\n' >&2
  exit 2
fi

input_path="$1"
if ! git -C "$input_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'PUBLIC_TREE_FAIL rule=git-worktree\n' >&2
  exit 1
fi

repository_root="$(git -C "$input_path" rev-parse --show-toplevel)"
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temporary_directory="$(mktemp -d)"
scanner_binary="$temporary_directory/PublicTreeScanner"
denylist_path="$temporary_directory/denylist.txt"

cleanup() {
  rm -rf "$temporary_directory"
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
  if [[ -L "$additional_denylist" || ! -f "$additional_denylist" || ! -r "$additional_denylist" ]]; then
    printf 'PUBLIC_TREE_FAIL rule=additional-denylist\n' >&2
    exit 1
  fi
  while IFS= read -r value || [[ -n "$value" ]]; do
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value" >> "$denylist_path"
    fi
  done < "$additional_denylist"
fi

swiftc "$script_directory/PublicTreeScanner.swift" -o "$scanner_binary"

while IFS= read -r -d '' relative_path; do
  absolute_path="$repository_root/$relative_path"
  if [[ -L "$absolute_path" || ! -f "$absolute_path" || ! -r "$absolute_path" ]]; then
    printf 'PUBLIC_TREE_FAIL entry=%q\n' "$relative_path" >&2
    exit 1
  fi
  "$scanner_binary" "$relative_path" "$absolute_path" "$denylist_path"
done < <(git -C "$repository_root" ls-files -z)

printf 'PUBLIC_TREE_PASS\n'
