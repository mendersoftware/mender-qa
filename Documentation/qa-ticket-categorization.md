# QA-ticket categorization

In order to keep a rough overview of how our QA time is spent, all QA tickets
should be categorized according to the following criterias:

* QA-Hotfix - Fixes to failing tests, and related pipeline maintenance.

* QA-Feature - Adds new testing functionality, like a new platform, or a new test.

* QA-Chore - Housekeeping. Upgrading base-images, dependencies etc.

* QA-Improvement - tests refactors, speedups, cleanups. All things which makes our QA stuff nicer/easier to use.

* QA-Project - For new and more work intensive QA projects, distinct from everyday QA work.

* QA-Spurious-failures - tests which have been bothering our pipelines consistently over a period of time. We want this as a separate label, so that our efforts here can be tracked.

