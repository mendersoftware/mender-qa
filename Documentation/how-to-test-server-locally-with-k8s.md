# Testing Mender Server Locally with k8s

This guide describes how to install Mender Server (both Open Source and Enterprise versions) using Kubernetes inside a virtual machine (Vagrant setup).

## Virtual Machine Setup

### Prerequisites

First install Vagrant using [Vagrant installation instructions](https://developer.hashicorp.com/vagrant/install). You also might need additional plugins depending on your virtualization setup.

**For libvirt users** (can be different if using VirtualBox):
```bash
sudo apt install libvirt-dev
vagrant plugin install vagrant-libvirt

# Add your user to libvirt group
sudo usermod -aG libvirt $USER
newgrp libvirt
```

### Create Virtual Machine

Next create a virtual machine where Mender Server will be installed (using generic Debian 12 image):

```bash
mkdir mender-virtual-server
cd mender-virtual-server
vagrant init generic/debian12
```

Above will create a `Vagrantfile` in your working directory. Edit it to add the required configuration.
Please configure the `config.vm.provider` section like below to install required
tools:

```ruby
# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.box = "generic/debian12"

  config.vm.provider "libvirt" do |libvirt|
    # 4GB RAM (8GB recommended for Enterprise); if you see issues increase to 8GB (12 GB for Enterprise)
    libvirt.memory = "4096"
    # 4 CPUs (6 recommended for Enterprise)
    libvirt.cpus = "4"       # 4 CPUs
  end

  # Set up port forwarding so that we will be able to access Mender UI
  # from the host machine.
  #config.vm.network "forwarded_port", guest: 443, host: 8443, host_ip: "127.0.0.1"
  config.vm.network "private_network", ip: "192.168.56.10"

  config.vm.provision "shell", inline: <<-SHELL
    apt-get update
    apt-get install -y tmux
    sh -c 'echo "127.0.0.1 mender.local" >> /etc/hosts'
    curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
    echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> /home/vagrant/.bashrc
    curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
    curl -s https://fluxcd.io/install.sh | sudo bash
  SHELL
end
```

On the host machine add static VM IP address to `/etc/hosts`. This is required for the ingress controller configuration and accessing UI form the host machine:
```bash
sudo sh -c 'echo "192.168.56.10 mender.local" >> /etc/hosts'
```

Once the configuration is done, start the virtual machine and SSH to it:
```bash
vagrant up --provider=libvirt
vagrant ssh
```

## Mender Server Setup

Once inside the virtual machine, we will set up and start Mender Server. The instructions below contain steps required for both Open Source and Enterprise.

### Overview

For a local test environment, we use:
- **k3s** (lightweight Kubernetes)
- **Included MongoDB, NATS, and Redis** (from Helm Chart; this is not recommended for production but is fine for testing)
- **SeaweedFS** for S3-compatible storage
- **Self-signed certificates** using OpenSSL
- **Local domain** using /etc/hosts

### System Preparation

The required tools like k3s (lightweight Kubernetes), Helm and Flux, are already
installed from the Vagrantfile. You can verify them:

Verify installation:
```bash
kubectl get nodes
```

Expected output:
```
NAME                   STATUS   ROLES                  AGE   VERSION
debian12.localdomain   Ready    control-plane,master   1m    v1.33.x+k3s1
```

Verify Helm installation:
```bash
helm version
```

Verify Flux installation:
```bash
flux --version
```

### Generate Self-Signed Certificate

```bash
# Create directory for certificates
mkdir -p ~/mender-certs
cd ~/mender-certs

# Generate private key
openssl genrsa -out mender.key 2048

# Generate certificate signing request
openssl req -new -key mender.key -out mender.csr \
  -subj "/C=US/ST=State/L=City/O=Mender/CN=mender.local"

# Generate self-signed certificate (valid for 365 days)
openssl x509 -req -days 365 -in mender.csr -signkey mender.key -out server.crt \
  -extfile <(printf "subjectAltName=DNS:mender.local")

# Create Kubernetes TLS secret
kubectl create secret tls mender-ingress-tls \
  --cert=server.crt \
  --key=mender.key

# Verify secret was created
kubectl get secret mender-ingress-tls
```

### Install SeaweedFS (Local S3-Compatible Storage) and Mender from nt-iac

You can follow instructions below or [official Mender guide](https://docs.mender.io/server-installation/production-installation-with-kubernetes/storage).

Set up storage configuration:
```bash
# Generate random values
export ADMIN_KEY=$(openssl rand -hex 16)
export ADMIN_SECRET=$(openssl rand -hex 32)
export READ_KEY=$(openssl rand -hex 16)
export READ_SECRET=$(openssl rand -hex 32)

# Create the SeaweedFS secret
kubectl create secret generic seaweedfs-mender-s3-secret \
  --from-literal=admin_access_key_id="$ADMIN_KEY" \
  --from-literal=admin_secret_access_key="$ADMIN_SECRET" \
  --from-literal=read_access_key_id="$READ_KEY" \
  --from-literal=read_secret_access_key="$READ_SECRET" \
  --from-literal=seaweedfs_s3_config="{\"identities\":[{\"name\":\"anvAdmin\",\"credentials\":[{\"accessKey\":\"$ADMIN_KEY\",\"secretKey\":\"$ADMIN_SECRET\"}],\"actions\":[\"Admin\",\"Read\",\"Write\"]},{\"name\":\"anvReadOnly\",\"credentials\":[{\"accessKey\":\"$READ_KEY\",\"secretKey\":\"$READ_SECRET\"}],\"actions\":[\"Read\"]}]}"

# Create the Mender secret
kubectl create secret generic mender-s3-artifacts \
  --from-literal=AWS_AUTH_KEY="$ADMIN_KEY" \
  --from-literal=AWS_AUTH_SECRET="$ADMIN_SECRET" \
  --from-literal=AWS_BUCKET="mender-artifacts-storage-seaweedfs" \
  --from-literal=AWS_FORCE_PATH_STYLE="true" \
  --from-literal=AWS_URI="http://seaweedfs-s3:8333" \
  --from-literal=AWS_REGION="us-east-1"
```

Install Flux components:
```bash
flux install 
```

Expected output:
```
✔ helm-controller: deployment ready
✔ kustomize-controller: deployment ready
✔ notification-controller: deployment ready
✔ source-controller: deployment ready
✔ install finished
```

Create the Github Secret needed to fetch from nt-iac repository
```bash
export GITHUB_TOKEN=<gh-token>

flux create secret git github-auth \
  --url=https://github.com/NorthernTechHQ/nt-iac \
  --username=git \
  --password=${GITHUB_TOKEN}
```

#### Open Source Configuration

Bootstrap the cluster with Flux:
```bash
flux create source git nt-iac \
  --url=https://github.com/NorthernTechHQ/nt-iac \
  --branch=main \
  --interval=1m \
  --secret-ref=github-auth

flux create kustomization manifests \
  --source=GitRepository/nt-iac \
  --path="./manifests/test-k3s-opensource" \
  --prune=true \
  --interval=10m
```

Expected output:
```
✚ generating Kustomization
► applying Kustomization
✔ Kustomization created
◎ waiting for Kustomization reconciliation
✔ Kustomization manifests is ready
✔ applied revision main@sha1
```

#### Enterprise Configuration

Create the Mender Enterprise Registry secret:
```bash
export MENDER_REGISTRY_USERNAME="your-username"
export MENDER_REGISTRY_PASSWORD="your-password"
export MENDER_REGISTRY_EMAIL="your-email@example.com"

kubectl create secret docker-registry my-mender-pull-secret \
  --docker-username=${MENDER_REGISTRY_USERNAME} \
  --docker-password=${MENDER_REGISTRY_PASSWORD} \
  --docker-email=${MENDER_REGISTRY_EMAIL} \
  --docker-server=registry.mender.io

```

Bootstrap the cluster with Flux:
```bash
flux create source git nt-iac \
  --url=https://github.com/NorthernTechHQ/nt-iac \
  --branch=main \
  --interval=1m \
  --secret-ref=github-auth

flux create kustomization manifests \
  --source=GitRepository/nt-iac \
  --path="./manifests/test-k3s-enterprise" \
  --prune=true \
  --interval=10m
```

Expected output:
```
✚ generating Kustomization
► applying Kustomization
✔ Kustomization created
◎ waiting for Kustomization reconciliation
✔ Kustomization manifests is ready
✔ applied revision main@sha1
```

### Monitor Installation Progress

In another terminal, you can monitor pod status:
```bash
kubectl get pods -w
```

After about 10 minutes, verify SeaweedFS and Mender are running:

```bash
kubectl get pods
```

Expected output:
```bash
NAME                                             READY   STATUS    RESTARTS      AGE
mender-api-gateway-99664d6c5-vgs2r               1/1     Running   0             81s
mender-auditlogs-9b8cc954d-8g2cf                 1/1     Running   0             82s
mender-create-artifact-worker-6df9f9b9f4-2ln95   1/1     Running   2 (60s ago)   81s
mender-deployments-847f6fdf65-zxmzj              1/1     Running   0             82s
mender-device-auth-56bdb6b6bf-shx5t              1/1     Running   0             81s
mender-deviceconfig-cd77d69dd-tzg2t              1/1     Running   0             81s
mender-deviceconnect-9d7579556-jz98g             1/1     Running   0             81s
mender-devicemonitor-6f67c7b98c-6442q            1/1     Running   0             81s
mender-generate-delta-worker-0                   1/1     Running   2 (54s ago)   82s
mender-gui-cdfb6946f-885p6                       1/1     Running   0             82s
mender-inventory-9665fb57c-v4k8d                 1/1     Running   0             82s
mender-iot-manager-7774c4b467-9r4nn              1/1     Running   0             82s
mender-mongodb-69f86b6997-tvcdv                  1/1     Running   0             5m51s
mender-nats-0                                    3/3     Running   0             82s
mender-nats-1                                    3/3     Running   0             82s
mender-nats-2                                    3/3     Running   0             82s
mender-nats-box-65d659fd84-f94sp                 1/1     Running   0             82s
mender-tenantadm-79889477c8-fh94t                1/1     Running   0             82s
mender-useradm-6c5f597f5f-fsvm4                  1/1     Running   0             82s
mender-workflows-server-754c9cb6b4-bxsg4         1/1     Running   2 (68s ago)   82s
mender-workflows-worker-84cc9d4cbf-7m5lt         1/1     Running   3 (54s ago)   82s
seaweedfs-filer-0                                1/1     Running   0             5m50s
seaweedfs-master-0                               1/1     Running   0             5m50s
seaweedfs-s3-789f788758-n944c                    1/1     Running   0             5m50s
seaweedfs-volume-0                               1/1     Running   0             5m50s
```

## Create Users

The user creation process differs between Open Source and Enterprise versions.

### Open Source: Create Admin User

```bash
# Create admin user
USERADM_POD=$(kubectl get pod -l 'app.kubernetes.io/component=useradm' -o name | head -1)
kubectl exec $USERADM_POD -- useradm create-user \
  --username "admin@mender.local" \
  --password "adminpassword"
```

Expected output of the command is user id.

### Enterprise: Create Organization and Admin User

Enterprise uses a multi-tenant architecture. You need to create an organization and admin user:

```bash
# Create organization and admin user
TENANTADM_POD=$(kubectl get pod -l 'app.kubernetes.io/component=tenantadm' -o name | head -1)

TENANT_ID=$(kubectl exec $TENANTADM_POD -- tenantadm create-org \
  --name "Acme" \
  --username "admin@mender.local" \
  --password "adminpassword" \
  --addon troubleshoot \
  --addon monitor \
  --addon configure \
  --plan enterprise)

echo "Tenant ID: $TENANT_ID"

# Save tenant ID for future use
echo $TENANT_ID > ~/mender-tenant-id.txt
```

### Enterprise: Create Additional Users (Optional)

```bash
# Get the tenant ID
TENANT_ID=$(cat ~/mender-tenant-id.txt)
USERADM_POD=$(kubectl get pod -l 'app.kubernetes.io/component=useradm' -o name | head -1)

# Create a regular user
kubectl exec $USERADM_POD -- useradm create-user \
  --username "user@mender.local" \
  --password "userpassword" \
  --tenant-id $TENANT_ID
```

## Access Mender UI

Open your browser **on the host machine** (not in the virtual machine, as we have port forwarding set up) and navigate to the IP address of your VM:

```
https://mender.local/
```

**Login credentials:**

For Open Source or Enterprise admin:
- Username: `admin@mender.local`
- Password: `adminpassword`

For Enterprise regular user:
- Username: `user@mender.local`
- Password: `userpassword`

**Note:** Since we are using a self-signed certificate, you will see a warning that the connection is not trusted. Click "Advanced" and proceed with connecting to your Mender Server.

## Verify Installation

Check all pods are running:
```bash
kubectl get pods
```

All pods should show `Running` or `Completed` status.

Check services:
```bash
kubectl get svc
kubectl get ingress
```

View logs if needed:
```bash
# Example: Check deployments service logs
kubectl logs mender-device-auth-6745b98c5b-k6dkp --tail=50
```

## Upgrade Mender Server

Specify the version to run (or upgrade to) the Mender Server by running the following command (same command for both Open Source and Enterprise):

```bash
VERSION=v4.1.0-saas.16

kubectl create configmap mender-override-values \
  --from-literal=mender-override-values.yaml='default:
  image:
    tag: "'$VERSION'"'
```

## Run a Pull Request build (Feature Branch Deployment)

Specify a build from a Pull Request, from Gitlab:

```bash
# Create a Gitlab Registry Secret
export GITLAB_REGISTRY_USERNAME="your-username"
export GITLAB_REGISTRY_TOKEN="your-password"
export GITLAB_REGISTRY_EMAIL="your-email@example.com"

kubectl create secret docker-registry my-gitlab-registry-secret \
  --docker-username=${GITLAB_REGISTRY_USERNAME} \
  --docker-password=${GITLAB_REGISTRY_TOKEN} \
  --docker-email=${GITLAB_REGISTRY_EMAIL} \
  --docker-server=registry.gitlab.com

# Your build version that you can find in Gitlab CICD pipeline for the pr, like:
# VERSION=build-2caec8af4113366eeb7b16905200d45a80d4eebd

VERSION="your-build-version"

kubectl create configmap mender-override-values \
  --from-literal=mender-override-values.yaml='default:
  image:
    registry: registry.gitlab.com
    repository: northern.tech/mender/mender-server-enterprise
    tag: "'$VERSION'"
  imagePullSecrets:
    - name: my-gitlab-registry-secret'
    
```


## Tearing Down the Installation

### Uninstall Mender

```bash
helm uninstall mender
```

After uninstalling, you should see only SeaweedFS and MongoDB pods running:
```bash
kubectl get pods
```

Output:
```
NAME                              READY   STATUS    RESTARTS   AGE
mender-mongodb-76c76666d8-xxxxx   1/1     Running   0          15h
seaweedfs-filer-0                 1/1     Running   0          16h
seaweedfs-master-0                1/1     Running   0          16h
seaweedfs-s3-5c88cbd4c8-xxxxx     1/1     Running   0          16h
seaweedfs-volume-0                1/1     Running   0          16h
```

### Clean Up MongoDB

MongoDB persists due to Helm hook behavior. Remove it manually:
```bash
kubectl delete deployment mender-mongodb
```

### Complete Cleanup (Optional)

To remove everything including SeaweedFS:
```bash
# Uninstall SeaweedFS
helm uninstall seaweedfs

# Delete all resources
kubectl delete all,configmap,secret,pvc -l app.kubernetes.io/instance=mender
kubectl delete all,configmap,secret,pvc -l app.kubernetes.io/instance=seaweedfs

# Delete TLS secret
kubectl delete secret mender-ingress-tls

# Verify cleanup
kubectl get all
```

### Destroy the Virtual Machine (Optional)

On your host machine:
```bash
cd mender-virtual-server
vagrant destroy -f
```

## Client configuration

First copy `server.crt` from the VM to a known path on your host machine

```
vagrant ssh-config
```

Check `HostName` and `IdentityFile` from the command above

```
HOST=...
IDFILE=...
DEST=$HOME/...
scp -i $IDFILE vagrant@$HOST:/home/vagrant/mender-certs/mender.crt $DEST
```

### Yocto project

Follow https://docs.mender.io/operating-system-updates-yocto-project/build-for-production#preparing-the-server-certificates-on-the-client

For example by adding something like the following to your `local.conf`:

```
FILESEXTRAPATHS:prepend:pn-mender-server-certificate := "/home/lluis/mender-virtual-server/:"
SRC_URI:append:pn-mender-server-certificate = " file://server.crt"
IMAGE_INSTALL:append = " mender-server-certificate"
```

### Debian family

TODO

### Zephyr (preview)

TODO
