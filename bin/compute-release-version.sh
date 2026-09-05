#!/usr/bin/env bash

# Computes the next explicit release version per ADR 0006 "Version computation".
# Used only by the prepare-release workflow — never for dev builds (see
# bin/compute-version.sh for that).
#
# Usage: ./bin/compute-release-version.sh <source_ref> <type> <version_bump>
#   source_ref:    dev, or a maintained release/X.Y line
#   type:          ga | alpha | beta | rc
#   version_bump:  patch | minor | major — applies whenever promoting from a GA
#                  (any type: ga, alpha, beta, rc). Ignored when the latest
#                  reachable release is already a pre-release (channel bump is
#                  fixed there: alphaNN -> alpha(NN+1), or alpha -> beta01, etc.)
#                  and when promoting an existing pre-release to GA.
#
# Requires a checkout with full tag history (fetch-depth: 0) and source_ref
# fetched and resolvable as "origin/<source_ref>".
#
# On success, prints the computed version (without a leading 'v') to stdout.
# On any invariant violation (channel-rank regression, release-line violation,
# SemVer gap/collision, or no explicit release reachable at all — bootstrap,
# out of scope per ADR 0006 Open Questions) prints an error to stderr and exits 1.

set -euo pipefail

source_ref="${1:?Usage: $0 <source_ref> <type> <version_bump>}"
type="${2:?Usage: $0 <source_ref> <type> <version_bump>}"
version_bump="${3:-patch}"

case "$type" in
  ga | alpha | beta | rc) ;;
  *)
    echo "error: type must be one of ga, alpha, beta, rc (got: $type)" >&2
    exit 1
    ;;
esac

case "$version_bump" in
  patch | minor | major) ;;
  *)
    echo "error: version_bump must be one of patch, minor, major (got: $version_bump)" >&2
    exit 1
    ;;
esac

rank() {
  case "$1" in
    alpha) echo 0 ;;
    beta) echo 1 ;;
    rc) echo 2 ;;
  esac
}

bump_version() {
  # $1 = X.Y.Z, $2 = patch|minor|major
  local base="$1" kind="$2" maj min pat
  IFS='.' read -r maj min pat <<<"$base"
  case "$kind" in
    patch) echo "${maj}.${min}.$((pat + 1))" ;;
    minor) echo "${maj}.$((min + 1)).0" ;;
    major) echo "$((maj + 1)).0.0" ;;
  esac
}

# Latest explicit release (GA or named pre-release) reachable from source_ref.
latest_tag=$(git describe --tags --match "v[0-9]*.[0-9]*.[0-9]*" --abbrev=0 "origin/${source_ref}" 2>/dev/null || echo "")

if [[ -z "$latest_tag" ]]; then
  echo "error: no explicit release reachable from '${source_ref}' — bootstrapping the first release on this history is out of scope (ADR 0006 Open Questions)" >&2
  exit 1
fi

latest="${latest_tag#v}"

# Release-line constraint (ADR 0003 + ADR 0006): a release/X.Y source may only
# ever produce vX.Y.* — minor/major bumps from such a source are a hard failure.
is_release_line=false
line=""
if [[ "$source_ref" =~ ^release/([0-9]+\.[0-9]+)$ ]]; then
  is_release_line=true
  line="${BASH_REMATCH[1]}"
fi

target=""

if [[ "$latest" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-(alpha|beta|rc)([0-9]+)$ ]]; then
  latest_base="${BASH_REMATCH[1]}"
  latest_channel="${BASH_REMATCH[2]}"
  latest_counter="${BASH_REMATCH[3]}"

  if [[ "$type" == "ga" ]]; then
    # Promote the pre-release to GA. version_bump does not apply here — there is
    # no "latest GA" to bump from, the version is fixed by the promoted pre-release.
    target="$latest_base"
  else
    if (($(rank "$type") < $(rank "$latest_channel"))); then
      echo "error: cannot prepare '${type}' — latest reachable release '${latest_tag}' is already at channel '${latest_channel}', which ranks higher. A release cannot move backward in channel maturity for the same target version." >&2
      exit 1
    elif [[ "$type" == "$latest_channel" ]]; then
      next_counter=$(printf '%02d' $((10#${latest_counter} + 1)))
      target="${latest_base}-${type}${next_counter}"
    else
      target="${latest_base}-${type}01"
    fi
  fi
elif [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  # Latest reachable release is a GA.
  target=$(bump_version "$latest" "$version_bump")
  if [[ "$type" != "ga" ]]; then
    target="${target}-${type}01"
  fi
else
  echo "error: could not parse latest reachable release tag '${latest_tag}'" >&2
  exit 1
fi

if [[ "$is_release_line" == "true" ]]; then
  target_line=$(grep -oE '^[0-9]+\.[0-9]+' <<<"$target")
  if [[ "$target_line" != "$line" ]]; then
    echo "error: source_ref 'release/${line}' may only produce ${line}.* releases; computed target '${target}' falls outside that line (version_bump: minor/major is invalid from a release/X.Y source)" >&2
    exit 1
  fi
fi

# SemVer gap check: the target must not already exist, and must be exactly the
# next version in sequence for its X.Y line — no skipped or superseded version.
if git rev-parse -q --verify "refs/tags/v${target}" >/dev/null; then
  echo "error: tag 'v${target}' already exists — refusing to recompute an existing release" >&2
  exit 1
fi

target_xy=$(grep -oE '^[0-9]+\.[0-9]+' <<<"$target")
while IFS= read -r existing_tag; do
  [[ -z "$existing_tag" ]] && continue
  existing="${existing_tag#v}"
  if [[ "$(./bin/semver compare "$existing" "$target")" == "1" ]]; then
    echo "error: existing tag '${existing_tag}' is already ahead of computed target 'v${target}' — this candidate would be superseded or create a version gap" >&2
    exit 1
  fi
done < <(git tag -l "v${target_xy}.*")

echo "$target"
