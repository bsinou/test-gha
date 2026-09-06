# Repo settings for testing the release process

Recap of the manual GitHub settings applied to this repo, so the setup can be
reproduced (or torn down) elsewhere.

The release process moved from a PR-based `PREPARED` state to a draft GitHub
Release. Most of the settings below existed only to make the PR mechanism
work and are no longer needed — kept here, marked obsolete, for anyone
retracing the repo's history.

## Still needed

### Branch ruleset on `main`

`Settings → Rules → Rulesets → "Require Approval before Release"`

- **Target branches**: default branch (`main`).
- **Enforcement**: Active.
- **Rules enabled**:
  - Require a pull request before merging.
  - Require approvals: **1**.
  - Allowed merge methods: **merge commit only** (squash/rebase disabled).
- **Bypass**: the repo owner has an "always" bypass entry, so direct pushes
  from that account still work; every other push must go through a PR.

This still protects `main` from unreviewed direct pushes for ordinary
development. It **no longer gates releases**: neither `prepare-release` nor
`publish-release` pushes to `main` — the only pushes they make are the
release tag itself and, on the first GA of a new minor, a `release/X.Y`
branch.

### Delete head branches automatically after merge

`Settings → General → Pull Requests`

- **Automatically delete head branches**: enabled.

Repo hygiene for ordinary development PRs — nothing to do with the release
process, which no longer creates any head branch.

## Who can publish a release

The approval gate moved. It used to be *"1 PR approval, enforced by the
`main` ruleset"*; now it's *"who can flip a draft release to published"*,
i.e. by default anyone with `write` access to the repo, since publishing a
draft is what creates the tag.

If you want a comparable gate, add a **tag ruleset**:

`Settings → Rules → Rulesets → New ruleset → Target: tags → v*`

restricting tag creation to a named set of actors or teams. Since publishing
a draft release is what creates its tag, such a ruleset blocks the publish
action itself for anyone not on the allow-list (bypass entries excepted) —
which is exactly the desired effect.

## Anti-recursion

`publish-release.yml`'s final "flip the draft to published" step must
authenticate with `github.token`, never a PAT. Events caused by the default
`GITHUB_TOKEN` — including the `release: published` event from that
API call — never start other workflow runs. Using a PAT there instead would
make the flip re-trigger `publish-release` on itself, looping.

This is the same GitHub anti-recursion rule that motivated the (now removed)
PAT setup below — previously worked around because it *blocked* a trigger we
wanted; now relied on directly because it *blocks* a trigger we don't want.

## No longer needed (historical)

These were required for the old PR-based flow and can be safely turned off.

### ~~Allow Actions to create pull requests~~

`Settings → Actions → General → Workflow permissions`

Was needed for `prepare-release.yml`'s `gh pr create` step. Nothing in the
current workflows creates a pull request.

### ~~Allow auto-merge~~

`Settings → General → Pull Requests`

Was needed for `prepare-release.yml`'s `gh pr merge --auto --merge` step,
which no longer exists.

### ~~PAT for the auto-merge bot identity (`RELEASE_BOT_TOKEN`)~~

**The original problem:** `prepare-release.yml` used to call `gh pr create` /
`gh pr merge --auto` with the default `github.token`. GitHub attributes any
event caused by that token — including a merge completed later by
auto-merge — to `github-actions[bot]`, and per GitHub's anti-recursion rule,
events triggered by the default `GITHUB_TOKEN` never start other workflow
runs. Result: the merge happened, but `publish-release.yml`'s
`pull_request: closed` trigger silently never fired — this is the same
reason wire-team-settings' real workflows use `secrets.OTTO_THE_BOT_GH_TOKEN`
instead of `github.token` for that kind of step.

**The fix at the time** was a classic PAT for a dedicated bot account
(`bsinou-agent`, `repo` scope — fine-grained tokens didn't support the
required `gh pr merge` mutations), stored as `RELEASE_BOT_TOKEN`.

**Why it's gone:** there is no longer a PR or an auto-merge to attribute.
The trigger for `publish-release` is now a human clicking **Publish
release**, which always fires the `release: published` event regardless of
token identity. `RELEASE_BOT_TOKEN` is unused; delete the secret (or keep it
around for parity with wire-team-settings' `OTTO_THE_BOT_GH_TOKEN`, if this
repo later grows a step that genuinely needs a bot identity).

## Net effect on the operator flow

With the current settings, releasing is:

1. `gh workflow run prepare-release.yml -f type=... -f source_branch=... -f version_bump=...`
2. Review the draft release it creates, then click **Publish release**.
3. Nothing else — publishing the draft triggers `publish-release.yml`
   automatically.

`publish-release.yml` also keeps a manual `workflow_dispatch` (with a
`version` input) as a fallback if the automatic trigger is ever skipped, or
if you'd rather verify and promote before the release goes public.
