# Definition of Done

An Epic is considered "Done" when all the criteria below have been met. These
need not be achieved sequentially. Parallel and stepwise completion is
expected.

## Done criteria

- **Implementation.** Required changes to code, configuration, and tooling
  are implemented per current team conventions. Automated test suites (unit,
  integration, acceptance) are extended or adjusted and pass in CI. Linters
  and static checks are green.

- **Peer review.** All work has passed peer review. Issues found during
  implementation or review are either addressed or, if non-critical, logged
  in Jira.

- **CI health.** CI pipelines run successfully. No Blocker bugs or critical
  regressions are known against the affected areas.

- **Acceptance criteria verified.** The work has been explicitly checked
  against the acceptance criteria defined by the PO. Tasks being marked
  "Done" in Jira is not on its own satisfactory. Explicit verification is
  required in case something was overlooked during planning or during
  individual task completion.

- **Manual testing and dogfooding.** A manual test plan has been made and
  executed. The implementing team has used the feature themselves and
  confirmed it works. For non-trivial scope, at least one person outside the
  team has exercised the feature to cover the "blind to your own mistakes"
  angle.

- **Documentation.** Required documentation changes are made and approved by
  relevant stakeholders, both external (docs.mender.io) and internal
  (READMEs, API docs).

- **Sprint review and PO sign-off.** The Epic has been demoed at sprint
  review. If scope, audience, or timing require it, an out-of-band demo is
  arranged with named stakeholders. The PO has signed off that what was
  demoed is consistent with what was specified. This sign-off authorises
  deployment to production (which may be behind a feature flag).

- **PO/UX acceptance (where required).** Default: not required for low-risk
  or non-customer-visible work; required for material customer-facing
  features where direction or UX could be wrong. When required, the PO and
  UX have used the feature themselves in staging or behind a flag in
  production, and have explicitly accepted it.

- **Deployment plan.** A deployment plan mapping potential risks and their
  mitigation strategies, rollback opportunities, and timing has been
  developed, documented, communicated to relevant stakeholders (PO,
  marketing, sales, support), agreed, and carried out.

- **Live on hosted Mender.** Where the work is deployed to hosted Mender,
  the Epic is live with no open Blocker issues that would
  require rollback. The work is not "Done" until this is true.

## Cross-cutting concerns

The team decides applicability and records the decision in the Epic. When
applicable:

- **Performance.** Load/stress tests run; benchmarks met; production metrics
  confirm expected latency and throughput post-rollout.
- **Infrastructure as code.** Infra and platform changes are expressed as
  IaC and peer-reviewed.
- **Observability.** Structured logging covers key operations and error
  paths; metrics and alerts are defined per team conventions where new
  behavior warrants monitoring.

## Engineering judgment

This list is not categorically exhaustive. It encodes the minimum bar; it
does not replace engineering judgment. We trust the reader to absorb the
spirit of the requirements and apply it together with their own high
standards on a case-by-case basis. When something matters that isn't listed,
raise it and propose adding it.
