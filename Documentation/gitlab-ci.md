# GitLab CI/CD Setup Guide

This document provide a summary of the GitLab documentation, sufficient to setting
up and configuring a new GitLab repository with self-hosted build workers 
(`gitlab-runner`s). This document will only cover a small portion of the 
official documentation - just enough to setup a fresh repository from scratch.

## Local Setup

For the sake of not messing about, this document will use a fresh GitLab server
instance for demoing. To bring up a fresh docker instance with a GitLab server
you can run:

```sh
docker network create gitlab
sudo docker run --detach \
    --hostname gitlab --network gitlab --network-alias gitlab.mender.io \
    --publish 8443:443 --publish 8080:80 --publish 22022:22 \
    --name gitlab \
    --restart unless-stopped \
    --volume ~/.cache/gitlab/config:/etc/gitlab \
    --volume ~/.cache/gitlab/logs:/var/log/gitlab \
    --volume ~/.cache/gitlab:/var/opt/gitlab \
    gitlab/gitlab-ce:latest
```

> The following examples are also applicable to our production CI/CD setup by targeting `gitlab.com` instead of `gitlab.mender.io` and `localhost`.

After the container is setup (this might take a couple of minutes) visit
http://localhost:8080 and enter a password for the user `root`.

Logging in as the root user, you will be greeted by the admin panel. Let's start
of with initializing a new project in a group hierarchy:
1. Go to the "Groups" tab in the upper left and select "Your groups" and then
hit "New group" in the upper right corner.
2. Enter a new group name "Norhern.tech" and click "Create group"
3. Inside the Northern.tech group, create a new subgroup by expanding the button 
next to "New project" in the upper right corner and click "New subgroup".
4. Enter a new subgroup name "Mender" and click "Create group".
5. Inside the Mender subgroup, click "New project" and call it "mender".

Let's leave the project empty for now, we'll revisit it once we've setup a
gitlab-runner.

## GitLab Runner
`gitlab-runner` is a daemon that runs on your worker node to schedule jobs
defined in `.gitlab-ci.yml` in the project root. A project can have multiple
different runners, and like the repository structure, runners can be registered
at multiple different levels of accessibility across projects:
* **Shared runners** are globally accessible to the whole organization.
* **Group runners** are accessible to all projects under a specific group.
* **Project runners** are only accessible to the project/repository itself.
As we will see, which runner is able to process which job for a given repository
is controlled by `tags`. The `gitlab-runner` daemon regularly polls the 
[GitLab API](https://docs.gitlab.com/ee/api/README.html) for pending jobs
under the runner's registered `tags`.

### Installing a new runner
To install a new gitlab-runner instance, follow the 
[official install guide](https://docs.gitlab.com/runner/install/) for installing
on your specific platform. Continuing on our demo, we can create a `gitlab-runner` 
container on our local machine:
```
docker run --rm -it --detach --name gitlab-runner \
    --network gitlab --network-alias gitlab-runner.mender.io \
    -v ~/.cache/gitlab/gitlab-runner:/etc/gitlab-runner \
    -v /var/run/docker.sock:/var/run/docker.sock \
    gitlab/gitlab-runner
```
Now that `gitlab-runner` is up and running, you may notice from the logs that
it's not configured yet. For that we need to register the runner. To register
the runner, we will first need the `registration token` for the type of runner
we want to register. For the three different kinds of runners, these tokens
can be found under:
* **Project runner:** &lt;repository root&gt; -&gt; Settings -&gt; CI/CD -&gt; Runners (expand).
* **Group runner:** &lt;group home&gt; -&gt; -&gt; Settings -&gt; CI/CD -&gt; Runners (expand).
* **Shared runner:** &lt;Admin area&gt;<sup>1</sup> -&gt; Overview -&gt; Runners

<sup>1</sup> To access the admin area you need to be logged in as an Administrator.

```
CI_TOKEN="<insert token>"
docker exec -it gitlab-runner gitlab-runner register \
    --non-interactive \
    --name docker-runner \
    --url http://gitlab.mender.io \
    --registration-token $CI_TOKEN \
    --tag-list linux86-64,demo \
    --executor shell
```
Congratulations! If you refresh the CI/CD settings page on the `mender` project 
a new runner has appeared. Creating jobs with either of the tags `linux86-64` or
`demo` will trigger a job on this instance.


### Configuring the runner
If you inspect the docker container, `gitlab-runner` has just initialized a new
minimal config file at `/etc/gitlab-runner/config.toml`. In this section we 
will in general terms go through some common configuration options, while 
leaving the specifics to the
[documentation](https://docs.gitlab.com/runner/configuration/advanced-configuration.html).

To start with, we silently added the `--executor shell` argument above, which 
runs each job on the same host and as the same user as `gitlab-runner` is 
running. By default, each build will be deployed under the user's home directory
but can be modified by `builds_dir`. Some executors worth mentioning are:
* **shell:** executes the job as the user running the `gitlab-runner` service
on the machine instance itself.
* **docker:** executes a job in a dedicated container on the same host.
* **docker+machine:** provisions a new Dockerized host for each job - supports
auto-scaling for running instances on Google Cloud Platform, Amazon AWS and
Azure Cloud.
* **kubernetes:** executes jobs inside Kubernetes pods and naturally supports
auto-scaling as well.

All executors with the exception of `shell` has a specific configuration section
`runner.<executor>` allowing customization specific to the executor platform.
Other sections worth mentioning are the global section, which stores options
such as number of allowed `concurrent` jobs. And finally, to speed up jobs
running on distributed hosts (such as `docker+machine`), a `runners.cache` 
section allows caching jobs to `s3` or `gcp` buckets for reuse in shared and 
subsequent jobs.

In closing it is emphasizing that the `runners` section is specified as an TOML
array, hence it's possible to configure multiple runners in a single 
configuration file. We close this section with an example configuration using
a local `shell` executor and a `docker+machine` one running on `GCP`:
```toml
concurrent = 8      # Total number of concurrent jobs
check_interval = 0  # Default poll interval
[session_server]
  session_timeout = 1800

# shell runner
[[runners]]
  name = "test"
  url = "http://gitlab.mender.io"
  token = "<token received by POST /runners/register>"
  executor = "docker"

# docker+machine runner
[[runners]]
  limit = 7                   # This runner can excute up to 7 jobs
  name = "gitlab-machine"
  url = "https://gitlab.com/"
  token = "<token received by POST /runners/register>"
  executor = "docker+machine"
  output_limit = 512000
  [runners.docker]
    tls_verify = false
    image = "ubuntu:18.04"              # The default image used by jobs
    privileged = true
    volumes = ["/dev/shm:/dev/shm", "/cache"]
    shm_size = 8589934592
  [runners.machine]
    IdleTime = 300  # How many seconds nodes can remain idle before getting killed
    # MachineDriver: See https://docs.docker.com/machine/drivers/ for a
    # comprehensive list of supported platforms.
    MachineDriver = "google" 
    MachineName = "gitlab-worker-%s"
    OffPeakPeriods = [
      "* * 0-7,20-23 * * mon-fri *",
      "* * * * * sat,sun *"
    ]
    # MachineOptions GCP-specific options, see https://docs.docker.com/machine/drivers/gce/
    # for a comprehensive list.
    MachineOptions = [
      "google-project=gitlab-runners-project",
      "google-machine-type=n1-standard-8",
      "google-disk-size=100",
      "google-machine-image=ubuntu-os-cloud/global/images/family/ubuntu-1804-lts",
      "google-tags=gitlab-worker",
      "google-zone=northamerica-northeast1-b",
      "google-use-internal-ip=true",
    ]
```

#### Mender's gitlab-master configuration reference

The content of `/etc/gitlab-runner/config.toml` at the time of writing follows:

```
concurrent = 40
check_interval = 0

[session_server]
  session_timeout = 1800

[[runners]]
  name = "mender-qa-master"
  limit = 40
  output_limit = 512000
  url = "https://gitlab.com/"
  token = "<edited>"
  executor = "docker+machine"
  [runners.custom_build_dir]
  [runners.cache]
  [runners.docker]
    tls_verify = false
    image = "ubuntu:22.04"
    privileged = true
    disable_entrypoint_overwrite = true
    oom_kill_disable = false
    disable_cache = false
    volumes = ["/dev/shm:/dev/shm", "/cache", "/dind/certs:/certs"]
    shm_size = 8589934592
  [runners.machine]
    IdleCount = 0
    IdleScaleFactor = 0.0
    IdleCountMin = 0
    IdleTime = 300
    MachineDriver = "google"
    MachineName = "gitlab-runner-slave-%s"
    MachineOptions = ["google-project=mender-gitlab-runners", "google-machine-type=n2-standard-16", "google-disk-size=100", "google-machine-image=https://www.googleapis.com/compute/v1/projects/mender-gitlab-runners/global/images/nested-virt-ubuntu-2204-jammy-v20221011", "google-tags=mender-qa-slave", "google-zone=northamerica-northeast1-b", "google-use-internal-ip=true", "google-scopes=https://www.googleapis.com/auth/devstorage.read_write,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/cloud-platform"]

[[runners]]
  name = "mender-qa-master"
  limit = 40
  output_limit = 512000
  url = "https://gitlab.com/"
  token = "<edited>"
  executor = "docker+machine"
  [runners.custom_build_dir]
  [runners.cache]
  [runners.docker]
    tls_verify = false
    image = "ubuntu:22.04"
    privileged = true
    disable_entrypoint_overwrite = true
    oom_kill_disable = false
    disable_cache = false
    volumes = ["/dev/shm:/dev/shm", "/cache", "/dind/certs:/certs"]
    shm_size = 8589934592
  [runners.machine]
    IdleCount = 0
    IdleScaleFactor = 0.0
    IdleCountMin = 0
    IdleTime = 300
    MachineDriver = "google"
    MachineName = "gitlab-runner-slave-%s"
    MachineOptions = ["google-project=mender-gitlab-runners", "google-machine-type=n2-highcpu-16", "google-disk-size=100", "google-machine-image=https://www.googleapis.com/compute/v1/projects/mender-gitlab-runners/global/images/nested-virt-ubuntu-2204-jammy-v20221011", "google-tags=mender-qa-slave", "google-zone=northamerica-northeast1-b", "google-use-internal-ip=true", "google-scopes=https://www.googleapis.com/auth/devstorage.read_write,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/cloud-platform"]
```

## .gitlab-ci.yml
We are now in a position where we can finally start implementing the CI job
definitions, i.e. the `.gitlab-ci.yml` file. This file must be at the root of
the repository in order to be picked up by GitLab CI. Once again, GitLab provides
[extensive documentation](https://docs.gitlab.com/ee/ci/yaml/) on the layout of 
this yaml file. This document will only go through the most basic stuff to 
complete our demo.

A `.gitlab-ci.yml` defines the CI/CD pipeline for the project repository, and 
each pipeline is structured as a sequence of jobs. A job is defined as a yaml
object with a key name not in the set of 
[reserved keywords](https://docs.gitlab.com/ee/ci/yaml/#unavailable-names-for-jobs). 
A job is typically defined using the following keywords<sup>1</sup>:
| **Keyword**   | **Value**                           | **Description**                                                             |
| --------      | ---------                           | -----------                                                                 |
| tags          | list of tags (string)               | List of tags to select gitlab-runner.                                       |
| **script**    | list of shell commands              | Shell script executed by the runner (the job itself). *Required*            |
| after_script  | list of shell commands              | Set of commands to run after script section.                                |
| before_script | list of shell commands              | Set of commands to run before script section.                               |
| image         | string                              | Name of docker image to run the tests in (not available for shell executor) |
| stage         | string                              | Pipeline stage to run the job. (defaults to "test")                         |
| artifacts     | object{paths,expire_in} (typically) | List of files/directories to attach to a job on success                     |
| dependencies  | string <job name>                   | Restrict artifacts passed to the job.                                       |

<sup>1<sup> This is just a small subset of
[full list](https://docs.gitlab.com/ee/ci/yaml/#configuration-parameters) 
of keywords available, please consult with the 
[docs](https://docs.gitlab.com/ee/ci/yaml/#configuration-parameters)
for extensive descriptions of the parameters.

Jobs can further be separated into `stages` to run in parallel. Stages are 
defined using the reserved keyword `stages` in the root of the yaml file, and
takes an array of names for the different stages of the pipeline.

Continuing on our demo, let's make a simple "hello world" CI pipeline echoing
"Hello world!" into an artifact passed to a second job which echoes the file to
the terminal:
```yaml
# .gitlab-ci.yml
stages:
  - hello
  - world
  
hello:
  stage: hello
  tags:
    - demo
  script:
    - echo "Hello world!" > hello.txt
  artifacts:
    paths:
      - hello.txt
    expire_in: 1d
  
world:
  stage: world
  tags:
    - demo
  dependencies:
    - hello
  script:
    - cat hello.txt
```
Pushing the above `.gitlab-ci.yml` to the repository 
(http://localhost:8080/Northern.tech/Mender/mender), you can see the job 
automatically getting triggered, and opening the pipeline in the sidebar
(CI/CD -&gt; Pipelines) you will see that the two jobs has already passed.

## Other nifty features

* **Repository mirroring:** Can be configured under Project -&gt; 
Settings -&gt; Repository -&gt; Mirroring repositories and supports mirroring
repositories both ways, i.e. both push and pull<sup>1</sup>.
* **Asyclic job dependencies:** For a more fine-grained control over 
`gitlab-ci.yml` job dependencies, a job can express execution dependencies 
using the [needs](https://docs.gitlab.com/ee/ci/yaml/#needs) keyword. This allows
starting a job before the entire previous stage has finished given the jobs listed
in the `needs` value are finished.

<sup>1</sup> Pull mode repository mirroring is only available in the enterprise plan.

The GitLab UI is pretty self-documenting, and it can be worth spending some
time clicking around in the [Dockerized](#local-setup) to other features not 
covered in this document. Moreover, the 
[GitLab documentation](https://docs.gitlab.com/ee/README.html) is very well 
structured and easy to navigate.
