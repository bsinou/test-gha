# Repo settings for testing the release process

Recap of the manual GitHub settings applied to this repo, in the order they were
made, so the setup can be reproduced (or torn down) elsewhere.

## 1. Allow Actions to create pull requests

`Settings → Actions → General → Workflow permissions`

- **Allow GitHub Actions to create and approve pull requests**: enabled.

Without this, `prepare-release.yml`'s `gh pr create` step fails with
`GitHub Actions is not permitted to create or approve pull requests`.

Equivalent API state:

```json
{ "default_workflow_permissions": "read", "can_approve_pull_request_reviews": true }
```

(`default_workflow_permissions` was left at `read` — the workflows request
`contents: write` / `pull-requests: write` explicitly per job instead of
relying on a broad default.)

## 2. Branch ruleset on `main`

`Settings → Rules → Rulesets → "Require Approval before Release"`

- **Target branches**: default branch (`main`).
- **Enforcement**: Active.
- **Rules enabled**:
  - Require a pull request before merging.
  - Require approvals: **1**.
  - Allowed merge methods: **merge commit only** (squash/rebase disabled).
- **Not enabled** (left off on purpose / not yet configured):
  - Dismiss stale approvals on new commits.
  - Require status checks to pass.
- **Bypass**: the repo owner has an "always" bypass entry, so direct pushes
  from that account still work; every other push must go through a PR.

This is what makes `publish-release.yml`'s "true merge commit" check
(exactly 2 parents) always hold — squash/rebase merges are rejected by the
ruleset before they can ever reach that workflow.

## 3. Allow auto-merge

`Settings → General → Pull Requests`

- **Allow auto-merge**: enabled.

Combined with the ruleset above, this lets `prepare-release.yml` call
`gh pr merge --auto --merge` right after opening the PR: the merge is queued
and completes by itself as soon as the required approval is given, which in
turn fires `publish-release.yml`'s `pull_request: closed` trigger.

## Net effect on the operator flow

With all three settings in place, releasing is:

1. `gh workflow run prepare-release.yml -f type=... -f source_ref=... -f version_bump=...`
2. Approve the PR it opens.
3. Nothing else — auto-merge merges the PR, which triggers `publish-release.yml`
   automatically.

`publish-release.yml` also keeps a manual `workflow_dispatch` (with a
`pr_number` input) as a fallback if the automatic trigger is ever skipped.
