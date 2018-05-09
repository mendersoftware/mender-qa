#!/bin/bash

cd $HOME

. mender-qa/scripts/initialize-build-host.sh

sudo curl -L https://github.com/docker/compose/releases/download/1.20.1/docker-compose-`uname -s`-`uname -m` > docker-compose

sudo cp docker-compose /usr/bin/docker-compose
sudo chmod +x /usr/bin/docker-compose

sudo chown jenkins:jenkins /usr/bin/docker-compose

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
sudo apt-get -qy update
echo "deb http://apt.dockerproject.org/repo debian-jessie main" | sudo tee -a /etc/apt/sources.list.d/docker.list
curl -sL https://deb.nodesource.com/setup_8.x | sudo -E bash -
sudo apt-get -qy update
sudo apt-get -qy --force-yes install git autoconf automake build-essential diffstat gawk chrpath libsdl1.2-dev e2tools nfs-client  s3cmd psmisc screen libssl-dev python-dev libxml2-dev libxslt-dev libffi-dev nodejs libyaml-dev sysbench texinfo default-jre-headless pkg-config zlib1g-dev libaio-dev libbluetooth-dev libbrlapi-dev libbz2-dev libglib2.0-dev libfdt-dev libpixman-1-dev zlib1g-dev jq liblzo2-dev device-tree-compiler qemu-system-x86
sudo apt-get -qy --force-yes install docker-ce || sudo apt-get -qy --force-yes install docker-ce
sudo cp /sbin/debugfs /usr/bin/ || echo "debugfs not in /sbin/"

wget https://storage.googleapis.com/golang/go1.10.linux-amd64.tar.gz
gunzip -c go1.10.linux-amd64.tar.gz | (cd /usr/local && sudo tar x)
sudo ln -sf ../go/bin/go /usr/local/bin/go
sudo ln -sf ../go/bin/godoc /usr/local/bin/godoc
sudo ln -sf ../go/bin/gofmt /usr/local/bin/gofmt

sudo service docker restart

sudo npm install -g gulp
sudo npm install mocha selenium-webdriver@3.0.0-beta-2 saucelabs

# Python 2 pip
sudo apt-get -qy --force-yes install python-pip
sudo pip2 install requests --upgrade
sudo pip2 install pytest==3.2.5
sudo pip2 install filelock --upgrade
sudo pip2 install pytest-xdist --upgrade
sudo pip2 install pytest-html --upgrade
sudo pip2 install fabric --upgrade
sudo pip2 install psutil --upgrade
sudo pip2 install boto3 --upgrade
sudo pip2 install pycrypto --upgrade

# Python 3 pip
sudo apt-get -qy --force-yes install python3-pip
sudo pip3 install pyyaml --upgrade
