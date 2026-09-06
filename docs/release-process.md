# Release process

This repo implements a test harness for the two-phase release process used by
wire-team-settings (ADR 0006): **PREPARE → (review) → PUBLISH**. Docker/Helm
steps are mocked to log-only here since there's no real registry or S3 to
push to — everything else (versioning, git history, tags, GitHub releases)
is real.

The `PREPARED` candidate is a **draft GitHub Release**: no branch, no commit.
The changelog is the release body and the release manifest is a release
asset — both belong to the release, not to the code.

## Overview

```
operator                prepare-release.yml              publish-release.yml
  |                             |                                 |
  |-- dispatch(source_branch, ->|                                 |
  |     type, version_bump)     |                                 |
  |                             |-- compute version               |
  |                             |-- fail if release v<V> exists   |
  |                             |-- generate changelog            |
  |                             |-- mock build / docker / helm    |
  |                             |-- create DRAFT release          |
  |                             |     body   = changelog          |
  |                             |     asset  = release-manifest   |
  |                             |     target = source_commit      |
  |                             |                                 |
  |-- review draft, click "Publish release" ---(release:published)->|
  |                                                                |-- download + verify manifest
  |                                                                |-- verify candidate not stale
  |                                                                |-- promote docker / helm (mock)
  |                                                                |-- verify/create tag vX.Y.Z
  |                                                                |-- create release/X.Y (first GA of a minor)
```

One click — **Publish release** on the draft — is the only manual step.
Everything else is automatic.

`publish-release` also accepts a manual `workflow_dispatch` (with a `version`
input) as a fallback if the automatic trigger is ever skipped, or if you'd
rather verify and promote *before* the release goes public (see
[Phase 2](#phase-2--publish-releaseyml) below).

## Phase 1 — `prepare-release.yml`

Triggered manually via `workflow_dispatch` with three inputs:

- `source_branch` — branch to release from (`main`, or a maintained
  `release/X.Y` line).
- `type` — release channel: `ga`, `alpha`, `beta`, `rc`.
- `version_bump` — `patch` / `minor` / `major`. Applies whenever promoting
  from a GA release, for any `type`. Ignored when the latest reachable
  release is already a pre-release (channel bump is fixed there — e.g.
  `alpha01` → `alpha02`, or `alpha01` → `beta01`), and ignored when promoting
  an existing pre-release to GA (the version is fixed by what's being
  promoted).

Steps, in order:

1. **Checkout** `source_branch`.
2. **Resolve source commit** — records `git rev-parse HEAD` as `source_commit`
   right after checkout, before anything else happens. This is the exact
   commit being released; see [`source_commit`](#what-is-source_commit)
   below for why it's tracked separately from everything that follows.
3. **Compute target version** — via `bin/compute-release-version.sh`
   (see [Version computation](#version-computation)). Also computes the
   changelog boundary tag (`from_tag`), which differs by `type`:
   - `ga` → since the last **GA-only** tag.
   - `alpha` / `beta` / `rc` → since the last **pre-release** tag of any
     channel, falling back to the last GA tag if this is the first
     pre-release of a new cycle.
4. **Fail if a release already exists** — lists releases and filters for
   `tag_name == "v<target>"` (drafts are not returned by the tag-lookup
   endpoint, so this must list-and-filter rather than look up the tag
   directly). If one is found — draft or published — the run fails with a
   link to it, in both the log annotation and the step summary.
5. **Generate changelog** — `bin/generate-release-changelog.js` (real script,
   copied from wire-team-settings, using the `generate-changelog` npm
   package) writes `CHANGELOG.md` for the range `from_tag...source_commit`,
   copied to `/tmp/release-notes.md` for later use as the release body.
6. **Build / push Docker / package Helm** — mocked; each logs what it would
   have done and produces a deterministic fake digest/sha256 so the manifest
   still has realistic-looking values to verify later.
7. **Write release manifest** — `release-manifest.json` (version, type,
   source_branch, source_commit, mocked Docker/Helm coordinates, the
   `prepare_run_id`) is written to `/tmp`. Nothing is committed.
8. **Create draft release** — tagged `vX.Y.Z`, `--target <source_commit>`,
   title `vX.Y.Z`, body = the changelog, with `release-manifest.json`
   attached as an asset. Marked `--prerelease` for any `type` other than
   `ga`. Re-checks for a race (another run creating the same tag
   concurrently) immediately before creating, since GitHub allows multiple
   drafts to share a `tag_name`.

The draft sits until a human reviews it and clicks **Publish release** (or
deletes it, to abandon the candidate).

### Version computation

`bin/compute-release-version.sh <source_branch> <type> <version_bump>`
(ported verbatim from wire-team-settings, self-contained with `bin/semver`):

- Finds the latest explicit release tag (GA or pre-release) reachable from
  `source_branch`. No explicit release reachable at all is a hard failure
  (bootstrapping is out of scope).
- **From a pre-release** (`X.Y.Z-channelNN`):
  - `type=ga` → promotes to `X.Y.Z` (the pre-release's own version; `version_bump`
    doesn't apply, there's nothing to bump from).
  - `type=<channel>` — same channel as latest → increments the counter
    (`alpha01` → `alpha02`). Higher channel → resets to `01`
    (`alpha01` → `beta01`). Lower channel is a hard failure (can't go
    backward in maturity for the same target version).
- **From a GA** (`X.Y.Z`): `version_bump` is applied first
  (`bump_version` on major/minor/patch), then `-<type>01` is appended if
  `type` isn't `ga`. E.g. `1.2.3` + `type=alpha` + `version_bump=major` →
  `2.0.0-alpha01`.
- **Release-line constraint**: if `source_branch` is `release/X.Y`, the
  computed target must stay within that `X.Y` line — a `minor`/`major` bump
  from a release line is rejected.
- **SemVer gap check**: refuses to compute a version that already exists as a
  tag, or that would be behind/equal to an existing tag in the same `X.Y`
  line (no skipped or superseded versions).

### What is `source_commit`?

```json
"source_commit": "${{ steps.source.outputs.sha }}"
```

It's `source_branch`'s tip **at the instant `prepare-release` started** —
captured before anything else happens. There is no intermediate commit
anymore: the changelog and manifest live in the release, not in the repo, so
`source_commit` is simply the commit the draft release targets.

This matters because:
- It's what actually gets **tagged**: publishing the draft makes GitHub
  create `refs/tags/vX.Y.Z` at the release's `target_commitish`, which *is*
  `source_commit` (set via `--target` at creation time). `publish-release`'s
  own tag-creation step is idempotent against this, in case the tag doesn't
  exist yet (the manual fallback path) or already does (the automatic path).
- It's the **integrity anchor** for publish-time verification:
  `publish-release.yml` checks that `manifest.source_commit` equals the
  release's `target_commitish` (the draft was not retargeted after
  preparation), and that it is still an ancestor of `source_branch` (the
  branch wasn't rewritten since preparation) — before trusting anything else
  in the manifest.

## Phase 2 — `publish-release.yml`

Triggered two ways:
- **Automatically**, via `release: published` — fires whenever any release
  transitions out of draft, including by a human clicking **Publish release**
  on the GitHub UI. This is the normal path. On this path the release (and
  its tag) are already public by the time the workflow starts verifying —
  see the rollback step below.
- **Manually**, via `workflow_dispatch` with a `version` input — a fallback
  for when the automatic trigger is skipped, or when you'd rather verify and
  promote *before* the release goes public. On this path the tag does not
  exist yet; the workflow creates it, then flips the draft to published last.

### Job 1 — `resolve-release`

Looks up the release by version (from the trigger event or the manual input),
listing and filtering rather than using the tag-lookup endpoint (drafts are
excluded from that endpoint). Fails if none is found, or if more than one
release shares the tag. Outputs `release_id`, `is_draft`, `target_commitish`,
and the manifest asset's API URL (its `browser_download_url` 404s for a
draft).

### Job 2 — `publish`

1. **Download the release manifest** from the asset — via the API URL with
   `Accept: application/octet-stream` (not `gh release download`, which
   doesn't work for drafts).
2. **Read and verify release manifest** — checks `manifest.version` matches
   the resolved release, and `manifest.source_commit` matches the release's
   `target_commitish` (see [`source_commit`](#what-is-source_commit) above).
   All manifest fields become step outputs.
3. **Checkout** `source_branch`, full history.
4. **Verify candidate is not stale** — confirms `source_commit` is still an
   ancestor of `source_branch`'s current tip. If the branch was force-pushed
   or rewritten since preparation, this fails with an explicit message rather
   than trusting the manifest blindly.
5. **Promote Docker image / Helm chart** — mocked; logs what it would have
   verified/promoted (candidate digest/sha256 match, no-rebuild promotion).
6. **Create immutable release tag** — `vX.Y.Z` at `source_commit`. Idempotent:
   an existing tag at the expected commit is a no-op; at a different commit
   is a hard failure (refuses to move a release tag). Always fetches tags
   first, since on the automatic path GitHub may have just created it.
7. **Create or verify `release/X.Y`** — only for `type=ga` where the version
   is `X.Y.0` (first GA of a new minor). Creates the maintenance branch at
   `source_commit`, or verifies an existing one matches.
8. **Publish draft release** — flips `draft=false` on the release (a no-op if
   it's already published, i.e. the automatic path). Uses `github.token`
   deliberately: a `release: published` event caused by `GITHUB_TOKEN` never
   starts another workflow run, so this cannot re-trigger `publish-release`
   on itself.
9. **Re-draft on failure** (automatic path only) — if any step above fails
   after the release was already public, this reverts the release to draft
   and deletes the tag it created, so a failed publication doesn't leave a
   half-promoted release sitting in the public releases list.

## Branch naming

The release process creates **no branch** for the release candidate itself —
only `release/X.Y`, and only for the first GA of a new minor line.

## See also

`docs/setup/repo-settings.md` — the manual GitHub settings this process
depends on, and why each one is (or isn't, anymore) needed.
