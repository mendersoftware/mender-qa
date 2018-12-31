#!/bin/bash

cd $HOME

. mender-qa/scripts/initialize-build-host.sh

# Install java first so that Jenkins gets going.
apt_get -qy update
apt_get -qy --force-yes install default-jre-headless

curl -L https://github.com/docker/compose/releases/download/1.20.1/docker-compose-`uname -s`-`uname -m` > docker-compose

cp docker-compose /usr/bin/docker-compose
chmod +x /usr/bin/docker-compose

chown jenkins:jenkins /usr/bin/docker-compose

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
echo "deb http://apt.dockerproject.org/repo debian-jessie main" | tee -a /etc/apt/sources.list.d/docker.list
curl -sL https://deb.nodesource.com/setup_8.x | bash -

apt_get -qy update
apt_get -qy --force-yes install git autoconf automake build-essential diffstat gawk chrpath libsdl1.2-dev e2tools nfs-client  s3cmd psmisc screen libssl-dev python-dev libxml2-dev libxslt-dev libffi-dev nodejs libyaml-dev sysbench texinfo pkg-config zlib1g-dev libaio-dev libbluetooth-dev libbrlapi-dev libbz2-dev libglib2.0-dev libfdt-dev libpixman-1-dev zlib1g-dev jq liblzo2-dev device-tree-compiler qemu-system-x86 bc kpartx musl-dev musl-tools
apt_get -qy --force-yes install docker-ce || apt_get -qy --force-yes install docker-ce
cp /sbin/debugfs /usr/bin/ || echo "debugfs not in /sbin/"

wget https://storage.googleapis.com/golang/go1.10.linux-amd64.tar.gz
gunzip -c go1.10.linux-amd64.tar.gz | (cd /usr/local && tar x)
ln -sf ../go/bin/go /usr/local/bin/go
ln -sf ../go/bin/godoc /usr/local/bin/godoc
ln -sf ../go/bin/gofmt /usr/local/bin/gofmt

# Download and install lzma using muslc.
wget https://tukaani.org/xz/xz-5.2.4.tar.gz
tar -xf xz-5.2.4.tar.gz
mkdir /usr/local/musl
(cd xz-5.2.4 && ./configure CC=musl-gcc --disable-shared --prefix=/usr/local/musl/ && make && sudo make install)

service docker restart

npm install -g gulp
npm install mocha selenium-webdriver@3.0.0-beta-2 saucelabs

# Python 2 pip
apt_get -qy --force-yes install python-pip
pip2 install requests --upgrade
pip2 install pytest --upgrade
pip2 install filelock --upgrade
pip2 install pytest-xdist --upgrade
pip2 install pytest-html --upgrade
pip2 install -I fabric==1.14.0
pip2 install psutil --upgrade
pip2 install boto3 --upgrade
pip2 install pycrypto --upgrade

# Python 3 pip
apt_get -qy --force-yes install python3-pip
pip3 install pyyaml --upgrade
