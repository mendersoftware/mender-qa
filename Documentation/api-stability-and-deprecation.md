# API stability and deprecation

This document captures the rules developers must follow when changing public
APIs exposed by Mender server components. The goal is to keep released APIs
stable for clients that already depend on them, while still letting us extend
the surface freely.

## Scope

These rules apply to **stable** APIs only — endpoints released as part of the
public, supported surface (`v1`, `v2`, …). They do **not** apply to **alpha**
or **beta** endpoints. Pre-release endpoints exist precisely so we can iterate
on their shape and semantics *without* the guarantees below: callers must
expect alpha/beta endpoints to change, including in breaking ways, until they
are promoted to a stable version.

When an endpoint is promoted from alpha/beta to stable, the form that ships as
stable is the one frozen by these rules.

## Stability rules

It is **not ok** to alter or remove any existing functionality or behavior of a
server API that clients might rely upon. This includes, but is not
limited to:

* HTTP verbs and URLs
* Required input parameters and their types
* Response status codes (with one carve-out, see
  [Permitted refinements](#permitted-refinements))
* Response body shape and field types
* Authentication and authorization requirements
* Error code semantics - what a given code *means* must never change: a `409` always signals a conflict, a `500` always signals an unhandled failure (see [Permitted refinements](#permitted-refinements))
* Any other guarantee a client would treat as part of a stable API

It **is ok** to add anything you need, as long as it is backward compatible.
This includes:

* New endpoints
* New optional input parameters with sensible defaults
* New fields in response bodies
* New error codes returned only under genuinely new conditions

Once an API version is released, its behavior is **locked**. It cannot be
changed in a breaking way (per the list above) without first going through the
[deprecation policy](https://docs.mender.io/overview/compatibility-policy#deprecation-policy-server-api).

These rules apply to every externally exposed API surface:
management APIs and device APIs.

## Permitted refinements

The rules above are about not changing *guarantees clients depend on*. There are a couple of changes that touch status codes but do **not** weaken any such guarantee, and these are explicitly allowed without versioning or deprecation.

### Specializing a catch-all error code

Any failure we do not handle explicitly maps to `500 Internal Server Error`. A `500` carries no promise other than "something went wrong on our side", so the only behavior a client can reasonably attach to it is at the *class* level (typically: a `5xx` is a server-side, retryable error). When we later discover the real cause of a `500` and return a more specific code instead - for example a `409` once we learn the failure was a conflict, or a `400` once we learn the input was invalid - that is a **refinement, not a breaking change**, and is
allowed.

The constraint that still holds is the one from the stability rules: a code's *meaning* never changes. You are not redefining what `409` means; you are classifying a failure that was previously unclassified. Concretely:
* It **is** ok to narrow a previously-returned `500` to a more specific code that accurately describes the cause. Staying within `5xx` (e.g. `500` → `503`) is fully transparent. Moving to a `4xx` (e.g. `500` → `409`/`400`) is also allowed and is usually the behavior you want.
* It is **not** ok to move a request that already succeeded (`2xx`) into an error, or to change one already-specific code into a different one (e.g. `409` → `400`). Those change a guarantee a client may rely on.

If you cannot specialize error codes without versioning the whole API, we hold ourselves to an unreasonably high standard that makes iterating on the server needlessly hard. So we don't.

## What counts as a breaking change

If unsure whether your change is breaking, ask: *could a client written
against the previous version stop working after this change?* If yes, it is
breaking. Common examples:

* Renaming a field in a response (keeping the old field alongside the new
  one is preferred, a removal is breaking)
* Tightening validation on an input (rejecting requests that used to succeed)
* Changing the meaning of an existing field
* Changing the default value of an optional parameter
* Changing the order of items in a response where order was previously stable

This is also covered, from the versioning angle, in
[Specific versioning criteria](https://docs.mender.io/overview/compatibility-policy#specific-versioning-criteria)
in the public docs.

## Process for unavoidable breaking changes

When a breaking change is genuinely needed:

1. Introduce the new behavior under a new API version (`v2`, `v3`, …) or a new
   endpoint. Keep the old behavior working.
2. Mark the old version or endpoint as deprecated in code and in the public
   documentation under
   [302.Release-information/02.Deprecations/docs.md](https://github.com/mendersoftware/mender-docs/blob/master/302.Release-information/02.Deprecations/docs.md).
3. Follow the timelines in the
   [deprecation policy](https://docs.mender.io/overview/compatibility-policy#deprecation-policy-server-api):

   * **Management APIs**: at least **6 months** from the deprecation
     announcement to removal.

   On hosted Mender, removal happens at the end of that window. On-premise,
   the release containing the deprecated API remains supported for at least
   the same window from the announcement, so the effective migration window
   is the same regardless of deployment model.
4. Only after the deprecation window has elapsed may the old behavior be
   removed.

## Security exceptions

The deprecation window protects clients from surprise. A high- or
critical-severity vulnerability can override that window when the only safe
remediation breaks the API contract (for example, tightening input
validation that previously accepted an exploitable payload, removing a field
that leaks sensitive data).

When invoking this exception:

* **Take the minimum-necessary break.** If a backward-compatible fix exists,
  use it. Convenience does not unlock the carve-out.
* **Ship a security advisory with the change.** Name the affected
  endpoint(s), the breaking aspect, and the client-side action required. Add
  a breaking-change entry to
  [302.Release-information/02.Deprecations/docs.md](https://github.com/mendersoftware/mender-docs/blob/master/302.Release-information/02.Deprecations/docs.md)
  even though the standard deprecation timeline does not apply.


## Reviewer checklist

When reviewing a PR that touches an API, confirm:

* [ ] No existing endpoint URL or verb is changed
* [ ] No status code change other than specializing a previous `500` into a more accurate code (see [Permitted refinements](#permitted-refinements))
* [ ] No existing required input becomes required-with-different-semantics
* [ ] No existing response field is renamed, retyped, or removed
* [ ] Any added input parameter is optional and has a sensible default
* [ ] If a breaking change really is needed, a new version is introduced and
      the old version is marked deprecated in both code and the public docs
