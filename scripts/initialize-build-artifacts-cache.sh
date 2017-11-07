#!/bin/bash

set -e -x

# Script that creates an artifacts-cache machine.
# It is expected that this script run as root.

useradd -m -u 1010 jenkins

# Fetch SSH keys from the initalize-build-host.sh script.
eval "$(sed -ne "/^SSH_KEYS=/ {p; n; :start; /'/ {p; b;}; p; n; b start;}" $(dirname $0)/initialize-build-host.sh)"
mkdir -p /home/jenkins/.ssh
echo "$SSH_KEYS" >> /home/jenkins/.ssh/authorized_keys

# Make sure the build slave key is there.
cat >> /home/jenkins/.ssh/authorized_keys <<EOF
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDWAr0/N60rxPIr8rg4xyJFY6fSMdlFb+Y0ruCNqcwg/H2meIwTnISW/RCzGv5iTkpoY6KGpCQeBIGbiRa4O8l4s9uoSls1AhDmCL82ccIokitIipPOYboi3Dl1YEF8Nze1xWTjnoFMjiAU9p5pCsss6KMp6ougIepId7v+kLRVGcauZ9Xb2gj+lUCWMZpA6UZ3I4PTf/3gpI75IYvHwH937YH0I7b4H7ICMKaivDii5yfs77hs+QJywI6ElzgCYwxpW1dwqyB2b67Pg5dst6dDk+lrc7y64Zkrr2WfC+ecAcAApl2G+TXl4SClPU/HwZ5vavo00u3fGnYzfxJRPJA1 jenkins_mender_buildslaves
EOF

mkdir -p /export/sstate-cache
chown jenkins:jenkins /export/sstate-cache

apt update
apt -y install nfs-kernel-server sudo

cat >> /etc/exports <<EOF

# FYI "insecure" doesn't mean what it says. Read the docs.
/export/sstate-cache 127.0.0.1(rw,insecure,no_subtree_check,all_squash,anonuid=1010,anongid=1010)
EOF
systemctl restart nfs-server

echo "jenkins ALL=(ALL:ALL) NOPASSWD:ALL" >> /etc/sudoers

chown -R jenkins:jenkins /home/jenkins
