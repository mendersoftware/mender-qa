# Mender CI/CD

This document contains various guides and how-to's for topics around our current
CI/CD setup using GitLab on Google Cloud Platform (GCP). For a basic introduction
to GitLab, refer to the dedicated guide in `gitlab-ci.md`.


## GitLab's master runner dependencies

We have only one permanent machine in GCP. It receives requests from GitLab for running jobs and
then launches, and configures "workers" to perform the actual CI job.

This machine requires three pieces of software:
* `gitlab-runner` to communicate with GitLab backend
* `docker-machine` to launch the workers in GCP and install/configure Docker in them
* `docker` as a dependency of the above.

### Installing `gitlab-runner`

We install the GitLab runner from GitLab's APT repositories. Follow
[this guide](https://docs.gitlab.com/runner/install/linux-repository.html#installing-gitlab-runner)
for more details.

In a nutshell:
```
curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | sudo bash
sudo apt-get install gitlab-runner
```

See [gitlab-ci.md](gitlab-ci.md#menders-gitlab-master-configuration-reference) for a sample of
our latest configuration settings.

### Installing `docker-machine`

Docker's `docker-machine` is out of support. GitLab's maintain their own fork while they develop
a full solution to replace the autoscaling functionality. Whenever this is in place we will migrate
to the new software stack. More details of this plan in these links:
* https://docs.gitlab.com/runner/configuration/autoscale.html
* https://gitlab.com/groups/gitlab-org/-/epics/2502
* https://gitlab.com/gitlab-org/gitlab/-/issues/341856

We install GitLab's fork of `docker-machine` from the direct downloads of GitLab repo. Browse
[this page](https://gitlab.com/gitlab-org/ci-cd/docker-machine/-/releases) to find the latest
release and install it manually.

In a nutshell:
```
curl -O "https://gitlab-docker-machine-downloads.s3.amazonaws.com/v0.16.2-gitlab.18/docker-machine-Linux-x86_64"
sudo cp docker-machine-Linux-x86_64 /usr/local/bin/docker-machine
sudo chmod +x /usr/local/bin/docker-machine
```

### Installing `docker`

We install Docker from official Ubuntu repositories, so just:
```
sudo apt-get install docker.io
```


## Enable KVM acceleration on GCP
Enabling KVM on Google Cloud's Compute Engine there are two steps:
1. Create a KVM-enabled custom image using the following license URL: `https://compute.googleapis.com/compute/v1/projects/vm-options/global/licenses/enable-vmx`
2. Install and enable kvm module for qemu

For step one, assuming you have [google-cloud-sdk](https://cloud.google.com/sdk) 
installed and initialized to current GCP project, the following command will 
create a new `Ubuntu 18.04` image with kvm enabled:
```shell
gcloud compute images create <image-name> \
    --source-image-project=ubuntu-os-cloud \
    --source-image-family=ubuntu-1804-lts \
    --licenses="https://www.googleapis.com/compute/v1/projects/vm-options/global/licenses/enable-vmx"
```

There is a script and a systemd timer service in this repository under 
`scripts/gcloud-kvm-image` that periodically checks for new Ubuntu 18.04 
releases and creates a new kvm enabled image and updates the gitlab config in 
`/etc/gitlab-runner/config.toml`.

NOTE: To apply the to apply the KVM-enabled image to the gitlab-runners using 
`docker+machine` autoscaling build hosts, update the configuration option 
`google-machine-image` under `runners.machine.Machineoptions` with image URI.
The image URI can be aquired from the SDK from with following command:
```
gcloud compute images list --uri --filter="name~'^<image-name>$'"
```

For step two, on Ubuntu 18.04 we need to install `qemu-kvm` package along with
dependencies required for running nested VMs, and then reload the 
`kvm_(intel|amd)` kernel module with flag `nested=Y` to enable nesting VMs. 
Moreover, using kvm within qemu requires the user to belong to the `kvm` group. 
So, to summarize here's a short snippet installing and loading the kvm kernel 
module for the user `mender`:
```shell
sudo apt-get install -y kmod libvirt-bin qemu-utils qemu-kvm
sudo apt-get install -y "linux-modules-$(uname -r)"
sudo usermod -a -G kvm mender

# Reload the kvm_intel with nesting enabled.
sudo modprobe -r kvm_intel
sudo modprobe kvm_intel nested=Y # nested=Y enables nested VMs
```


## NFS sstate-cache
For caching Bitbake's shared state across (parallel) builds we use a dedicated
NFS server instance for serving the cache across builds. This part will briefly
go through setting up the NFS server and mounting it on the client side (gitlab
worker instance).

### Setting up an NFS server
Setting up an NFS server consists of installing the NFS-server package
and configuring exported directories. On Debian based system, the default nfs 
server package is the `nfs-kernel-server`, which provides a systemd service 
and is configured using standard exports(5). Another user-space fuse-based 
alternative is the `nfs-ganesha` implementation, however, this section will only
demonstrate setting up the kernel server.


Instead of listing all the configuration options for exports(5), the following 
provides a brief example installing `nfs-kernel-server` and exporting the 
directory `/sstate-cache` as read/write to all hosts on the sub-net `192.168.1.0/24`
and making it read-only for hosts outside this range.
```
sudo apt-get install -y nfs-common nfs-kernel-server
sudo mkdir -p /sstate-cache
sudo chown -R 1000:1000 /sstate-cache # Set the owner

# Mount the NFS drive
sudo tee -a /etc/fstab > /dev/null << EOF
UUID=3e4b3f08-6e97-464e-a03c-8e10124b3357   /sstate-cache    ext4    defaults    0    0
EOF
sudo mount -a

# See exports(5) for detailed description of configuration options to /etc/exports
sudo tee -a /etc/exports > /dev/null << EOF
/sstate-cache 10.162.0.0/20(rw,insecure,no_subtree_check,all_squash,anonuid=1010,anongid=1010) *(ro,insecure,no_subtree_check,all_squash,anonuid=1010,anongid=1010)
EOF

sudo systemctl start nfs-server && sudo systemctl enable nfs-server
```
The NFS exports are configured in `/etc/exports` and may contain a series of
entries of the form.
```
<export-path> <hostrange(CIDR)>(<options>) [<hostrange(CIDR)>(<options>)...]
```
In the example above, the `all_squash` maps all uids and gids to the anonymous 
user, and the `anonuid,anongid` options fixes the clients user and group ids. 
Moreover, the `insecure` option lifts the restrictions that inbound client must 
use reserved ports (<= 1024) for accessing the directory.

Use command `exportfs` to verify that NFS exports are being exposed correctly:
```
sudo exportfs -v
```

If you plan on exposing an NFS export outside the local area network, you will
have to setup an additional firewall rule for the configured NFS port 
(default: 2049). To create a new firewall rule, enter "VPC Network" -> 
"Firewall" in the navigation menu and select "Create Firewall Rule". To apply
the rule, update the NFS server instance tags to include the tag corresponding
to the new rule.


### Mounting a remote NFS directory
Mounting an exported NFS directory is almost as easy as mounting a local device,
the only additional requirement is having the NFS driver installed and a URI to
the remote instance. The following example snippets mounts the exported directory
`sstate-cache` running on the same `localhost` to the `/mnt` directory.
```
NFS_URI="localhost"
sudo apt-get install -y nfs-common
sudo mount.nfs4 $NFS_URI:/sstate-cache /mnt
```

> The Yocto CI pipeline [expects](https://github.com/mendersoftware/mender-qa/blob/7f733b65cbc9c0aabbaa8f09f56a8ef7703c3073/scripts/jenkins-yoctobuild-build.sh#L153) the sstate-cache to be mounted at `/mnt/sstate-cache`
