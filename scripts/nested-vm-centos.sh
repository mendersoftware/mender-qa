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
# sudo apt -qy update
# sudo apt -qy install libvirt-bin rsync kvm qemu-kvm qemu-system-x86

# sudo yum -y update
sudo yum -y install epel-release
sudo yum -y install qemu-kvm qemu-system-x86 libvirt rsync
sudo yum -y install qemu-common qemu-kvm-common


# Enable nbd devices to have partitions.
# sudo modprobe -r nbd
# sudo modprobe nbd max_part=16

## Make temporary keys for logging into nested VM from this host.
## Saves having to keep the standard private keys here.
#if [ ! -f $HOME/.ssh/id_rsa ]
#then
#    mkdir -p $HOME/.ssh
#    ssh-keygen -f $HOME/.ssh/id_rsa -N ""
#fi
#
## Mount the image and add some keys.
#sudo qemu-nbd -c /dev/nbd0 $DISK
#sudo mkdir -p /mnt/vm
#success=0
#for i in 1 2 3 4 5
#do
#    VG=
#    if sudo file -sL /dev/nbd0p$i | grep -q 'Logical Volume'
#    then
#        # The VM is using LVM. This makes things a bit more complicated, we need
#        # to find the right volume. This just looks for the first ext[234]
#        # filesystem ATM.
#
#        # This is relying on there being no volume group on the parent host.
#        VG=`sudo vgs --noheadings | awk '{print $1}'`
#        sudo vgchange -ay $VG
#        for LV in /dev/mapper/${VG/-/--}-*
#        do
#            if sudo file -sL $LV | grep -q 'ext[234]'
#            then
#                sudo mount $LV /mnt/vm || continue
#                break
#            fi
#        done
#    else
#        # Normal partitions.
#        sudo mount /dev/nbd0p$i /mnt/vm || continue
#    fi
#    # Look for /usr directory to identify Linux partition.
#    if [ ! -d /mnt/vm/usr ]
#    then
#       sudo umount /mnt/vm
#       if [ -n "$VG" ]
#       then
#           sudo vgchange -an $VG
#       fi
#       continue
#    fi
#
#    # Install keys.
#    sudo mkdir -p /mnt/vm/root/.ssh
#    sudo bash -c "cat $HOME/.ssh/id_rsa.pub $HOME/.ssh/authorized_keys >> /mnt/vm/root/.ssh/authorized_keys"
#    sudo umount /mnt/vm
#    if [ -n "$VG" ]
#    then
#        sudo vgchange -an $VG
#    fi
#    success=1
#    break
#done
#sudo qemu-nbd -d /dev/nbd0
#
#if [ $success != 1 ]
#then
#    echo "Unable to insert SSH keys"
#    exit 1
#fi

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

# Find IP of the newly launched host.
IP=
attempts=180
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

echo "$IP" > $HOME/ip.txt

# Port forward to new host on port 2222.
sudo iptables -t nat -I PREROUTING 1 -p tcp --dport 2222 -j DNAT --to-dest $IP:22
sudo iptables -t nat -I OUTPUT 1 -p tcp --dst 127.0.0.1 --dport 2222 -j DNAT --to-dest $IP:22
sudo iptables -I FORWARD 1 -p tcp --dport 22 -j ACCEPT

# Create jenkins user on slave VM and copy keys.
#attempts=30
#while ! ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$IP true
#do
#    attempts=$(($attempts - 1))
#    if [ $attempts -le 0 ]
#    then
#        echo "Could not connect to SSH of launched VM."
#        exit 1
#    fi
#
#    sleep 10
#done
#ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$IP useradd -m -d /home/jenkins jenkins || true
#ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$IP mkdir -p /home/jenkins/.ssh
#ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$IP cp .ssh/authorized_keys /home/jenkins/.ssh/authorized_keys
#scp -o BatchMode=yes -o StrictHostKeyChecking=no /home/jenkins/.ssh/id_rsa* root@$IP:/home/jenkins/.ssh/
#ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$IP chown -R jenkins:jenkins /home/jenkins/.ssh
#PKG_MANAGER="apt-get -q"
#ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$IP "test -x /usr/bin/yum" && PKG_MANAGER=yum
#ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$IP "$PKG_MANAGER -y update && $PKG_MANAGER -y install rsync"

exit 0
