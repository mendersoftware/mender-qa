# Dependency updates

- [Overview](#overview)
- [How Renovate works](#how-renovate-works)
- [Running Renovate in a GitLab pipeline](#running-renovate-in-a-gitlab-pipeline)
- [Per-repository configuration](#per-repository-configuration)
- [Update process](#update-process)
- [Internal Mender dependencies](#internal-mender-dependencies)
- [Onboarding a new repository](#onboarding-a-new-repository)
- [Troubleshooting](#troubleshooting)

## Overview

Mender repositories use [Renovate](https://docs.renovatebot.com/) for dependency updates.
It replaced GitHub Dependabot.

Renovate opens pull requests when new versions of dependencies are available. You configure
it per-repository with a `renovate.json5` file at the repo root. A GitLab CI job in the
`.pre` stage runs it - only on scheduled pipelines, or a manual on-demand run. It no longer
runs on regular merge pipelines.

## How Renovate works

1. A GitLab CI/CD scheduled pipeline triggers the `renovate` job on a protected branch
   (or someone triggers it manually from the GitLab web UI)
2. Renovate clones the target GitHub repository
3. It reads `renovate.json5` (or falls back to defaults if the file is absent)
4. For each tracked dependency, it checks for newer versions
5. If a newer version is available, it opens or updates a PR with the version bump
6. The PR targets the configured base branches - `master` or `main` and any maintenance branches

Renovate maintains a "Dependency Dashboard" issue in each repository. That issue is where
you see everything: pending updates, open PRs, blocked updates, and anything it chose to
skip. The Dependecy issues are optionals, you can check it before wondering
where your update went, but you can rely on single PRs only if GH Issues are 
disabled for your repo.

## Running Renovate in a GitLab pipeline

Renovate runs via the `mendertesting` shared template. The component's job is restricted
to scheduled pipelines, plus a manual run kept available for on-demand use:

```yaml
# In .gitlab-ci.yml
include:
  - component: gitlab.com/Northern.tech/Mender/mendertesting/renovate@master
    inputs:
      stage: ".pre"

# Override the component job's rules - restrict to scheduled pipelines, plus a manual
# on-demand run (see "Triggering Renovate manually" below). No run on regular merges.
renovate:
  rules:
    - if: '$CI_PIPELINE_SOURCE == "schedule" && $CI_COMMIT_REF_PROTECTED == "true"'
    - if: '$CI_PIPELINE_SOURCE == "web" && $CI_COMMIT_REF_PROTECTED == "true"'
      when: manual
```

**Note:"** the [Github counterpart](https://github.com/renovatebot/github-action) is:
```
....
jobs:
  renovate:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v6.0.3
      - name: Self-hosted Renovate
        uses: renovatebot/github-action@v46.1.16
        with:
          docker-cmd-file: .github/renovate-entrypoint.sh
          docker-user: root
          token: ${{ secrets.RENOVATE_TOKEN }}
```

The job still runs in the `.pre` stage, ahead of anything else in the pipeline, but the
pipeline itself only exists because it was scheduled or manually triggered - a regular
merge to the default branch doesn't start a Renovate run.

### Triggering Renovate manually

Go to GitLab CI/CD > Pipelines > Run pipeline from the protected `main|master` 
branch, set `FORCE_RENOVATE_RUN` to `true`, run

## Per-repository configuration

Each repository needs a `renovate.json5` at the root. Start from `renovate.json5.sample`
in the mender-qa repository. Three things you must adapt:

- `reviewers` - the GitHub team that owns this repo (see the table below)
- `baseBranchPatterns` - every branch that should get updates, including maintenance branches
- `customManagers` - keep only the blocks that match what this repo actually pins

| Team slug | Repositories |
|---|---|
| `team:client-dependabot-reviewers` | mender-gateway, mender, mender-mcu |
| `team:backend-dependabot-reviewers` | mender-server, mender-server-enterprise |
| `team:qa-dependabot-reviewers` | integration, mendertesting |
| `team:sre-dependabot-reviewers` | mender-helm, saas, saas-tools, nt-boilerplate-pipeline |

## Update process

### Schedule

Renovate only runs on the GitLab CI/CD scheduled pipeline, tailored on every 
repository.

Security vulnerability PRs aren't opened immediately - they surface at the next
scheduled run, same as everything else. If you receive a GitHub Dependabot vulnerability
alert and don't want to wait, trigger a manual web pipeline run instead (see "Triggering
Renovate manually" above).

### What to expect

Up to 5 open Renovate PRs at any time. PRs are grouped by category: one PR for all Go
modules, separate PRs per Docker base image update, etc. The Dependency Dashboard issue
lists anything still pending or blocked.

### Your job as reviewer

Check the Dependency Dashboard once a week during QA duty. Review and merge dependency
PRs within the sprint. If a security vulnerability PR shows up, treat it as a priority -
it should not wait for the next sprint cycle.

Renovate only rebases a PR when it actually conflicts with the base branch - a PR that is
merely behind, with no conflict, is left alone. If a PR has been open 30+ days and keeps
conflicting, close it. Renovate will reopen it on the next run with a clean base.

### Major version updates

Major version bumps never automerge - they need a human decision. Renovate flags them
clearly. A Go runtime upgrade or a base OS change is a planned task, not something to
batch-merge on a Friday afternoon.

### Commit messages

Every dependency update commit follows the pattern `chore(deps): <description>`. CI file
updates use `ci:` instead. This keeps dependency bumps out of the product changelog
and prevents them from triggering unintended releases through release-please.

## Internal Mender dependencies

Some Mender component versions are pinned as plain strings in Dockerfiles or CI
variables rather than as standard package manager entries. Renovate picks these up via
custom regex managers.

### MENDER_ARTIFACT_VERSION

Tracks the `mendersoftware/mender-artifact` GitHub release version.

Pinned in a Dockerfile:
```dockerfile
ARG MENDER_ARTIFACT_VERSION=3.11.2
```

Pinned in `.gitlab-ci.yml`:
```yaml
MENDER_ARTIFACT_VERSION:
  value: "3.11.2"
```

Renovate opens a PR when a new GitHub release of `mendersoftware/mender-artifact` is
published. Use the custom manager variant that matches where the version is pinned in
your repo, not both.

### DOCKER_VERSION

Tracks the Docker CLI version pinned as a CI variable. Apply this manager to any repo
that has a `DOCKER_VERSION` variable in `.gitlab-ci.yml`.

## Onboarding a new repository

1. Copy `renovate.json5.sample` to the repo root as `renovate.json5`
2. Keep `reviewersFromCodeOwners: true` and maintain CODEOWNERS entries for dependency
   files (`go.mod`, `Dockerfile*`, `package.json`, etc.) assigned to the correct team -
   Renovate reads CODEOWNERS to assign reviewers, and those entries also protect the
   files in manually opened PRs
3. Set `baseBranchPatterns` to include all active branches
4. Delete custom manager blocks that do not apply to this repo
5. Delete `packageRules` entries for ecosystems the repo does not use
6. Add the Renovate runner job via the `mendertesting` shared template, with the `rules`
   override shown above - scheduled pipelines and manual web runs only, no merge trigger
7. Add a GitLab CI/CD Scheduled Pipeline with cron `0 1 * * 2` (Tuesday 01:00 UTC) on the
   protected default branch - this is now the only automatic trigger, not a fallback
8. Do not add `.github/dependabot.yml` - Renovate covers everything it did

First run takes a few minutes. Check the Dependency Dashboard issue after it completes
to confirm all expected ecosystems were detected.

## Troubleshooting

**No PRs after the first run**
Look at the Dependency Dashboard issue. Renovate creates it on the first run and lists
everything it found. If the issue exists but no PRs opened, you hit the concurrent PR
limit - remaining updates open on the next scheduled run, or trigger a manual run to
catch up sooner.

**A PR keeps rebasing in a loop**
Something on the target branch is conflicting with the update. Merge or close whatever
is blocking, then let Renovate rebase on the next run.

**Custom manager not picking up the version**
Test the regex at regex101.com using the `multiline` and `dotall` flags. The `[\\s\\S]*?`
pattern handles multi-line YAML blocks - without it the match will fail silently.

**The Dependency Dashboard issue is missing**
Trigger a manual run with `FORCE_RENOVATE_RUN=true`. If it was closed by someone,
Renovate will recreate it on the next run.

**A PR opened for a version you want to ignore**
Add a `matchPackageNames` + `"enabled": false` rule in `packageRules`, or use
`"ignoreVersions"` for a specific version string.

**Don't re-enable a run on every merge to main**
This was tried before. Running Renovate on every merge pipeline stressed both the GitLab
runners and the GitHub API rate limits, and produced multiple job failures across
repositories. That is why the trigger is schedule-only (plus manual on-demand runs) - do
not add the merge trigger back without addressing the runner load and rate-limit problem
first.
