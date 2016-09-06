#!/bin/false

# This file should be sourced, not run.

# This script will do build slave setup, including creating credentials for the
# jenkins user, based on root's credentials (will copy its keys). The script is
# expected to be sourced early in the user-data phase after provisioning.

# It will also create a port forwarding rule from port 222 to localhost:22. This
# is equivalent to logging in on port 22, but the reason this is necessary is to
# stop Jenkins from logging in too early. If it tries to login too early, it
# will find the port open, but the key for the jenkins user might not be
# accepted yet, and it will give up. However, if we keep port 222 closed until
# we know it's ready, it will keep trying and eventually succeed.

# Make sure error detection and verbose output is on, if they aren't already.
set -x -e

# Add jenkins user and copy credentials.
useradd -m jenkins
mkdir -p /home/jenkins/.ssh
cp /root/.ssh/authorized_keys /home/jenkins/.ssh

# Enable sudo access for jenkins.
echo "jenkins ALL=(ALL:ALL) NOPASSWD:ALL" >> /etc/sudoers

# Disable TTY requirement.
sed -i -e 's/^\( *Defaults *requiretty *\)$/# \1/' /etc/sudoers

# Copy the mender-qa repository to jenkins user.
cp -r /root/mender-qa /home/jenkins

# Make sure everything in jenkins' folder has right owner.
chown -R jenkins:jenkins /home/jenkins

# Open SSH port on 222.
iptables -t nat -I PREROUTING 1 -p tcp --dport 222 -j DNAT --to-dest :22
iptables -t nat -I OUTPUT 1 -p tcp --dst 127.0.0.1 --dport 222 -j DNAT --to-dest :22
