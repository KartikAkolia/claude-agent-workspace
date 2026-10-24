# ADR-001: Integrating CodeRabbit review into GitHub CI

Status: proposed
Date: 2026-10-24

Nothing here is wired up yet. This is a set of options with a recommendation, for Kartik to decide on. The YAML below is a scaffold to copy from once an option is picked, not a live config.

## Context

CodeRabbit is installed as a GitHub App on `KartikAkolia/claude-agent-workspace` and reviews pull requests on its own: PRs #13 and #14 both got a CodeRabbit summary comment, and the `coderabbit/review-…` head branch came from its workflow. CI is five independent GitHub Actions workflows: `gitleaks.yml`, plus `lint-bash.yml`, `lint-config.yml`, `lint-markdown.yml` and `lint-python.yml`, which are path-filtered. Nothing connects the two.

The gap is concrete. PR #13's head commit `0326b6f` still shows the `CodeRabbit` commit status as `pending`, and the PR merged at 11:48:43 UTC, about two minutes after that commit was made. So the merge went ahead without waiting for the review to finish, and nothing would have stopped it. Checked 2026-10-24 with `gh api repos/{owner}/{repo}/commits/0326b6f/statuses`. `master` has no branch protection and no rulesets (`gh api .../branches/master/protection` returns 404 and `.../rulesets` returns 0), so neither the lint checks nor CodeRabbit can block a merge today.

Constraints:

- **Direct pushes to `master` are normal here.** `6cf9892` and `fdc4256` went straight to `master`, with no PR. Any PR-only gate misses those commits. Hard-blocking direct pushes would change how Kartik works, so that's his call, not a default.
- **Keep CI runs down.** The standing preference is fewer Actions runs, and the existing workflows are already path-filtered for that reason. A gate that polls or runs on every push works against it.
- **Public repo.** Workflows triggered by `pull_request` from a fork get no secrets, so any option that needs a CodeRabbit API key only works on branches in this repo. That's fine, since all PRs here come from Kartik, but a fork PR would skip that check rather than fail it.
- **Five read-only reference clones** (`dwm-titus-main/`, `linutil-main/`, `titus-ai-main/`, `website-master/`, `winutil-main/`, per AGENTS.md non-negotiable 1) should never get review comments, just as the linters already skip them.
- **CodeRabbit behavior was checked against its current docs** through Context7 (`/websites/coderabbit_ai`) on 2026-10-24. Its status reporting has moved to check runs and progress reports, and the legacy commit status applies only while `reviews.review_progress` is off. Confirm the actual check or status name on the next PR before making it required.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A. Repo config plus a ruleset.** Add `.coderabbit.yaml` (request-changes workflow, path filters, path instructions, pre-merge checks), then add a `master` ruleset that requires the CodeRabbit check and the lint checks. | Uses no Actions minutes. Blocking happens on GitHub's side, so it's reliable. Reverting means deleting one file and one ruleset. | Covers PRs only, so direct pushes skip it unless the ruleset forbids them. Path-filtered lint workflows don't run on every PR, so they can't simply be required checks without an always-run wrapper. |
| **B. A gate job in Actions.** A small `coderabbit-gate.yml` workflow that runs on review events and fails while CodeRabbit's latest review is `CHANGES_REQUESTED` or its review threads are still unresolved. | Can enforce "every CodeRabbit thread resolved", which A can't. Gives a single required check named after this repo's policy. | Duplicates part of what A already does. Uses Actions runs on review events. Thread-resolution events may not trigger workflows at all (see the scaffold note), so it needs a manual re-run or a later event to go green. |
| **C. CodeRabbit CLI in Actions.** Run `cr review --remote … --agent` with a `CODERABBIT_API_KEY` secret on `push` to `master`, and fail or open an issue when it reports findings. | The only option that reviews direct pushes to `master`. Its NDJSON output is easy to turn into a check summary or an issue. | Costs Actions minutes and CodeRabbit review allowance on every push. It reviews after the fact, so the commit is already on `master`. Needs a secret and an Agentic API key. Needs CLI 0.7.7 or later. |
| **D. Local, before push.** Run `cr review --committed` in a pre-push hook, or as a step in the Claude Code workflow before `git push`. | Catches problems before they reach `master`, at no CI cost. It fits how `/code-review` is already used locally (AGENTS.md non-negotiable 7). | Not CI, so it can be bypassed, and each machine has to install and authenticate it. Doubles up with `/code-review`. |

## Decision

Recommend **A first**, then **B** if unresolved threads keep getting merged. Leave C and D out unless direct pushes start skipping review in a way that matters.

The deciding factor is that the failure seen so far, a merge while the review was still `pending`, is exactly what a required check stops. That costs nothing in Actions minutes and is reversible in a minute. B adds the one thing A can't express, "all CodeRabbit threads resolved", and is only worth its runs once that turns out to be a real problem. C is the only option that touches direct pushes, but it reviews after the commit has already landed, and it spends review allowance on every push to `master`. D overlaps with the `/code-review` pass AGENTS.md already requires.

Kartik's decision points:

1. Should the `master` ruleset require PRs, which blocks direct pushes (with an admin bypass, so he can still push when needed), or only require checks on PRs?
2. Should `request_changes_workflow` be on, so that CodeRabbit's "request changes" blocks a merge?
3. Should the lint checks be required too? That needs the always-run wrapper described in the scaffold.

## Consequences

**What it enables.** A PR can't merge while CodeRabbit is still reviewing, or after it has requested changes. Review rules for this repo (the reference-clone exclusion, shellcheck and ruff alignment, the AGENTS.md conventions) live in a versioned file instead of the CodeRabbit dashboard. The lint checks become enforceable rather than advisory.

**What it costs.** Merges wait for CodeRabbit, which usually takes a few minutes. If CodeRabbit has an outage, PRs are stuck until someone bypasses the rule. Path-filtered workflows need restructuring before they can be required. Direct pushes stay unreviewed unless decision point 1 goes the strict way.

**What would trigger revisiting this.** Revisit if CodeRabbit renames its check (its status reporting already moved from commit statuses to check runs once), if the plan or allowance changes, if a fork contributor starts sending PRs, or if direct pushes to `master` start shipping bugs that review would have caught. That last one points to C.

## Scaffold

### `.coderabbit.yaml` (option A)

The keys come from CodeRabbit's configuration reference. Validate this against the schema before committing, and `validate-config.sh` will also check it once it exists.

```yaml
# yaml-language-server: $schema=https://coderabbit.ai/integrations/schema.v2.json
language: en-GB
reviews:
  profile: chill
  request_changes_workflow: true # decision point 2
  fail_commit_status: true # a review error shows as a failure, not a silent pending
  auto_review:
    enabled: true
    drafts: false
  path_filters:
    - "!dwm-titus-main/**"
    - "!linutil-main/**"
    - "!titus-ai-main/**"
    - "!website-master/**"
    - "!winutil-main/**"
    - "!productivity/dashboard-archive/**"
  path_instructions:
    - path: "**/*.sh"
      instructions: >-
        Bash scripts here must pass lint-bash.sh (shellcheck, shfmt, bash -n).
        Flag anything that writes outside its documented files without sudo
        guards, and any destructive step with no rollback.
    - path: "docs/**/*.md"
      instructions: >-
        Flag claims that something is installed, configured or verified
        without the command or output that verified it (AGENTS.md
        non-negotiable 2).
  tools:
    shellcheck:
      enabled: true
    ruff:
      enabled: true
    markdownlint:
      enabled: true
    gitleaks:
      enabled: true
  pre_merge_checks:
    title:
      mode: warning
      requirements: "Imperative mood, matching this repo's commit subjects."
    description:
      mode: warning
```

CodeRabbit's markdownlint (`markdownlint-cli2`) isn't the same tool as this repo's `mdl`, so its findings can disagree with `.mdlrc`. If they turn noisy, switch it off and let `lint-markdown.yml` own markdown.

### `master` ruleset (option A)

Set this up in Settings, then Rules, then Rulesets, or with `gh api`. It's a repo setting, not a file. CodeRabbit's docs say a check only appears in the list of required checks after it has completed once, so open one PR first.

- Target `master`, enforcement Active, with a bypass for the repository admin.
- Require status checks to pass, and add CodeRabbit's check, using the name it actually publishes on that first PR.
- Optional, and decision point 1: require a pull request before merging.

### Always-run lint wrapper (option A, decision point 3)

A path-filtered workflow that doesn't run never reports, so GitHub waits on it forever if it's required. The usual fix is one workflow with no path filter that uses a path-detection step and skips the expensive steps when nothing relevant changed. It then always reports a single required check, for example `ci-required`. Merge that with the existing four lint workflows rather than adding a fifth path, or the run count goes up.

### `coderabbit-gate.yml` (option B)

This is a sketch. The thread query and the event list need testing on a real PR before relying on them. GitHub's docs, checked through Context7, confirmed `pull_request_review` and `pull_request`, but not whether thread resolution triggers a workflow. If it doesn't, re-run the gate by hand after resolving threads.

```yaml
name: CodeRabbit gate
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
  pull_request_review:
    types: [submitted, dismissed]
permissions:
  pull-requests: read
  contents: read
concurrency:
  group: coderabbit-gate-${{ github.event.pull_request.number }}
  cancel-in-progress: true
jobs:
  gate:
    runs-on: ubuntu-latest
    steps:
      - name: Fail on CodeRabbit changes-requested or unresolved threads
        env:
          GH_TOKEN: ${{ github.token }}
          PR: ${{ github.event.pull_request.number }}
          REPO: ${{ github.repository }}
        run: |
          owner=${REPO%/*} name=${REPO#*/}
          # Fetches the first 100 threads/reviews only; paginate if PRs get bigger.
          data=$(gh api graphql -F owner="$owner" -F name="$name" -F pr="$PR" -f query='
            query($owner:String!,$name:String!,$pr:Int!){
              repository(owner:$owner,name:$name){
                pullRequest(number:$pr){
                  reviewThreads(first:100){nodes{isResolved comments(first:1){nodes{author{login}}}}}
                  latestReviews(first:20){nodes{author{login} state}}
                }}}')
          open=$(jq '[.data.repository.pullRequest.reviewThreads.nodes[]
            | select(.isResolved|not)
            | select((.comments.nodes[0].author.login // "")|startswith("coderabbitai"))] | length' <<<"$data")
          state=$(jq -r '[.data.repository.pullRequest.latestReviews.nodes[]
            | select((.author.login // "")|startswith("coderabbitai")) | .state][0] // "NONE"' <<<"$data")
          echo "CodeRabbit latest review: $state, unresolved threads: $open"
          [ "$state" != CHANGES_REQUESTED ] && [ "$open" -eq 0 ]
```

### CLI review of direct pushes (option C)

This is an outline only. It needs `CODERABBIT_API_KEY` as a repo secret, from an Agentic API key, and CLI 0.7.7 or later. Install the CLI the way CodeRabbit's CLI docs currently say to. From 0.7.7, the CLI exits with code 1 on a failed or incomplete review, so check the exit code as well as the NDJSON `complete` event.

```yaml
on:
  push:
    branches: [master]
jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      # install step: per https://docs.coderabbit.ai/cli
      - run: cr auth login --api-key "$CODERABBIT_API_KEY"
        env:
          CODERABBIT_API_KEY: ${{ secrets.CODERABBIT_API_KEY }}
      - run: >-
          cr review --remote "$GITHUB_REPOSITORY"
          --base "${{ github.event.before }}" --source-branch "$GITHUB_SHA"
          --agent | tee review.ndjson
      # then: count findings in review.ndjson, write $GITHUB_STEP_SUMMARY,
      # and open an issue (or fail) when there are any.
```

Check that `--base` accepts a commit SHA. The docs only confirm that `--source-branch` takes a full 40-character SHA. When a push creates the branch, `github.event.before` is all zeros, so skip the review in that case or fall back to `HEAD~1`.
