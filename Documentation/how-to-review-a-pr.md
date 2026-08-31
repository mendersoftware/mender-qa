# PR Review Policy

To ensure code quality, maintainability, and stability, all Pull Requests (PRs) follow a three-step review process. This process includes automated checks followed by two distinct types of human review.

## Automated: 1st Step
Before any human review, all PRs must successfully pass a series of automated checks. These tools provide the first line of defense against common issues.

### Linter & Formatter
Automatically fixes all style and formatting issues.

We enforce a shared style guide (for example, Mantra will reuse the style guide from nt-gui).

### Test Coverage
Ensures that tests are present to prove the code works as intended.


### (future) Add Static Analysis
This is a more long-term goal for additional risk reduction.

A tool like SonarQube or Gitlab SATS will be used to scan the PR for code smells, complexity issues, and potential bugs. Some static code analysis can also be done within the Linter & Formatter step.

### Type Script (Frontend Specific)
Catches errors related to data types specifically in the frontend codebase.

## Human (Product Review): 2nd Step
This review focuses on the "what" and "why" of the change. Even if the reviewer doesn't know the specific programming language, they are still a skilled engineer who understands the product and can provide valuable feedback.

### Enforce Standard PR Description
The PR description must be clear so that reviewers understand the context and purpose, making the review easier. It should include:

- What: What is the purpose of this change?
- Why: Why is this change being made?
- How: A brief summary of the technical approach.

### The "What & Why"
Does this PR do what the JIRA ticket/task description says it should do?

Is the business logic sound?

### The API Contract
This is mainly for the Server team after the OpenAPI 3.0 migration is complete.

Is the frontend calling the API correctly?

Is it gracefully handling all expected responses (e.g., 200, 404, 500)?

### Readability & Maintainability
Clean code is clean code, regardless of language.

Can the reviewer get the gist of what this code is doing?

Is it well-commented?

Are variable names clear?

Is it aligned with the coding standard and style in the given project (function names, variable naming conventions)?

### The Tests
Are there tests included?

Do the tests cover the acceptance criteria? (This will be largely covered by the automated test coverage checks).

## Human (Domain Expert Review): 3rd Step
**This final review is performed by an expert in the specific domain (e.g., frontend, backend, client) and programming language. Their focus is on the technical implementation and architecture.**

### Implementation Correctness
Is the implementation correct, performant, and maintainable?

### Architecture & Best Practices
Does this code follow the established architecture and best practices for the specific function (frontend, backend, client), project, and programming language?