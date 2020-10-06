# Mender CI/CD

This document contains various guides and how-to's for topics around our current
CI/CD setup using GitLab on Google Cloud Platform (GCP). For a basic introduction
to GitLab, refer to the dedicated guide in `gitlab-ci.md`.


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
directory `/nfs-dir` as read/write to all hosts on the sub-net `192.168.1.0/24`
and making it read-only for hosts outside this range.
```
sudo apt-get install -y nfs-common nfs-kernel-server
sudo mkdir -p /nfs-dir
sudo chown -R 1000:1000 /nfs-dir # Set the owner 

# See exports(5) for detailed description of configuration options to /etc/exports
sudo cat << EOF >> /etc/exports
/nfs-dir 192.168.1.0/24(rw,insecure,all_squash,anonuid=1000,anongid=1000) *(ro,insecure,all_squash,anonuid=1000,anongid=1000)
EOF

systemctl start nfs-server && systemctl enable nfs-server
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
`nfs-dir` running on the same `localhost` to the `/mnt` directory.
```
NFS_URI="localhost"
sudo apt-get install -y nfs-common
sudo mount.nfs4 $NFS_URI:/nfs-dir /mnt
```

> The Yocto CI pipeline [expects](https://github.com/mendersoftware/mender-qa/blob/7f733b65cbc9c0aabbaa8f09f56a8ef7703c3073/scripts/jenkins-yoctobuild-build.sh#L153) the sstate-cache to be mounted at `/mnt/sstate-cache`
