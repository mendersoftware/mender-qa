# Testing Mender Server Locally with k8s

Use the [Mender Server testing kit](../mender-server-testing-kit/README.md).
It installs Mender Server (Open Source or Enterprise) for development and QA
in one of two ways:

- **Vagrant VM**: a Debian 12 VM with K3s, where Flux installs SeaweedFS and
  Mender from the nt-iac `manifests/test-k3s-opensource` or
  `manifests/test-k3s-enterprise` manifests. Includes pinning a release and
  running a GitLab PR build.
- **Local K3s**: the `mender` Helm chart installed directly, with the
  chart's built-in MongoDB, Redis, RustFS artifact storage and self-signed CA.

Neither setup is supported for production.
