# Release process

This repo implements a test harness for the two-phase release process used by
wire-team-settings (ADR 0006): **PREPARE → (review) → PUBLISH**. Docker/Helm
steps are mocked to log-only here since there's no real registry or S3 to
push to — everything else (versioning, branching, git history, tags,
GitHub releases) is real.

## Overview

```
operator                prepare-release.yml              publish-release.yml
  |                             |                                 |
  |-- dispatch(source_branch, --->|                              |
  |     type, version_bump)    |                                 |
  |                             |-- compute version               |
  |                             |-- generate changelog            |
  |                             |-- commit (changelog + manifest) |
  |                             |-- open PR, enable auto-merge    |
  |                             |                                 |
  |-- approve PR -------------->|                                 |
  |                        (auto-merge completes) ---(pull_request:closed)-->|
  |                                                                |-- verify merge commit
  |                                                                |-- verify manifest
  |                                                                |-- tag vX.Y.Z
  |                                                                |-- create release/X.Y (first GA of a minor)
  |                                                                |-- create GitHub release (+ manifest asset)
```

One approval — on the `pre-release/vX.Y.Z` PR — is the only manual step.
Everything else is automatic.

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
4. **Create prepare branch** — `pre-release/vX.Y.Z`, branched from
   `source_commit` (not from whatever `source_branch`'s tip has drifted to
   by this point).
5. **Generate changelog** — `bin/generate-release-changelog.js` (real script,
   copied from wire-team-settings, using the `generate-changelog` npm
   package) writes `CHANGELOG.md` for the range `from_tag...source_commit`.
6. **Build / push Docker / package Helm** — mocked; each logs what it would
   have done and produces a deterministic fake digest/sha256 so the manifest
   still has realistic-looking values to verify later.
7. **Write release manifest + commit** — `release-manifest.json` (version,
   type, source_branch, source_commit, mocked Docker/Helm coordinates, the
   `prepare_run_id`) is written, and `CHANGELOG.md` + `release-manifest.json`
   are committed together in a **single commit**: `chore(release): vX.Y.Z`.
8. **Push prepare branch**, **open PR** (`pre-release/vX.Y.Z` → `source_branch`),
   **enable auto-merge** (`gh pr merge --auto --merge`).

The PR sits queued until a human approves it (the `main` branch ruleset
requires 1 approval and only allows merge commits — see
`docs/setup/repo-settings.md`). Once approved, GitHub completes the merge on
its own.

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
captured before the prepare branch, changelog, or manifest commit exist.
Everything the workflow does afterwards happens *on top of* this commit, so
by the time the PR is open, the prepare branch's tip and the eventual merge
commit are different SHAs from it.

This matters because:
- It's what actually gets **tagged**: `publish-release.yml` runs
  `git tag "v${target}" "$source_commit"` — the release tag points at the
  real reviewed code, not at the changelog/manifest bookkeeping commit.
- It's the **integrity anchor** for publish-time verification:
  `publish-release.yml` checks
  `git merge-base --is-ancestor "$source_commit" "$merge_sha"` — i.e. the
  manifest's recorded source commit really is an ancestor of the PR's merge
  commit — before trusting anything else in the manifest.

## Phase 2 — `publish-release.yml`

Triggered two ways:
- **Automatically**, via `pull_request: closed` — but only acts when
  `github.event.pull_request.merged == true` and the head ref starts with
  `pre-release/` (see `resolve-pr`'s `if:`). This is the normal path.
- **Manually**, via `workflow_dispatch` with a `pr_number` input — a fallback
  for when the automatic trigger is skipped (e.g. the PAT/bypass setup isn't
  in place; see `docs/setup/repo-settings.md` section 5).

### Job 1 — `resolve-pr`

Looks up the PR (`gh pr view`) and outputs its `state`, `merge_sha`,
`base_ref`, `pr_number`. The `publish` job only runs `if:` this state is
`MERGED`.

### Job 2 — `publish`

1. **Checkout base ref** (`source_branch`, full history).
2. **Verify merge is a true merge commit** — exactly 2 parents. Squash/rebase
   merges (1 parent) are rejected; combined with the branch ruleset only
   allowing merge commits, this should never actually trigger, but the
   workflow checks it independently rather than trusting the ruleset alone.
3. **Read and verify release manifest** — reads `release-manifest.json` out
   of the merge commit (`git show "$merge_sha:release-manifest.json"`), then
   confirms `source_commit` is an ancestor of `merge_sha` (see above). All
   manifest fields become step outputs.
4. **Promote Docker image / Helm chart** — mocked; logs what it would have
   verified/promoted (candidate digest/sha256 match, no-rebuild promotion).
5. **Create immutable release tag** — `vX.Y.Z` at `source_commit`. Idempotent:
   an existing tag at the expected commit is a no-op; at a different commit
   is a hard failure (refuses to move a release tag).
6. **Create or verify `release/X.Y`** — only for `type=ga` where the version
   is `X.Y.0` (first GA of a new minor). Creates the maintenance branch at
   `source_commit`, or verifies an existing one matches.
7. **Create GitHub release** — title `vX.Y.Z`, notes from the merge commit's
   `CHANGELOG.md`, marked `--prerelease` for non-`ga` types. The release
   manifest is attached as a release **asset**
   (`release-manifest-vX.Y.Z.json`) rather than committed to `source_branch`
   — the tag + release already are the durable record, so there's no need
   for a second protected-branch PR just to archive the manifest.

## Branch naming

Temporary branches created during the process use the `pre-release/` prefix
(`pre-release/vX.Y.Z`), auto-deleted after merge (repo setting, see
`docs/setup/repo-settings.md`).

## See also

`docs/setup/repo-settings.md` — the manual GitHub settings (branch ruleset,
auto-merge, PAT for the bot identity) this process depends on, and why each
one is needed.
