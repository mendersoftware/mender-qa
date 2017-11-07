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
useradd -m -u 1010 jenkins
mkdir -p /home/jenkins/.ssh
cp /root/.ssh/authorized_keys /home/jenkins/.ssh

# Enable sudo access for jenkins.
echo "jenkins ALL=(ALL:ALL) NOPASSWD:ALL" >> /etc/sudoers

# Disable TTY requirement.
sed -i -e 's/^\( *Defaults *requiretty *\)$/# \1/' /etc/sudoers

# Copy the mender-qa repository to jenkins user.
cp -r /root/mender-qa /home/jenkins

# Key generated for the purpose of connecting to build-artifacts-cache
# via SFTP and getting the build artifacts (for normal build hosts) or
# getting the nested VM image (for hosts that run nested-vm.sh).
privkeyfile=/root/*id_rsa
privkeybase=`basename $privkeyfile`  ||  true
[ -f $privkeyfile ] \
    && cp $privkeyfile       /home/jenkins/.ssh/id_rsa \
    && chmod 600             /home/jenkins/.ssh/id_rsa \
    && cp /root/mender-qa/data/$privkeybase.pub /home/jenkins/.ssh/id_rsa.pub
cp /root/mender-qa/data/known_hosts                    /home/jenkins/.ssh/known_hosts


# Make sure everything in jenkins' folder has right owner.
chown -R jenkins:jenkins /home/jenkins

# change hostname to localhost
# it will fix sudo complaining "unable to resolve host digitalocean",
# and some tests
hostname localhost

# Open SSH port on 222.
iptables -t nat -I PREROUTING 1 -p tcp --dport 222 -j DNAT --to-dest :22
iptables -t nat -I OUTPUT 1 -p tcp --dst 127.0.0.1 --dport 222 -j DNAT --to-dest :22

apt_get() {
    # Work around apt-get not waiting for a lock if it's taken. We want to wait
    # for it instead of bailing out. No good return code to check unfortunately,
    # so we just have to look inside the log.

    pid=$$
    # Maximum five minute wait (30 * 10 seconds)
    attempts=30

    while true
    do
        ( /usr/bin/apt-get "$@" 2>&1 ; echo $? > /tmp/apt-get-return-code.$pid.txt ) | tee /tmp/apt-get.$pid.log
        if [ $attempts -gt 0 ] && \
               [ "$(cat /tmp/apt-get-return-code.$pid.txt)" -ne 0 ] && \
               fgrep "Could not get lock" /tmp/apt-get.$pid.log > /dev/null
        then
            attempts=$(expr $attempts - 1)
            sleep 10
        else
            break
        fi
    done

    rm -f /tmp/apt-get-return-code.$pid.txt /tmp/apt-get.$pid.log

    return "$(cat /tmp/apt-get-return-code.$pid.txt)"
}
alias apt=apt_get
alias apt-get=apt_get
