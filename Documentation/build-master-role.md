# Build Master role

In the Mender team, we have a weekly rotative role known as "Build Master". This
is a person in the team responsible for:

* Monotiring the health of the Build System
* Doing early investigation on issues
* Report problems to the team

## Mender QA rotation calendar

Link: https://calendar.google.com/calendar/embed?src=northern.tech_m6aop2it00n2jnpiut2j40n39k%40group.calendar.google.com&ctz=Europe%2FOslo

This is the Google calendar that shows who takes this role when.

## Responsibilities

### Nightly Mender QA build

Link: https://qastatus.mender.io/nightlies
Link: https://gitlab.com/Northern.tech/Mender/mender-qa/-/pipeline_schedules

There is no golden rule on what to do when the "Last Pipeline" in the link above
is not green.

The general advise is to do a short investigation before asking for help from
others in the team. For obvious test infra errors we can just re-run the jobs;
for actual test failures we need to asses if it might be a regression or not.

### Weekly Mender integration tests on staging

Link: https://gitlab.com/Northern.tech/Mender/integration/-/pipeline_schedules

Every Monday evening, at 9 PM UTC, we run the Mender integration tests targeting
the Mender staging environment.

On Tuesday morning, the Build Master must check the status of the pipeline and
do a short investigation before asking for help from others in the team in
case of failures.

### SaaS deploy pipeline(s)

Link: https://gitlab.com/Northern.tech/MenderSaaS/saas/pipelines

On Mondays, it is important to check that the weekly scheduled pipelines
succeeed (marked with "Scheduled" tag). For the rest of the week, it is also
good to keep an eye on the CI/CD related pipelines, specially if this is a week
where a new Hosted Mender release is planned.

### Individual pipelines

Link: https://qastatus.mender.io/build-status

All should be green. If a pipeline is broken, ping the corresponding team.

They get build after every merge to master on the corresponding repository, and
on weekly basis every Tuesday evening, at 9 PM UTC.
