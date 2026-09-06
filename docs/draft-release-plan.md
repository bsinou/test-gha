# Plan: replace the release PR with a draft GitHub Release

Implementation plan for `bsinou/test-gha`. The `PREPARED` state moves from a
`pre-release/vX.Y.Z` branch + PR to a **draft GitHub Release**. No commit, no
branch: the changelog and the release manifest belong to the release, not to
the code.

This is the test harness. Once validated here, the same change is ported to
`wire-team-settings` — see that repo's `docs/qa/draft-release-plan.md`.

---

## 1. Design summary

| Was (PR-based) | Becomes (draft-release-based) |
| --- | --- |
| `pre-release/vV` branch | *(gone)* |
| Commit `chore(release): vV` (CHANGELOG + manifest) | *(gone)* |
| `CHANGELOG.md` in the repo | Draft release **body** (notes) |
| `release-manifest.json` in the repo | Draft release **asset** |
| PR = validation surface | Draft release = validation surface |
| PR must be a merge commit (2 parents) | *(gone — no commit, no merge check)* |
| Approve PR → auto-merge → `pull_request: closed` | Click **Publish release** on the draft → `release: published` |
| `publish-release` input `pr_number` | `publish-release` input `version` (fallback path only) |
| `git show merge_sha:release-manifest.json` | download the draft's asset |
| `gh release create` at publish time | draft already exists; publish flips `draft=false` |

**Operator flow is still exactly two actions**, and the second one is still a
single click:

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

The candidate's binding to a commit moves from *"manifest committed on a
branch, verified as an ancestor of the merge commit"* to
***`manifest.source_commit` == the draft's `target_commitish`, and still an
ancestor of `source_branch`***.

---

## 2. Two GitHub API gotchas that shape the implementation

**2.1 — `GET /repos/{o}/{r}/releases/tags/{tag}` does not return drafts.**
A draft has no tag ref yet, so `gh release view v$X` and
`gh release download v$X` are unreliable for drafts. Always list and filter:

```bash
gh api --paginate "/repos/${GITHUB_REPOSITORY}/releases" \
  --jq "[.[] | select(.tag_name == \"v${target}\")]"
```

Likewise, a draft asset's `browser_download_url` 404s — use the asset's API
`url` with `Accept: application/octet-stream`.

**2.2 — GitHub allows *multiple* drafts with the same `tag_name`.**
`gh release create --draft` will silently create a duplicate. Both workflows
must list-and-filter and fail loudly when the match count is `> 1`.

**2.3 — Publishing a draft creates the tag.** When the draft is published
(UI click or API `PATCH draft=false`), GitHub creates `refs/tags/vV` at the
release's `target_commitish`. So on the `release: published` path the tag
already exists when `publish-release` runs — the existing "create immutable
release tag" step handles this unchanged, since its idempotent branch already
accepts *"tag exists at the expected commit"*.

**2.4 — Anti-recursion is now working *for* us.** `publish-release`'s
`draft=false` flip (fallback path only) **must** use `github.token`: events
caused by `GITHUB_TOKEN` never start workflow runs, so the flip cannot
re-trigger `publish-release` on itself. Using `RELEASE_BOT_TOKEN` there would
create an infinite loop. See §6.

---

## 3. `.github/workflows/prepare-release.yml`

### 3.1 Header / permissions / concurrency

- Update the top comment: candidate is published as a **draft GitHub Release**;
  no branch, no commit, no PR.
- Job `permissions:` → **`contents: write` only**. Drop `pull-requests: write`.
- Add concurrency, to shrink the duplicate-draft race window:

  ```yaml
  concurrency:
    group: prepare-release-${{ inputs.source_branch }}
    cancel-in-progress: false
  ```

### 3.2 Rewrite `Fail if release PR already exists` (lines 81–113)

Same position in the file (right after `Compute target version`, before any
build work) and **keep the existing `::error title=` + `$GITHUB_STEP_SUMMARY`
+ ➡️ link presentation** — just change what it looks up.

```yaml
      - name: Fail if a release already exists for this version
        env:
          GH_TOKEN: ${{ github.token }}
          TARGET: ${{ steps.version.outputs.target }}
        run: |
          set -euo pipefail

          # /releases/tags/<tag> does not return drafts — must list and filter.
          matches="$(
            gh api --paginate "/repos/${{ github.repository }}/releases" \
              --jq "[.[] | select(.tag_name == \"v${TARGET}\") | {url: .html_url, draft: .draft}]"
          )"
          count="$(jq 'length' <<<"$matches")"

          if [[ "$count" -gt 0 ]]; then
            url="$(jq -r '.[0].url' <<<"$matches")"
            state="$(jq -r 'if .[0].draft then "draft" else "published" end' <<<"$matches")"

            echo "::error title=Release already exists::A ${state} release already exists for v${TARGET}: ${url}"

            {
              echo "### Release already in progress"
              echo ""
              echo "A ${state} release already exists for \`v${TARGET}\`:"
              echo ""
              echo "➡️ [v${TARGET}](${url})"
              echo ""
              echo "Delete the draft to re-prepare, or publish it to complete the release."
            } >> "$GITHUB_STEP_SUMMARY"

            exit 1
          fi

          echo "No existing release found for v${TARGET}."
```

### 3.3 Delete these steps entirely

| Step | Current lines |
| --- | --- |
| `Configure git` | 115–118 |
| `Create prepare branch` | 120–121 |
| `Push prepare branch` | 185–186 |
| `Create pull request` | 188–204 |
| `Enable auto-merge` | 206–209 |

`steps.source.outputs.sha` is unaffected — the checkout is already at that
commit, we simply stop branching from it.

### 3.4 `Generate changelog` (line 131) — copy the output to `/tmp`

`bin/generate-release-changelog.js` hardcodes `../CHANGELOG.md`. Leave the
script alone; just stop committing the result:

```yaml
      - name: Generate changelog
        run: |
          set -euo pipefail
          node bin/generate-release-changelog.js "${{ steps.version.outputs.from_tag }}" "${{ steps.source.outputs.sha }}"
          cp CHANGELOG.md /tmp/release-notes.md
```

### 3.5 `Write release manifest` (lines 165–183) — write to `/tmp`, no commit

Keep every JSON key exactly as-is (`publish-release` reads them). Write
straight to `/tmp` so the worktree stays clean, and drop the git lines:

```diff
-          cat > release-manifest.json <<JSON
+          cat > /tmp/release-manifest.json <<JSON
           {
             "version": "${{ steps.version.outputs.target }}",
             ...
             "prepare_run_id": "${{ github.run_id }}"
           }
           JSON
-          git add CHANGELOG.md release-manifest.json
-          git commit -m "chore(release): v${{ steps.version.outputs.target }}"
+          cat /tmp/release-manifest.json
```

### 3.6 New final step — create the draft release

Replaces `Create pull request` + `Enable auto-merge`.

```yaml
      - name: Create draft release
        env:
          GH_TOKEN: ${{ github.token }}
          TARGET: ${{ steps.version.outputs.target }}
        run: |
          set -euo pipefail

          # Re-check right before creating: GitHub permits multiple drafts with
          # the same tag_name, so create-without-check can silently duplicate.
          count="$(gh api --paginate "/repos/${{ github.repository }}/releases" \
            --jq "[.[] | select(.tag_name == \"v${TARGET}\")] | length")"
          if [[ "$count" -ne 0 ]]; then
            echo "::error title=Race detected::A release for v${TARGET} appeared during this run — aborting"
            exit 1
          fi

          {
            echo "Release candidate for \`${TARGET}\` (\`${{ inputs.type }}\`) from \`${{ inputs.source_branch }}\` @ \`${{ steps.source.outputs.sha }}\`."
            echo ""
            echo "[MOCK] Candidate artifacts are simulated in this test repo (no real registry/S3 push), recorded in the \`release-manifest.json\` asset:"
            echo "- Docker: \`${{ steps.docker.outputs.repository }}:${{ steps.docker.outputs.candidate_tag }}\` (\`${{ steps.docker.outputs.digest }}\`)"
            echo "- Helm: \`${{ steps.helm.outputs.candidate_path }}\` (sha256 \`${{ steps.helm.outputs.sha256 }}\`)"
            echo ""
            echo "**Review this draft, then click _Publish release_** — that creates the tag \`v${TARGET}\` at \`${{ steps.source.outputs.sha }}\` and runs \`publish-release\`, which promotes the artifacts above without rebuilding. To abandon this candidate, delete this draft."
            echo ""
            echo "---"
            echo ""
            cat /tmp/release-notes.md
          } > /tmp/release-body.md

          args=(--draft
                --target "${{ steps.source.outputs.sha }}"
                --title "v${TARGET}"
                --notes-file /tmp/release-body.md)
          if [[ "${{ inputs.type }}" != "ga" ]]; then args+=(--prerelease); fi

          gh release create "v${TARGET}" "${args[@]}" /tmp/release-manifest.json

          url="$(gh api --paginate "/repos/${{ github.repository }}/releases" \
            --jq "[.[] | select(.tag_name == \"v${TARGET}\")][0].html_url")"

          {
            echo "### Draft release ready"
            echo ""
            echo "➡️ [v${TARGET}](${url})"
            echo ""
            echo "Review it and click **Publish release** to complete the release."
          } >> "$GITHUB_STEP_SUMMARY"
```

Notes:

- `--target <sha>` is **essential**: it binds the draft to the exact candidate
  commit (otherwise GitHub defaults `target_commitish` to the default branch),
  it is what GitHub tags on publish, and it is `publish-release`'s independent
  cross-check against the manifest.
- `--draft` creates **no tag ref** — preparation still must not create the
  release tag (ADR 0006).
- `github.token` is enough (`contents: write`). Draft creation emits no release
  event, so no bot-identity PAT is needed here.
- Asset name will be `release-manifest.json` (from the filename).
  `publish-release` filters on that exact name.
- `--notes-file` bodies are capped around 125 000 characters; a huge changelog
  would 422. Not a concern in this repo, but worth knowing.

---

## 4. `.github/workflows/publish-release.yml`

### 4.1 Triggers

Keeps the same dual shape as today — one automatic path, one manual fallback:

```yaml
on:
  release:
    types: [published]
  workflow_dispatch:
    inputs:
      version:
        description: 'Version to publish, e.g. 1.0.1 or 1.1.0-rc01 (leading v optional). Manual fallback — normally the draft is published from the Releases page.'
        type: string
        required: true
```

The two paths differ only in *when the tag/release becomes public*:

- **`release: published`** (normal) — a human clicked Publish. GitHub has
  already created the tag and made the release public; the workflow verifies
  and promotes. This is the direct analogue of the old
  approve → auto-merge → `pull_request: closed` chain.
- **`workflow_dispatch`** (fallback) — the release is still a draft. The
  workflow verifies and promotes *first*, creates the tag, and flips
  `draft=false` last. Safer ordering; use it if a promotion is risky.

### 4.2 Replace job `resolve-pr` with `resolve-release`

```yaml
  resolve-release:
    name: Resolve release
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    outputs:
      target:             # version without leading v
      release_id:         # numeric id — address the release by id, never by tag
      is_draft:           # 'true' | 'false'
      target_commitish:
      manifest_asset_url: # API url, not browser_download_url
```

Steps:

1. Derive `target`:
   - `release` event → `${{ github.event.release.tag_name }}`, strip leading `v`
   - `workflow_dispatch` → `${{ inputs.version }}`, strip leading `v`
2. List releases, filter `tag_name == "v$target"`:
   - `0` matches → fail: *"no prepared candidate for v$target — run
     prepare-release first."*
   - `>1` matches → fail, listing every `html_url`: *"multiple releases share
     tag v$target — resolve manually."*
3. Emit `.id`, `.draft`, `.target_commitish`, and
   `.assets[] | select(.name == "release-manifest.json") | .url`.
   Fail with a clear message if that asset is absent — *"release v$target has
   no release-manifest.json asset; it was not produced by prepare-release."*

There is **no `state == 'MERGED'` gate anymore** — the equivalent gate is
"a release with a manifest asset exists".

### 4.3 Job `publish`

`needs: resolve-release`, `permissions: contents: write`.

Order matters, because we cannot know which branch to check out until the
manifest is read, and `actions/checkout` wipes the workdir (but not `/tmp`).

1. **Download the manifest** — before checkout:

   ```yaml
       - name: Download release manifest
         env:
           GH_TOKEN: ${{ github.token }}
         run: |
           set -euo pipefail
           gh api -H "Accept: application/octet-stream" \
             "${{ needs.resolve-release.outputs.manifest_asset_url }}" \
             > /tmp/release-manifest.json
           jq . /tmp/release-manifest.json
   ```

2. **Read and verify release manifest** — replaces lines 101–119. Same
   `for key in …` output loop (note this repo's manifest uses `source_branch`,
   not `source_ref`), plus two new assertions:
   - `manifest.version == resolve-release.outputs.target` — the release we
     resolved really is the one the manifest describes;
   - `manifest.source_commit == resolve-release.outputs.target_commitish` — the
     draft was not retargeted after preparation, and the tag GitHub creates on
     publish will land on the manifest's commit.

3. **Checkout** `ref: ${{ steps.manifest.outputs.source_branch }}`,
   `fetch-depth: 0`, `token: ${{ github.token }}` — replaces
   `Checkout base ref`.

4. **Verify the candidate is not stale** — replaces
   `Verify merge is a true merge commit` (lines 75–99) entirely:

   ```yaml
       - name: Verify candidate is still on its source branch
         run: |
           set -euo pipefail
           source_commit="${{ steps.manifest.outputs.source_commit }}"
           source_branch="${{ steps.manifest.outputs.source_branch }}"
           if ! git merge-base --is-ancestor "$source_commit" "origin/${source_branch}"; then
             echo "::error title=Stale candidate::source_commit ${source_commit} is no longer an ancestor of ${source_branch} — the branch was rewritten since preparation. Delete this release and re-run prepare-release."
             exit 1
           fi
           echo "Candidate ${source_commit} is still reachable from ${source_branch}."
   ```

5. **Promote Docker / Helm (mocked)** — unchanged (lines 121–140).

6. **Create immutable release tag** — **unchanged** (lines 142–160). It already
   handles both paths correctly:
   - `release: published` path → GitHub created the tag; the step's
     "exists at the expected commit" branch logs a no-op. It also catches the
     pathological case where the tag landed somewhere unexpected.
   - `workflow_dispatch` path → tag does not exist; the step creates and
     pushes it.

   > One caveat to verify during testing: on the `release: published` path the
   > checkout may predate GitHub's tag creation. If the step reports "tag does
   > not exist" and then fails to push, add `git fetch --tags --force origin`
   > as the first line of the step.

7. **Create or verify `release/X.Y` for first GA of a new minor** — unchanged
   (lines 162–185).

8. **Replace `Create GitHub release` (lines 187–206) with `Publish draft release`:**

   ```yaml
       - name: Publish draft release
         env:
           # Must be github.token: the resulting release event must NOT re-trigger
           # this workflow (GITHUB_TOKEN-caused events never start workflow runs).
           GH_TOKEN: ${{ github.token }}
         run: |
           set -euo pipefail
           if [[ "${{ needs.resolve-release.outputs.is_draft }}" != "true" ]]; then
             echo "Release v${{ steps.manifest.outputs.version }} is already published — treating as already completed."
             exit 0
           fi
           gh api --method PATCH \
             "/repos/${{ github.repository }}/releases/${{ needs.resolve-release.outputs.release_id }}" \
             -F draft=false --jq '.html_url'
   ```

   The `--prerelease` flag was already set at draft-creation time, so the
   `type != ga` branching disappears from this workflow.

### 4.4 Optional — rollback on the `release: published` path

On that path the release goes public *before* verification runs, so a failed
verification leaves a published release for an unpromoted artifact. In this
test repo everything downstream is mocked, but it is worth testing the
recovery step:

```yaml
      - name: Re-draft release on failure
        if: failure() && github.event_name == 'release'
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          target="${{ needs.resolve-release.outputs.target }}"
          gh api --method PATCH \
            "/repos/${{ github.repository }}/releases/${{ needs.resolve-release.outputs.release_id }}" \
            -F draft=true >/dev/null
          git push --delete origin "v${target}" || true
          echo "::error title=Publication failed::Release v${target} was reverted to draft and its tag deleted. Fix the cause and publish again."
```

Deleting a tag is not something to do lightly in the real repo — flag it as a
deliberate decision when porting.

---

## 5. Repository file cleanup

The PR-based flow left build products committed at the repo root. They now
belong to the release:

```bash
git rm CHANGELOG.md release-manifest.json
```

and add to `.gitignore`:

```
node_modules/
CHANGELOG.md
release-manifest.json
```

(The `.gitignore` entries are belt-and-braces — with §3.5 writing the manifest
to `/tmp`, only `CHANGELOG.md` is ever created in the worktree.)

Also worth cleaning while you're there: the stale
`origin/prepare/v0.1.1-beta01` branch, left over from before the
`pre-release/` rename.

---

## 6. Repo settings — `docs/setup/repo-settings.md`

Almost every setting in that doc existed to make the PR mechanism work. Rewrite
it:

| Section | Action |
| --- | --- |
| **1. Allow Actions to create pull requests** | No longer needed. Nothing calls `gh pr create`. Can be turned off. |
| **2. Branch ruleset on `main`** | **Keep the ruleset** (it still protects `main` from direct pushes), but delete the paragraph claiming it guarantees the "true merge commit" check — that check is gone. Note that the ruleset **no longer gates releases at all**: `prepare-release` and `publish-release` never push to `main`. |
| **3. Allow auto-merge** | No longer needed. |
| **4. Delete head branches automatically** | Moot for the release process — no head branches are created. Harmless to leave on. |
| **5. PAT `RELEASE_BOT_TOKEN`** | **No longer needed.** The old problem was that a `GITHUB_TOKEN`-driven auto-merge could not trigger `publish-release`. Now the trigger is a *human* clicking Publish, which always fires. Delete the secret and the section — but first read the new §7 below, because the anti-recursion rule is now load-bearing in the opposite direction. |

**New section to add — "Who can publish a release".** The approval gate moved.
It used to be *"1 PR approval, enforced by the `main` ruleset"*; it is now
*"who can publish a draft release"*, i.e. anyone with `write` on the repo.
If you want a stronger gate, add a **tag ruleset** on `v*`
(`Settings → Rules → Rulesets → Target: tags → v*`) restricting tag creation to
a named set of actors — note that publishing a draft *creates* the tag, so such
a ruleset will block the publish action itself for non-bypassed users, which is
exactly the desired behaviour.

**New section to add — "Anti-recursion".** `publish-release`'s
`draft=false` flip must use `github.token`. Using `RELEASE_BOT_TOKEN` there
would emit a `release: published` event that re-triggers `publish-release` in a
loop. This is the *same* GitHub rule as old §5, now relied on for the opposite
effect.

---

## 7. Docs — `docs/release-process.md`

| Section | Change |
| --- | --- |
| Overview diagram (lines 11–31) | Replace with the diagram in §1 above. Replace "One approval — on the `pre-release/vX.Y.Z` PR" with "One click — **Publish release** on the draft". |
| Phase 1 step list (47–80) | Delete step 4 (create prepare branch). Step 5 (changelog) → written to the release body, not committed. Step 7 → manifest written to `/tmp` and attached as a release asset; **no commit**. Step 8 → replaced by "create draft release (`--draft --target <source_commit>`, notes = changelog, asset = manifest, `--prerelease` for non-`ga`)". Drop the trailing paragraph about the PR sitting queued for approval. |
| `What is source_commit?` (108–128) | Keep the section — it gets *simpler*. The "everything happens on top of this commit / different SHAs" framing goes away entirely: there is now no commit but `source_commit`. Rewrite the two bullets: it is what gets tagged (GitHub tags the draft's `target_commitish`, which *is* `source_commit`), and it is the integrity anchor — publish verifies `manifest.source_commit == draft.target_commitish` **and** that it is still an ancestor of `source_branch`, instead of the old ancestor-of-merge-commit check. |
| Phase 2 triggers (130–138) | Rewrite per §4.1: automatic via `release: published`, manual fallback via `workflow_dispatch` with a `version` input. |
| Job 1 (140–144) | `resolve-pr` → `resolve-release`, per §4.2. Mention the two API gotchas (drafts absent from `/releases/tags/…`; duplicate `tag_name` drafts possible). |
| Job 2 (146–170) | Step 2 (merge-commit check) → replaced by the staleness check. Step 3 → manifest downloaded from the release asset, not `git show`. Step 7 → the release already exists; publish flips it out of draft (no-op on the automatic path). |
| Branch naming (172–176) | Rewrite: **the release process no longer creates any branch**, except `release/X.Y` on the first GA of a new minor. |

---

## 8. Verification

1. **Lint:** `actionlint .github/workflows/*.yml`.
2. **Prepare, happy path:** dispatch `prepare-release` with
   `source_branch=main`, `type=rc`. Assert:
   - a draft release appears with the manifest asset attached and the changelog
     in the body;
   - `git ls-remote --heads origin | grep pre-release` → empty;
   - `git ls-remote --tags origin | grep "v<target>"` → empty;
   - `git log origin/main -1` unchanged (no new commit).
3. **Collision path:** re-dispatch with identical inputs → fails in under a
   minute, with the draft's URL in both the annotation and the step summary.
4. **Publish, automatic path:** click **Publish release** on the draft →
   `publish-release` fires on `release: published`, all steps green, tag
   `v<target>` exists at `source_commit`.
5. **Publish, fallback path:** prepare a second candidate, leave the draft
   alone, dispatch `publish-release` with `version=<target>` → verifies,
   promotes, creates the tag, then flips the draft to published.
6. **Idempotency:** re-dispatch `publish-release` for an already-published
   version → every step reports "already completed", exit 0.
7. **Duplicate-draft guard:** create a second draft with the same tag by hand
   (`gh api --method POST /repos/bsinou/test-gha/releases -f tag_name=vX -F draft=true`),
   then dispatch `publish-release` → must fail with "multiple releases share
   tag".
8. **Staleness guard:** prepare a candidate, then force-push `main` to drop
   that commit, then publish → must fail with the stale-candidate error.
9. **Minor GA path:** run a full `type=ga`, `version_bump=minor` cycle and
   confirm `release/X.Y` is still created at `source_commit`.

---

## 9. Open decisions

1. **Automatic path ordering.** `release: published` makes the release public
   before verification runs (§4.4). Options: accept it plus the re-draft
   rollback step; or drop the `release: published` trigger and make
   `workflow_dispatch` the only path (safe ordering, but the operator's second
   action moves from one UI click to a workflow dispatch). **Recommended:**
   keep both, with the rollback step — it preserves today's one-click
   ergonomics and is exactly the thing this test harness exists to exercise.
2. **Release-publish gate.** With the PR gone, the "1 approval" requirement no
   longer applies to releases. **Recommended:** add a tag ruleset on `v*` (§6)
   so publication is restricted to named actors.
3. **Manifest asset name.** Plan uses `release-manifest.json` (publish filters
   on that exact name). The old flow produced `release-manifest-vX.Y.Z.json` on
   the published release. Switching to the unversioned name is simpler; say so
   if you'd rather keep the versioned one (prepare would need
   `cp /tmp/release-manifest.json /tmp/release-manifest-v$TARGET.json` and
   publish would filter on a prefix).
4. **`RELEASE_BOT_TOKEN`.** Becomes unused. Delete the secret, or keep it
   around for parity with wire-team-settings' `OTTO_THE_BOT_GH_TOKEN`.
