#!/bin/bash

# A script that launches a nested VM inside an already running VM. The only
# argument is an image file, which is expected to be accompanied by a KVM xml
# domain specification with the same name + ".xml". The script also creates a
# proxy-target.txt file which can be used to automatically enter the host later
# using enter-proxy-target.sh.

# After the VM is launched, an extra login port is available on the proxy host:
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

# Create an empty file early in case there is an error in this script. At least
# then we will still detect correctly whether we are on a slave or a proxy.
touch $HOME/proxy-target.txt

# Enabled nested VMs.
sudo modprobe -r kvm_intel
sudo modprobe kvm_intel nested=1

# Verify that nested VMs are supported.
test "`cat /sys/module/kvm_intel/parameters/nested`" = "Y"
egrep -q '^flags\b.*\bvmx\b' /proc/cpuinfo

# Avoid nfs copy if argument contains '@'
if echo "$1" | grep -q '@'
then
    # '*' must be interpreted by the remote ssh host
    scp -o Ciphers=aes128-gcm@openssh.com -o Compression=yes  \
        "$1*" $HOME/
else
    cp "$1"* $HOME/
fi

BASEDISK=`echo $1 | sed 's/.*\///'`
DISK="$HOME/$BASEDISK"
XML="$DISK.xml"

# Install KVM and other tools.
sudo yum -y install epel-release
sudo yum -y install qemu-kvm qemu-system-x86 libvirt rsync
sudo yum -y install qemu-common qemu-kvm-common

# Replace the disk with our copy.
sed -i -e "s,[^']*/$BASEDISK,$HOME/$BASEDISK," $XML

chmod go+rx $HOME
sudo chown qemu:kvm $DISK $XML

## fixing issue with /dev/kvm
sudo chown root:kvm /dev/kvm
sudo chmod g+rw /dev/kvm
sudo chmod o+rw /dev/kvm

# Start libvirt
sudo systemctl start libvirtd

# Start the VM
# sudo virsh net-start default || true
sudo virsh create $XML

# WAIT for host and find its IP
IP=
attempts=20
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

# Port forward to new host on port 2222.
sudo iptables -t nat -I PREROUTING 1 -p tcp --dport 2222 -j DNAT --to-dest $IP:22
sudo iptables -t nat -I OUTPUT 1 -p tcp --dst 127.0.0.1 --dport 2222 -j DNAT --to-dest $IP:22
sudo iptables -I FORWARD 1 -p tcp --dport 22 -j ACCEPT


exit 0
