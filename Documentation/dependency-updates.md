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
`.pre` stage runs it on every pipeline on the default branch, plus weekly as a fallback.

## How Renovate works

1. A GitLab/Github pipeline triggers the `renovate` job (on merge to master/main, or weekly)
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

Renovate runs via the `mendertesting` shared template:

```yaml
# In .gitlab-ci.yml
  - component: gitlab.com/Northern.tech/Mender/mendertesting/renovate@master
    inputs:
      stage: ".pre"
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

The job runs in the `.pre` stage so it fires as soon as the commit lands, before any
other stage runs. Renovate reads dependency files, not build artifacts, so it does not
need to wait for CI to complete. The scheduled pipeline is a fallback for weeks with no
merges.

### Triggering Renovate manually

Go to GitLab CI/CD > Pipelines > Run pipeline from the protected `main|master` 
branch, set `FORCE_RENOVATE_RUN` to `true`, run

## Per-repository configuration

Each repository needs a `renovate.json5` at the root. Start from `renovate.json5.sample`
in the mender-qa repository. Three things you must adapt:

- `reviewers` - the GitHub team that owns this repo (see the table below)
- `baseBranches` - every branch that should get updates, including maintenance branches
- `customManagers` - keep only the blocks that match what this repo actually pins

| Team slug | Repositories |
|---|---|
| `team:client-dependabot-reviewers` | mender-gateway, mender, mender-mcu |
| `team:backend-dependabot-reviewers` | mender-server, mender-server-enterprise |
| `team:qa-dependabot-reviewers` | integration, mendertesting |
| `team:sre-dependabot-reviewers` | mender-helm, saas, saas-tools, nt-boilerplate-pipeline |

## Update process

### Schedule

Renovate runs after every merge to the default branch. It also runs once a week
overnight between Monday and Tuesday (22:00-06:00 UTC) for repos that go a full week
without merges. PRs are ready when the team arrives Tuesday morning.

Security vulnerability PRs open immediately, any day, any time - they do not wait for
either trigger.

### What to expect

Up to 5 open Renovate PRs at any time. PRs are grouped by category: one PR for all Go
modules, separate PRs per Docker base image update, etc. The Dependency Dashboard issue
lists anything still pending or blocked.

### Your job as reviewer

Check the Dependency Dashboard once a week during QA duty. Review and merge dependency
PRs within the sprint. If a security vulnerability PR shows up, treat it as a priority -
it should not wait for the next sprint cycle.

PRs that drift out of date get rebased automatically. If a PR has been open 30+ days and
keeps conflicting, close it. Renovate will reopen it on the next run with a clean base.

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
3. Set `baseBranches` to include all active branches
4. Delete custom manager blocks that do not apply to this repo
5. Delete `packageRules` entries for ecosystems the repo does not use
6. Add the Renovate runner job via the `mendertesting` shared template
7. Add a weekly scheduled pipeline with cron `0 1 * * 2` (Tuesday 01:00 UTC) as a fallback
8. Do not add `.github/dependabot.yml` - Renovate covers everything it did

First run takes a few minutes. Check the Dependency Dashboard issue after it completes
to confirm all expected ecosystems were detected.

## Troubleshooting

**No PRs after the first run**
Look at the Dependency Dashboard issue. Renovate creates it on the first run and lists
everything it found. If the issue exists but no PRs opened, you hit the concurrent PR
limit - remaining updates will open over the next few hourly cycles.

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
