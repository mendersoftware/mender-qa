# QA duty

In the Mender team, we have a rotating responsibility for QA, known as "QA duty".
This is a person in the team responsible for:

* Monitoring the health of the build system
* Triaging failures and routing them to the right owner
* Quarantining persistent failures so the team is not blocked
* Reporting status to the team (post status to `#mender-qa` Slack channel and
  discuss issues during the internal team meeting)

## Goal: trustworthy CI signal

The point of this rotation is to keep
CI a signal you can trust. Green should mean "safe to merge", red should mean
"a real, actionable problem exists". A pipeline that flaps red intermittently
is worse than a consistently red one, because it teaches the team to ignore
CI.

The person on QA duty owns this outcome for the duration of the rotation.
They are not expected to fix every issue personally, but they are expected
to make sure each broken pipeline is either fixed, reverted, or quarantinedas as soon as possible and ideally by end of day.

In cases where end of day resolution is not achievable, the person
on QA duty is expected to have assigned a clear owner of the issue and
agreed upon ETA for a fix. Furthermore, the person on QA duty is also
expected to follow-up on the progress of such assignments (for example
during standup's) to ensure the problem is resolved in a timely manner and
according to plan.

The team relies on the state of the CI pipelines as a signal of trust to
both merge code and deploy to production and it's therefore paramount that
we treat failures in this space with urgency and importance.

## Test tiers

We operate two tiers:

* **Tier 1: required to merge.** Client tests, server unit tests, server API
  tests, and server integration tests. These run on every PR and
  must pass before merge. Tier 1 failures are owned by the **author of the
  PR**, not QA duty. QA duty steps in only if a tier 1 job has structural
  issues (infra, flake patterns) that span PRs.

* **Tier 2: nightly, informational.** End-to-end integration tests
  (client + server) and staging tests, primarily in mender-server and
  mender-server-enterprise. These do not block PR merges. **Tier 2 is the
  primary QA duty surface during the rotation.**

## Authority

To make the goal above achievable, the person on QA duty has explicit
authority to:

* Create Jira tasks for broken pipelines and test failures
* Add those tasks to the current sprint without waiting for sprint planning
* Mark them as expedited so they jump the queue
* Ask the author of a breaking change to either fix forward or revert
* Quarantine a persistently failing test to unblock the team
  (see [Quarantine policy](#quarantine-policy))

The person on QA duty distributes bugs to the team, but only after attempting
a first investigation themselves so the handoff is concrete: identify which
PR/commit or which subsystem likely introduced the issue, then assign it to
that author or owner. Don't fan out vague "the pipeline is red" pings.

## Mender QA rotation calendar

Client team: https://northerntech.atlassian.net/compass/operations/1aec3540-3768-4f3d-b728-d1f3e7e4412f/on-call

Server team: https://northerntech.atlassian.net/compass/operations/6aef3ccd-778c-4691-9450-664b3b323b74/on-call

This is the Atlassian Compass Operations calendar showing who takes which QA rotation and when.

## Team Assigned Repositories

As a rule of thumb each team is responsible for their work (e.g. Server team is responsible for all Server components
and the Client team is responsible for all the Client components). As per current agreement the Client team is
responsible for `integration` repository and Mender Gateway.

## Triage loop for tier 2 failures

When a tier 2 nightly comes in red, classify before acting. The categories
matter because the response is different for each:

1. **Did the tests run at all?** If the job died in setup (package install,
   docker pull, dind start, docker-compose up), the tests never executed. The
   right response is usually re-run + flag the infra cause to the relevant
   owner.

2. **If tests ran and failed, was it the same test as recent nights?** Check
   the existing Mantra dashboard (per-test data). A test that has been
   failing for several nights is a quarantine candidate. A new failure is more
   likely to point at a real change.

3. **If the failure looks new, can you pin it to a PR or commit?** Check the
   diff between the last green and this run. If yes, ask the author to fix
   forward or revert. If no, escalate to the relevant team. Don't
   sink hours on attribution alone.

Spend a reasonable first effort on classification (≈30 minutes), then either
act or escalate. Sustained heroics are not the goal here.

## Quarantine policy

Quarantine is for the case where: we understand the failure, we can't fix it
this week, and leaving it in place is blocking other work or eroding trust in
the signal. It is **not** a way to silence a flaky test that nobody has tried
to understand yet. That path leads to a permanently red graveyard.

Quarantine is a judgment call by the person on QA duty, not driven by a fixed
time threshold. Typical triggers: the same failure has repeated across several nightly runs and the cause is understood but not yet fixed.

### Convention: the Jira ticket is the source of truth

A test or job is quarantined when there is an open Jira ticket with the
`Quarantine` label. The mark in source code is just a pointer at that ticket.
This way the convention works across pytest, Playwright, and any future
test framework.

When quarantining:

1. Create a Jira ticket describing the failure:
   * Label: **`Quarantine`**
   * Priority: **Blocker** (so it surfaces in the release-readiness view)
   * Include: the failing test or job, the first observed failure date, a
     representative pipeline link, and the suspected root cause if known.

2. Mark the test or job in source so anyone reading it knows why.

   **pytest test:**
   ```python
   @pytest.mark.quarantine(jira="QA-1234")
   def test_something():
       ...
   ```

   **Playwright test:**
   ```ts
   test.fixme("QA-1234: quarantined — see Jira", async ({ page }) => {
     // ...
   });
   ```

3. Push the change and verify the pipeline reflects the quarantine.

The pytest `quarantine` marker is implemented in conftest.py - it converts
the marker into a `skip` with the Jira ID in the reason. We do not use
`xfail` for quarantine because `xfail(strict=False)` still runs the test
and silently swallows new failure modes.

### Release gate

Releases are blocked while any Jira ticket with the `Quarantine` label is
still open. We do not ship with quarantined tests in
place. That's the deal we make when we quarantine in the first place.

## Pipelines QA duty should be watching

### Overview of unstable tests

Link: https://qastatus.mender.io/stats

The unstable tests should be known to the person on QA duty so it can be
detected when test failures are genuine or spurious.

**By the end of the QA duty period, all failed tests in nightly builds (link
above) should either be fixed or discussed during the internal team meeting.
Once we see the tests are failing consistently we will report those in JIRA
(QA project) to follow-up in the next Sprint.**

### Nightly Mender QA build (client only)

Link: https://qastatus.mender.io/nightlies

Link: https://gitlab.com/Northern.tech/Mender/mender-qa/-/pipelines?page=1&scope=all&source=schedule

### Nightly Mender Server

Link: https://gitlab.com/Northern.tech/Mender/mender-server/-/pipelines?page=1&scope=all&source=schedule

Link: https://gitlab.com/Northern.tech/Mender/mender-server-enterprise/-/pipelines?page=1&scope=all&source=schedule

Nightly tests over the mender-server monorepo. These include the whole
spectrum from unit tests to E2E tests. The enterprise pipeline features the
same jobs as the open-source one.

### Nightly Mender Server Integration tests

Link: *qastatus link pending*

Link: https://gitlab.com/Northern.tech/Mender/integration/-/pipelines?page=1&scope=all&source=schedule

These tests run the Mender Server monorepo artifacts from `main` over the
current Mender client artifacts from `master`.

### Nightly Mender Gateway

Link: https://gitlab.com/Northern.tech/Mender/mender-gateway/-/pipelines?page=1&scope=all&source=schedule

Two branches to check: `master` and `2.0.x`.

### Other notable weekly pipelines

Link: https://gitlab.com/Northern.tech/Mender/integration-test-runner/-/pipeline_schedules

Link: https://gitlab.com/Northern.tech/Mender/mender-mcu/-/pipeline_schedules

Link: https://gitlab.com/Northern.tech/Mender/monitor-client/-/pipeline_schedules

## More information

More information about roles and responsibilities can be found in the internal document:

https://docs.google.com/document/d/1pFJbGVM248UoynsMbNox47whrzIfVUrK4hO_xiIWHzA/edit
