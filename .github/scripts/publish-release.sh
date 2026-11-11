#!/usr/bin/env bash
# Attach one platform's assets and notes section to the GitHub release for a tag.
#
#   publish-release.sh <tag> <notes-marker> <asset-notes-file> <asset>...
#
# Several workflows (Windows, macOS, Linux, wisptermctl) run on the same tag
# push and all end here. Each used to do `gh release view || gh release create
# ... <assets>`, so two that arrived together both tried to create the release:
# the loser failed and its assets were never attached, and only the winner's
# notes survived. This script is safe to run concurrently:
#
#   1. Create the release if it is missing. Losing that race is fine; the
#      release the other workflow made is used.
#   2. Upload the assets (`--clobber`, so a re-run replaces them).
#   3. Append this platform's notes section unless its marker line is already
#      in the body. The read-modify-write is not atomic on GitHub's side, so
#      the section is re-checked after a short random wait and appended again
#      if a concurrent edit dropped it.
#
# Requires GH_TOKEN and GH_REPO in the environment.
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "usage: $0 <tag> <notes-marker> <asset-notes-file> <asset>..." >&2
  exit 2
fi

tag="$1"
marker="$2"
asset_notes_file="$3"
shift 3

: "${GH_REPO:?GH_REPO must be set}"

for asset in "$@"; do
  if [[ ! -f "${asset}" ]]; then
    echo "release asset not found: ${asset}" >&2
    exit 1
  fi
done
asset_notes="$(cat "${asset_notes_file}")"

release_exists() {
  gh release view "${tag}" --repo "${GH_REPO}" >/dev/null 2>&1
}

if ! release_exists; then
  # Curated notes are named vX.Y.Z.md whether or not the tag carries the "v".
  curated=""
  curated_path="release-notes/v${tag#v}.md"
  if [[ -f "${curated_path}" ]]; then
    curated="$(cat "${curated_path}")"
  fi
  if ! gh release create "${tag}" \
    --repo "${GH_REPO}" \
    --verify-tag \
    --generate-notes \
    --notes "${curated}"; then
    echo "release create failed; checking whether another workflow created ${tag}" >&2
    found=0
    for _ in 1 2 3 4 5 6; do
      if release_exists; then
        found=1
        break
      fi
      sleep 5
    done
    if [[ "${found}" -ne 1 ]]; then
      echo "could not create or find release ${tag}" >&2
      exit 1
    fi
  fi
fi

gh release upload "${tag}" "$@" --clobber --repo "${GH_REPO}"

for attempt in 1 2 3 4 5 6; do
  body="$(gh release view "${tag}" --repo "${GH_REPO}" --json body --jq '.body')"
  if grep -qF -- "${marker}" <<<"${body}"; then
    echo "release notes section present (check ${attempt})"
    exit 0
  fi
  gh release edit "${tag}" --repo "${GH_REPO}" \
    --notes "$(printf '%s\n\n%s\n' "${body}" "${asset_notes}")"
  sleep $(( (RANDOM % 6) + 3 ))
done

body="$(gh release view "${tag}" --repo "${GH_REPO}" --json body --jq '.body')"
if ! grep -qF -- "${marker}" <<<"${body}"; then
  echo "warning: could not keep the notes section for '${marker}' on ${tag}" >&2
fi
