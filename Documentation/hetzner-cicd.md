# Hetzner Hosting GitLab CI/CD runners

This document provide a summary of the Gitlab Runner infrastructure hosted
in Hetzner hosts, both bare-metal and VMs.

- [Hetzner Hosting GitLab CI/CD runners](#hetzner-hosting-gitlab-cicd-runners)
  - [Node list](#node-list)
    - [Hetzner EX130-R](#hetzner-ex130-r)
    - [Hetzner AX41-NVMe](#hetzner-ax41-nvme)
    - [Hetzner CAX21](#hetzner-cax21)
    - [Hetzner VM Podman cpx31 gitlab-runner-podman-01](#hetzner-vm-podman-cpx31-gitlab-runner-podman-01)
    - [Hetzner VM for Zephyr testing](#hetzner-vm-for-zephyr-testing)
    - [Hetzner AX42](#hetzner-ax42)
  - [Secrets](#secrets)


## Node list

### Hetzner EX130-R
* Node type: bare-metal
* IP: 49.12.169.71
* Connection string:
  ```bash
  eval `ssh-agent` && \
  pass show mender/cicd/hetznercloud/gitlab-hetzner-ax41-runner-ssh_key-priv.pem | ssh-add - && \
  ssh root@49.12.169.71
  ```

### Hetzner AX41-NVMe
* Node type: bare-metal
* IP: 65.108.231.138 
* Connection string:
  ```bash
  eval `ssh-agent` && \
  pass show mender/cicd/hetznercloud/gitlab-hetzner-ax41-runner-ssh_key-priv.pem | ssh-add - && ssh root@65.108.231.138
  ```

### Hetzner CAX21
* Node type: Cloud VM
* IP: `192.168.84.3` (behind jumphost)
* Console access: https://console.hetzner.cloud/projects/2768387/servers
* Connection string:
  ```bash
  eval `ssh-agent` && \
  pass show mender/cicd/hetznercloud/ssh_key-01-priv.pem | ssh-add - && \
  ssh -J root@49.13.211.148 root@192.168.84.3
  ```

### Hetzner VM Podman cpx31 gitlab-runner-podman-01
* Node type: Cloud VM
* IP: `5.75.240.59`
* Console access: https://console.hetzner.cloud/projects/2768387/servers
* Connection string:
  ```bash
  eval `ssh-agent` && \
  pass show mender/cicd/hetznercloud/ssh_key-01-priv.pem | ssh-add - && \
  ssh root@5.75.240.59 -p 4242
  ```

### Hetzner VM for Zephyr testing
* [Internal documentation](https://github.com/NorthernTechHQ/sre-iac/tree/main/hetzner-zephyr-qa)


### Hetzner AX42
* Node type: bare-metal
* IP: `5.9.120.171`
* Connection string:
  ```bash
  eval `ssh-agent` && \
  pass show mender/cicd/hetznercloud/gitlab-hetzner-ax41-runner-ssh_key-priv.pem | ssh-add - && ssh root@5.9.120.171
  ```


## Secrets

The Hetzener hosts are using the Docker Hub user `northerntechreadonly` to pull
the images. The password is stored in the `mender/cicd/docker.com/northerntechreadonly`
mystiko entry.
