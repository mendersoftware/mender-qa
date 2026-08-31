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
it per-repository with a `renovate.json5` file at the repo root.

Renovate itself runs from one central project, `NorthernTechHQ/renovate-ring`, not from a job
in each repository. The ring walks every repo in the organisation once a week and reads each
one's `renovate.json5` live from GitHub. A repo opts in by having that file and opts out by
not having it.

## How Renovate works

1. The weekly scheduled pipeline in `renovate-ring` starts one job per GitHub organisation
2. Renovate discovers the repositories in that organisation and clones each one
3. It reads `renovate.json5` (or falls back to defaults if the file is absent)
4. For each tracked dependency, it checks for newer versions
5. If a newer version is available, it opens or updates a PR with the version bump
6. The PR targets the configured base branches - `master` or `main` and any maintenance branches

Renovate maintains a "Dependency Dashboard" issue in each repository. That issue is where
you see everything: pending updates, open PRs, blocked updates, and anything it chose to
skip. The Dependecy issues are optionals, you can check it before wondering
where your update went, but you can rely on single PRs only if GH Issues are 
disabled for your repo.

## Where Renovate runs

Everything runs from `NorthernTechHQ/renovate-ring`. That project holds two files:

- `.gitlab-ci.yml` - one job per GitHub organisation, on a weekly schedule
- `renovate-global.json5` - bot side settings that apply to every repository

Individual repositories need no CI job and no pipeline schedule. The `mendertesting/renovate`
component that used to provide this has been removed everywhere.

Two settings in the global config are worth knowing:

- `requireConfig: "required"` - a repo with no `renovate.json5` is skipped entirely
- `autodiscoverFilter` - which organisations are in scope, set per job

Adding an organisation to the filter does nothing on its own. Repos in it still have to opt
in with a config file.

### Triggering Renovate manually

Go to the `renovate-ring` project in GitLab, CI/CD > Pipelines > Run pipeline from the
protected `main` branch. To try something without opening PRs, add the variable
`RENOVATE_EXTRA_FLAGS` set to `--dry-run=full` - Renovate then logs what it would do and
writes nothing.

The manual run creates the pipeline with the jobs in a manual state, so press play on the
one for the organisation you care about.

### Running it for one repository

Same thing, but narrow the scope with a filter:

```
RENOVATE_EXTRA_FLAGS = --autodiscover-filter=mendersoftware/mender-cli
```

The other organisation's job will find nothing and pass. Combine both flags if you want a
look without opening anything:

```
RENOVATE_EXTRA_FLAGS = --autodiscover-filter=mendersoftware/mender-cli --dry-run=full
```

A command line flag wins over the environment, so this overrides the filter the job sets
for itself. Check the `Autodiscovered repositories` line in the log to confirm only the repo
you asked for is listed.

The repo still needs a `renovate.json5`. Without one it is skipped and the run goes green
anyway, so an empty log is worth a second look before assuming Renovate is broken.

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

Renovate runs once a week, Sunday at 20:00 UTC, from the `renovate-ring` project. It does
not run on merges and there is no per-repository schedule any more. PRs are ready when the
team arrives Monday morning.

A full pass over both organisations takes about an hour, most of it spent on a handful of
large repositories.

Security vulnerability PRs bypass the `prHourlyLimit` and `prConcurrentLimit` caps, so a run
can open more of them than the limits suggest.

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

Every dependency update commit follows the pattern `fix(deps): <description>`. CI file
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
6. Do not add `.github/dependabot.yml` - Renovate covers everything it did

That is the whole onboarding. No CI job and no pipeline schedule: the ring picks the repo up
on its next weekly run because the config file is now there.

Check the Dependency Dashboard issue after that run to confirm all expected ecosystems were
detected. To see the result sooner, trigger a manual run from `renovate-ring`.

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
Trigger a manual run from the `renovate-ring` project. If it was closed by someone,
Renovate will recreate it on the next run.

**A repo gets no PRs and has no Dependency Dashboard**
Check it has a `renovate.json5` on the default branch. `requireConfig` is `required`, so a
repo without one is skipped silently - it will not appear as an error anywhere.

**A PR opened for a version you want to ignore**
Add a `matchPackageNames` + `"enabled": false` rule in `packageRules`, or use
`"ignoreVersions"` for a specific version string.
