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
touch $HOME/on-vm-hypervisor

# Enabled nested VMs.
sudo modprobe -r kvm_intel || true
sudo modprobe kvm_intel nested=1

# Verify that nested VMs are supported.
test "`cat /sys/module/kvm_intel/parameters/nested`" = "Y"
egrep -q '^flags\b.*\bvmx\b' /proc/cpuinfo

# Path where images are stored on build-artifacts-cache
DISKIMAGE="/export/images/$1"
BASEDISK=`echo $1 | sed 's/.*\///'`
DISK="$HOME/$BASEDISK"
XML="$DISK.xml"

if [ ! -f $DISK ]
then
    # We append '*', which will be expanded on the SFTP server
    echo "
    lcd $HOME
    get $DISKIMAGE*
    "  | sftp -o Ciphers=aes128-gcm@openssh.com -o Compression=yes -o PreferredAuthentications=publickey -b -  \
             jenkins_sftp_cache@build-artifacts-cache.cloud.cfengine.com
fi

# Install KVM and other tools.
sudo apt -qy update
sudo apt -qy install rsync
# Since Debian 9, single libvirt-bin was split into two
# Note that we don't run this script on other platforms but Debian 8 and 9,
# so we don't need to care about, say, Ubuntu VERSION=18.04
if grep -q VERSION.*8 /etc/os-release
then
    sudo apt -qy install libvirt-bin
else
    sudo apt -qy install libvirt-daemon-system libvirt-clients
fi

# Enable nbd devices to have partitions.
sudo modprobe -r nbd || true
sudo modprobe nbd max_part=16

# Make temporary keys for logging into nested VM from this host.
# Saves having to keep the standard private keys here.
if [ ! -f $HOME/.ssh/id_rsa ]
then
    mkdir -p $HOME/.ssh
    ssh-keygen -f $HOME/.ssh/id_rsa -N ""
fi

# Mount the image and add some keys.
sudo qemu-nbd -d /dev/nbd0 || true
sudo qemu-nbd -c /dev/nbd0 $DISK
sudo mkdir -p /mnt/vm
success=0
for i in 1 2 3 4 5
do
    VG=
    if sudo file -sL /dev/nbd0p$i | grep -q 'Logical Volume'
    then
        # The VM is using LVM. This makes things a bit more complicated, we need
        # to find the right volume. This just looks for the first ext[234]
        # filesystem ATM.

        # This is relying on there being no volume group on the parent host.
        VG=`sudo vgs --noheadings | awk '{print $1}'`
        sudo vgchange -ay $VG
        for LV in /dev/mapper/${VG/-/--}-*
        do
            if sudo file -sL $LV | grep -q 'ext[234]'
            then
                sudo umount /mnt/vm || true
                sudo mount $LV /mnt/vm || continue
                break
            fi
        done
    else
        # Normal partitions.
        sudo umount /mnt/vm || true
        sudo mount /dev/nbd0p$i /mnt/vm || continue
    fi

    # Look for /usr directory to identify Linux partition.
    if [ ! -d /mnt/vm/usr ]
    then
       sudo umount /mnt/vm || true
       if [ -n "$VG" ]
       then
           sudo vgchange -an $VG
       fi
       continue
    fi

    # Install keys.
    sudo mkdir -p /mnt/vm/root/.ssh
    sudo bash -c "cat $HOME/.ssh/id_rsa.pub $HOME/.ssh/authorized_keys >> /mnt/vm/root/.ssh/authorized_keys" || true
    sudo umount /mnt/vm
    if [ -n "$VG" ]
    then
        sudo vgchange -an $VG
    fi
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
sed -i -e "s,[^']*/$BASEDISK,$DISK," $XML

chmod go+rx $HOME
sudo chown libvirt-qemu:libvirt-qemu $DISK $XML

# Start the VM
sudo virsh net-start default || true
if sudo dmesg | grep -q "BIOS Google"
then
    # We're in Google Cloud, so follow the Google guide:
    # https://cloud.google.com/compute/docs/instances/enable-nested-virtualization-vm-instances
    sudo apt-get -y install uml-utilities qemu-kvm bridge-utils tmux
    sudo modprobe dummy
    sudo brctl delif virbr0 dummy0 || true
    sudo brctl addif virbr0 dummy0
    sudo tunctl -t tap0 || true
    sudo ifconfig tap0 up
    sudo brctl delif virbr0 tap0 || true
    sudo brctl addif virbr0 tap0
    MAC=`sed -e '/mac address/!d' -e "s/.*'\(.*\)'.*/\1/" $XML`
    sudo pkill qemu-system-x86_64 || true
    tmux new-session -d "sudo qemu-system-x86_64 -enable-kvm -hda $DISK -m 789 -curses -netdev tap,ifname=tap0,script=no,id=hostnet0 -device rtl8139,netdev=hostnet0,id=net0,mac=$MAC,bus=pci.0,addr=0x3"
else
    # do it like we did before
    sudo virsh create $XML
fi

# WAIT for host and find its IP
IP=
attempts=60
while [ -z "$IP" ]
do
    attempts=$(($attempts - 1))
    if [ $attempts -le 0 ]
    then
        break
    fi

    sleep 10
    IP="$(sudo arp | grep virbr0 | awk '{print $1}')"
done

if [ -z "$IP" ]
then
    echo "Could not find IP of launched VM."
    exit 1
fi

echo "jenkins@$IP" > $HOME/proxy-target.txt

# Port forward to new host on port 2222.
sudo iptables -t nat -I PREROUTING 1 -p tcp --dport 2222 -j DNAT --to-dest $IP:22
sudo iptables -t nat -I OUTPUT 1 -p tcp --dst 127.0.0.1 --dport 2222 -j DNAT --to-dest $IP:22
sudo iptables -I FORWARD 1 -p tcp --dport 22 -j ACCEPT

# WAIT for ssh
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

RSH="ssh -o BatchMode=yes"

# Populate known_hosts file
ssh-keyscan -t rsa  $IP  > ~/.ssh/known_hosts

# Create jenkins user on slave VM and copy keys.
$RSH root@$IP  "useradd -m -d /home/jenkins jenkins"  ||  true
$RSH root@$IP  "mkdir -p /home/jenkins/.ssh"
$RSH root@$IP  "cp .ssh/authorized_keys /home/jenkins/.ssh/authorized_keys"
scp -o BatchMode=yes  /home/jenkins/.ssh/id_rsa* root@$IP:/home/jenkins/.ssh/
$RSH root@$IP  "chown -R jenkins:jenkins /home/jenkins/.ssh"
PKG_MANAGER="apt-get -q --force-yes"
$RSH root@$IP  "test -x /usr/bin/yum"  &&  PKG_MANAGER=yum
$RSH root@$IP  "$PKG_MANAGER -y update && $PKG_MANAGER -y install rsync ntpdate"
$RSH root@$IP  "ntpdate -u time.nist.gov" || true

exit 0
