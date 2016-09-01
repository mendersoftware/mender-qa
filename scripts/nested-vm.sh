#!/bin/bash

# A script that launches a nested VM inside an already running VM. The only
# argument is an image file, which is expected to be accompanied by a KVM xml
# domain specification with the same name + ".xml". The script also creates a
# proxy-target.txt file which can be used to automatically enter the host later
# using enter-proxy-target.sh.

# After the VM is launched, two login ports are available:
# Port 222  - Login to the proxy. This is equivalent to port 22, but the reason
#             this is necessary is to stop Jenkins from logging in too early. If
#             it tries to login too early, it will find the port open, but the
#             key for the jenkins user might not be accepted yet, and it will
#             give up. However, if we keep the port closed, it will keep trying.
# Port 2222 - Login to the proxy target, IOW the build slave. This won't be used
#             by Jenkins, but is useful for debugging.

set -x -e

if [ -z "$HOME" ]
then
    echo "HOME has to be set"
    exit 1
fi

if [ -z "$1" ]
then
    echo "Requires image name as argument"
    exit 1
fi

cp "$1"* $HOME

BASEDISK="$(basename "$1")"
DISK="$HOME/$BASEDISK"
XML="$DISK.xml"

# Create an empty file early in case there is an error in this script. At least
# then we will still detect correctly whether we are on a slave or a proxy.
touch $HOME/proxy-target.txt

# Enabled nested VMs.
sudo modprobe -r kvm_intel
sudo modprobe kvm_intel nested=1

# Verify that nested VMs are supported.
test "`cat /sys/module/kvm_intel/parameters/nested`" = "Y"
egrep -q '^flags\b.*\bvmx\b' /proc/cpuinfo

# Install KVM and other tools.
sudo apt -y update
sudo apt -y install libvirt-bin rsync

# Enable nbd devices to have partitions.
sudo modprobe -r nbd
sudo modprobe nbd max_part=16

# Make temporary keys for logging into nested VM from this host.
# Saves having to keep the standard private keys here.
if [ ! -f $HOME/.ssh/id_rsa ]
then
    mkdir -p $HOME/.ssh
    ssh-keygen -f $HOME/.ssh/id_rsa -N ""
fi

# Mount the image and add some keys.
sudo qemu-nbd -c /dev/nbd0 $DISK
sudo mkdir -p /mnt/vm
success=0
for i in 1 2 3 4 5
do
    sudo mount /dev/nbd0p$i /mnt/vm || continue
    if [ ! -d /mnt/vm/usr ]
    then
       sudo umount /mnt/vm
       continue
    fi

    sudo mkdir -p /mnt/vm/root/.ssh
    sudo bash -c "cat $HOME/.ssh/id_rsa.pub $HOME/.ssh/authorized_keys >> /mnt/vm/root/.ssh/authorized_keys"
    sudo umount /mnt/vm
    success=1
    break
done
sudo qemu-nbd -d /dev/nbd0

if [ $success != 1 ]
then
    echo "Unable to insert SSH keys"
    exit 1
fi

# Replace the disk with our copy.
sed -i -e "s,[^']*/$BASEDISK,$HOME/$BASEDISK," $XML

chmod go+rx $HOME
sudo chown libvirt-qemu:libvirt-qemu $DISK $XML

# Start the VM
sudo virsh net-start default || true
sudo virsh create $XML

# Find IP of the newly launched host.
IP=
attempts=10
while [ -z "$IP" ]
do
    attempts=$(($attempts - 1))
    if [ $attempts -le 0 ]
    then
        echo "Could not find IP of launched VM."
        exit 1
    fi

    sleep 10
    IP="$(sudo arp | grep virbr0 | awk '{print $1}')"
done
echo "jenkins@$IP" > $HOME/proxy-target.txt

# Port forward to this host on port 222, and new host on port 2222.
sudo iptables -t nat -I PREROUTING 1 -p tcp --dport 222 -j DNAT --to-dest :22
sudo iptables -t nat -I OUTPUT 1 -p tcp --dst 127.0.0.1 --dport 222 -j DNAT --to-dest :22
sudo iptables -t nat -I PREROUTING 1 -p tcp --dport 2222 -j DNAT --to-dest $IP:22
sudo iptables -t nat -I OUTPUT 1 -p tcp --dst 127.0.0.1 --dport 2222 -j DNAT --to-dest $IP:22
sudo iptables -I FORWARD 1 -p tcp --dport 22 -j ACCEPT

# Create jenkins user on slave VM and copy keys.
attempts=10
while ! ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$IP true
do
    attempts=$(($attempts - 1))
    if [ $attempts -le 0 ]
    then
        echo "Could not connect to SSH of launched VM."
        exit 1
    fi

    sleep 10
done
ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$IP useradd -m -d /home/jenkins jenkins || true
ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$IP mkdir -p /home/jenkins/.ssh
ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$IP cp .ssh/authorized_keys /home/jenkins/.ssh/authorized_keys
ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$IP chown -R jenkins:jenkins /home/jenkins/.ssh
ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$IP "apt-get -y update && apt-get -y install rsync"

exit 0
