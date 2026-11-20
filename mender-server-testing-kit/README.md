# Mender Server testing kit

Helpers to run a throwaway Mender Server for development and QA.

> **Not supported for production.** Both setups run MongoDB, artifact storage
> and certificates inside the cluster with test-grade settings. For real
> installations follow https://docs.mender.io/server-installation.

Two setups, pick one:

| | Vagrant VM | Local K3s |
|---|---|---|
| Where | libvirt VM, Debian 12 | K3s on this host (`~/.kube/k3s.yaml`) |
| Installs | nt-iac `manifests/test-k3s-*` through Flux | `mender` Helm chart directly |
| Storage | SeaweedFS | RustFS subchart (`rustfs.enabled`) |
| TLS | self-signed certificate for `mender.local` | chart-generated CA (`ingress.selfSignedTLS`) |
| Needs | GitHub token for NorthernTechHQ/nt-iac | chart 8.6.0+ or a local mender-helm checkout |

Enterprise needs a registry.mender.io account in both setups. The pull
secret is created from `MENDER_REGISTRY_USERNAME`, `MENDER_REGISTRY_PASSWORD`
and `MENDER_REGISTRY_EMAIL` in your environment; the unset ones are asked
for. With none of them set, an existing secret is kept, so upgrades do not
ask again; set them to replace it.

Every prompt can be answered in advance with the variable shown below.
Secrets are read with hidden prompts or from the environment and passed
through files, never on a command line. One exception: the user CLIs in the
Mender images read the admin password only from a terminal, so
`USER_PASSWORD` set in the environment is passed with `--password` and is
visible in `ps`. Leave it unset to type it at their prompt instead.

The code blocks have no comments, so they paste into bash and zsh alike.

## Vagrant VM

Requirements: Vagrant with the libvirt provider
(`vagrant plugin install vagrant-libvirt`, user in the `libvirt` group).

```bash
make vm-up
sudo sh -c 'echo "192.168.56.10 mender.local" >> /etc/hosts'
make vm-install
make vm-status
make vm-user
```

- `vm-up`: `VM_MEMORY=8192 VM_CPUS=6` for Enterprise; with another `VM_IP`,
  use it in `/etc/hosts`. `K3S_VERSION`, `HELM_VERSION` and `FLUX_VERSION`
  pin the tools installed in the VM.
- `vm-install`: `EDITION`, `GITHUB_TOKEN`, `MENDER_REGISTRY_USERNAME`,
  `MENDER_REGISTRY_PASSWORD`, `MENDER_REGISTRY_EMAIL`. Use a fine-grained
  GitHub token with read-only access to NorthernTechHQ/nt-iac only: it is
  stored in the VM.
- `vm-status`: about 10 minutes until all pods run.
- `vm-user`: `USER_EMAIL`, `USER_PASSWORD`, `ORG_NAME` (Enterprise).

Open https://mender.local and accept the certificate warning.

Other targets:

- `make vm-version VERSION=v4.1.0-saas.16`: pin the Mender Server image tag.
- `make vm-pr-build VERSION=build-<sha>`: run a PR build from the GitLab
  registry (`GITLAB_REGISTRY_USERNAME`, `GITLAB_REGISTRY_TOKEN`,
  `GITLAB_REGISTRY_EMAIL`).

The `vm-*` targets forward the variables that are set on your host into the
VM through a temporary file readable only by you, deleted as soon as it is
read; they never appear on a command line.

- `make vm-cert`: copy the server certificate to `.state/server.crt` for
  device builds, for example in Yocto `local.conf`:
  ```
  FILESEXTRAPATHS:prepend:pn-mender-server-certificate := "/path/to/mender-server-testing-kit/.state/:"
  SRC_URI:append:pn-mender-server-certificate = " file://server.crt"
  IMAGE_INSTALL:append = " mender-server-certificate"
  ```
- `make vm-ssh`.

Clean up with `make vm-uninstall` (Mender, SeaweedFS, the built-in MongoDB
left behind by its Helm hook, PVCs, secrets and Flux; the VM stays, ready for
another `make vm-install`) or `make vm-destroy` (the whole VM).

## Local K3s

Requirements: 4 vCPUs and 8 GB RAM free, ports 80 and 443 free,
`fs.inotify.max_user_instances` of at least 1024 (`k3s-setup` sets it).

> **Trusted networks only.** K3s listens on all interfaces: Mender on 80 and
> 443, the Kubernetes API on 6443, the kubelet on 10250 and flannel on UDP
> 8472. On a laptop, do not run it on public Wi-Fi, or block these ports with
> a firewall.

```bash
make k3s-setup
make k3s-install
make k3s-user
```

- `k3s-setup`: installs or starts K3s and writes `~/.kube/k3s.yaml`.
  `K3S_VERSION` and `HELM_VERSION` pin the versions installed.
- `k3s-install`: `MENDER_SERVER_URL`, `EDITION`, `CHART`, `IMAGE_TAG`.
- `k3s-user`: `USER_EMAIL` (default `admin@example.com`), `USER_PASSWORD`,
  `ORG_NAME` (Enterprise).

Mender Server 5 rejects user emails on non-public domains such as
`mender.local`, so the default admin is `admin@example.com`.

The `k3s-*` targets always use `~/.kube/k3s.yaml` and the namespace
`mender`, never your `KUBECONFIG`, current context, `NAMESPACE` or
`HELM_KUBE*` variables, so they cannot hit another cluster by accident. Set
`KIT_KUBECONFIG` for a different cluster and `KIT_NAMESPACE` for another
namespace. Anything other than a server on 127.0.0.1 asks for confirmation;
`k3s-uninstall` always asks, and only deletes a namespace that holds the
`mender` release.

`k3s-install` asks for:

- `MENDER_SERVER_URL`: default `https://mender.local`, a host name without
  port or path. It must resolve to this host, through DNS or `/etc/hosts`.
- `EDITION`: `opensource` (default) or `enterprise`.
- `CHART`: `mender/mender` from https://charts.mender.io (default) or the path
  of a local chart, for example `../mender-helm/mender`.
- `IMAGE_TAG`: the tag of all Mender Server images. The edition selects the
  images: `docker.io/mendersoftware/*` (Open Source) or
  `registry.mender.io/mender-server-enterprise/*` (Enterprise). The default is
  the tag last used for that edition, else the chart `appVersion`. Use `main`
  for the latest development build. The kit sets `pullPolicy: Always` for the
  Mender images, so a moving tag such as `main` is pulled again instead of
  reusing an older copy cached on the node.

Test a specific build without prompts, for example:

```bash
EDITION=opensource IMAGE_TAG=v4.1.5 make k3s-install
EDITION=enterprise IMAGE_TAG=v5.0.0-saas.1 make k3s-install
```

Optional: `CHART_VERSION`, `KIT_NAMESPACE` (default `mender`), `EXTRA_VALUES`
(an extra values file, for example to override a single service image),
`HELM_TIMEOUT` (default `15m`). A tag that does not exist shows up as pods in
`ImagePullBackOff` (`make k3s-status`) while Helm waits.

Running `make k3s-install` again upgrades. The URL, edition, chart, image
tag and MongoDB root password of the last install are kept in `.state/` and
offered as defaults. The values file is regenerated each time, so pass
`EXTRA_VALUES` again. The URL and edition of an existing release cannot
change, because its data and TLS certificate belong to them: run
`make k3s-uninstall` first.
The CA certificate is written to `.state/ca.crt`: import it in the browser,
and copy it to devices as `ServerCertificate`. Export it again at any time,
optionally elsewhere, with `make k3s-ca [CA_OUT=path]`; it prints the subject,
expiry and SHA-256 fingerprint.

Clean up with `make k3s-uninstall` (release, namespace with the MongoDB and
RustFS volumes, and the `.state` files of that namespace) or `make k3s-remove`
(K3s with all its data, and all `.state` files).
