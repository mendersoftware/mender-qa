#!/bin/bash

set -e

LINARO_COMPILER=gcc-linaro-6.3.1-2017.05-x86_64_arm-linux-gnueabihf
COMPRESSED_COMPILER=${LINARO_COMPILER}.tar.xz
LINARO_BINARY_PATH=${LINARO_COMPILER}/bin

DEBIAN_IMAGE=bone-debian-9.4-iot-armhf-2018-06-17-4gb.img
COMPRESSED_DEBIAN=${DEBIAN_IMAGE}.xz
CONVERTED_DEBIAN_IMAGE=mender_debian_converted.sdimg

RASPBIAN_FILE_NAME=2018-06-27-raspbian-stretch-lite
RASPBIAN_IMAGE=${RASPBIAN_FILE_NAME}.img
COMPRESSED_RASPBIAN=${RASPBIAN_FILE_NAME}.zip
CONVERTED_RASPBIAN_IMAGE=mender_raspbian_converted.sdimg

QEMUX86_64_BOARD_NAME=qemux86-64-ovmf-grub
QEMUX86_64_RAW_DISK_IMAGE=
CONVERTED_QEMUX86_64_IMAGE=mender_qemux86_64_converted.sdimg

eval $(sed -n -e '/MENDER_CLIENT_VERSION=/p' $WORKSPACE/mender-convert/docker-build)

export GOPATH="$WORKSPACE/go"

host=$(uname -m)

get_arm_compiler() {
    wget -nc -q https://releases.linaro.org/components/toolchain/binaries/6.3-2017.05/arm-linux-gnueabihf/gcc-linaro-6.3.1-2017.05-x86_64_arm-linux-gnueabihf.tar.xz
    tar -xJf ${COMPRESSED_COMPILER}
}

get_debian() {
    wget -nc -q http://debian.beagleboard.org/images/bone-debian-9.4-iot-armhf-2018-06-17-4gb.img.xz
    xz -d -k ${COMPRESSED_DEBIAN}
}

get_raspbian() {
    wget -nc -q https://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2018-06-29/2018-06-27-raspbian-stretch-lite.zip
    unzip -q ${COMPRESSED_RASPBIAN}
}

get_pytest_files() {
    wget -nc -q https://raw.githubusercontent.com/mendersoftware/meta-mender/master/tests/acceptance/pytest.ini -P $WORKSPACE/mender-image-tests
    wget -nc -q https://raw.githubusercontent.com/mendersoftware/meta-mender/master/tests/acceptance/common.py -P $WORKSPACE/mender-image-tests
    wget -nc -q https://raw.githubusercontent.com/mendersoftware/meta-mender/master/tests/acceptance/conftest.py -P $WORKSPACE/mender-image-tests
    wget -nc -q https://raw.githubusercontent.com/mendersoftware/meta-mender/master/tests/acceptance/fixtures.py -P $WORKSPACE/mender-image-tests
}

get_mender_artifact() {
    wget -nc -q https://d1b0l86ne08fsf.cloudfront.net/mender-artifact/2.3.0/mender-artifact
}

build_mender_client_deps() {
    # Build liblzma from source
    mkdir -p $WORKSPACE/liblzma
    wget -q https://tukaani.org/xz/xz-5.2.4.tar.gz -P $WORKSPACE/liblzma
    tar -C $WORKSPACE/liblzma -xzf $WORKSPACE/liblzma/xz-5.2.4.tar.gz
    cd $WORKSPACE/liblzma/xz-5.2.4
    ./configure --host=arm-linux-gnueabihf --prefix=$WORKSPACE/liblzma/install
    make
    make install
    cd -
    export LIBLZMA_INSTALL_PATH=$WORKSPACE/liblzma/install
}

build_mender_client() {
    go get -d github.com/mendersoftware/mender
    mkdir -p $GOPATH/bin
    cd $GOPATH/src/github.com/mendersoftware/mender
    git checkout $MENDER_CLIENT_VERSION
    env CGO_ENABLED=1 \
        CGO_CFLAGS="-I${LIBLZMA_INSTALL_PATH}/include" \
        CGO_LDFLAGS="-L${LIBLZMA_INSTALL_PATH}/lib" \
        CC=arm-linux-gnueabihf-gcc \
        GOOS=linux \
        GOARCH=arm make build
    arm-linux-gnueabihf-strip mender
    cp mender $GOPATH/bin/mender-arm
    make clean
    make build
    strip mender
    cp mender $GOPATH/bin/mender-$host
    cd -
}

build_mender_artifact() {
    go get github.com/mendersoftware/mender-artifact
    cd $GOPATH/src/github.com/mendersoftware/mender-artifact
    go get ./...
    cd -
}

build_qemux86_64_vanilla_image() {
    local machine_name=qemux86-64
    local board_name=$QEMUX86_64_BOARD_NAME
    local image_name=core-image-full-cmdline

    cd $WORKSPACE/poky

    source oe-init-build-env ${board_name}

    if [ -d $WORKSPACE/mender-image-tests/tests/build-conf/${board_name} ]; then
        cp $WORKSPACE/mender-image-tests/tests/build-conf/${board_name}/local.conf $BUILDDIR/conf/local.conf
    else
        echo "Could not find build-conf for $board_name board."
        return 1
    fi

    # Use network cache if present, if not, use local cache.
    if [ -d /mnt/sstate-cache ]; then
        cat >> $BUILDDIR/conf/local.conf <<EOF
SSTATE_DIR = "/mnt/sstate-cache"
EOF
    else
        mkdir -p $HOME/sstate-cache
        cat >> $BUILDDIR/conf/local.conf <<EOF
SSTATE_DIR = "$HOME/sstate-cache"
EOF
    fi

    cd $BUILDDIR

    local bitbake_result=0
    bitbake $image_name || bitbake_result=$?

    if [[ $bitbake_result -eq 0 ]]; then
        github_PR_status "pending" "poky build completed"
    else
        github_PR_status "failure" "poky build failed"
        return $bitbake_result
    fi

    mkdir -p $WORKSPACE/$board_name
    cp -vL $BUILDDIR/tmp/deploy/images/$machine_name/$image_name-$machine_name.wic $WORKSPACE/$board_name
    cp -vL $BUILDDIR/tmp/deploy/images/$machine_name/ovmf.* $WORKSPACE/$board_name

    QEMUX86_64_RAW_DISK_IMAGE="$WORKSPACE/$board_name/$image_name-$machine_name.wic"

    return 0
}


github_PR_status () {
    request_body=$(cat <<EOF
         {
              "state": "$1",
              "description": "$2",
              "target_url": "$BUILD_URL",
              "context": "mender_convert_acceptance_tests"
         }
EOF
)

    GITHUB_BOT_USER=mender-test-bot
    GITHUB_BOT_PASSWORD="niMhcVa4>Nb{ZLyb"

    git_commit=$(cd "$WORKSPACE/mender-convert" && git rev-parse HEAD)
    for decl in $(env); do
         key=${decl%%=*}
         if ! eval echo \$$key | egrep -q "^pull/[0-9]+/head$"; then
              # Not a pull request, skip.
              continue
         fi
         case "$key" in
              *_REV)
                   repo=$(tr '[A-Z_]' '[a-z-]' <<<${key%_REV})
                   ;;
               *)
                   continue
                   ;;
         esac

         pr_status_endpoint=https://api.github.com/repos/mendersoftware/$repo/statuses/$git_commit
         set -x
         curl --user "$GITHUB_BOT_USER:$GITHUB_BOT_PASSWORD" \
              -d "$request_body" \
              "$pr_status_endpoint"
         set +x
done

}

github_PR_status "pending" "Mender convert acceptance tests has started"

# Wait unti build host is ready.
attempts=180
while [ $attempts -gt 0 ] && ! systemctl is-system-running; do
    # Wait for init-script to finish.
    sleep 10
    attempts=$(expr $attempts - 1 || true)
done
sudo journalctl -u rc-local | cat || true
 if [ $attempts -le 0 ]; then
    exit 1
fi


echo "deb http://us.archive.ubuntu.com/ubuntu/ bionic main restricted universe" | sudo tee -a /etc/apt/sources.list
echo "deb http://security.ubuntu.com/ubuntu bionic-security main restricted universe" | sudo tee -a /etc/apt/sources.list

sudo apt-get update
sudo apt-get -qy --force-yes install e2fsprogs=1.44.1-1
sudo apt-get -qy --force-yes install kpartx bison unzip mtools parted mtd-utils u-boot-tools pigz flex liblzma-dev
sudo apt-get -qy --force-yes install python-pip
sudo pip2 install pytest --upgrade
sudo pip2 install pytest-xdist --upgrade
sudo pip2 install pytest-html --upgrade
sudo pip2 install -I fabric==1.14.0

cat >> ~/.mtoolsrc << EOF
mtools_skip_check=1
EOF

get_arm_compiler
if [ ! -e ${LINARO_BINARY_PATH} ]; then
    echo "${LINARO_BINARY_PATH}: can not be found"
    github_PR_status "failure" "Cannot setup arm compiler"
    exit 1
fi

get_debian
if [ ! -e ${DEBIAN_IMAGE} ]; then
    echo "${DEBIAN_IMAGE}: can not be found"
    github_PR_status "failure" "Cannot find debian image"
    exit 1
fi

get_raspbian
if [ ! -e ${RASPBIAN_IMAGE} ]; then
    echo "${RASPBIAN_IMAGE}: can not be found"
    github_PR_status "failure" "Cannot find raspbian image"
    exit 1
fi

export PATH=$PATH:$(pwd)/gcc-linaro-6.3.1-2017.05-x86_64_arm-linux-gnueabihf/bin

build_mender_client_deps
build_mender_client
if [ ! -e $GOPATH/bin/mender-$host ]; then
    echo "$GOPATH/bin/mender-$host: can not be found"
    exit 1
fi
if [ ! -e $GOPATH/bin/mender-arm ]; then
    echo "$GOPATH/bin/mender-arm: can not be found"
    exit 1
fi

build_mender_artifact
if [ ! -e $GOPATH/bin/mender-artifact ]; then
    echo "mender-artifact: can not be found"
    github_PR_status "failure" "Cannot find mender artifact"
    exit 1
fi

export PATH=$PATH:$GOPATH/bin

if ! [ -x "$(command -v mender-artifact)" ]; then
    echo "mender-artifact: not found in PATH."
    github_PR_status "failure" "mender-artifact: not found in PATH."
    exit 1
fi

build_qemux86_64_vanilla_image || rc=$?

[[ $rc -eq 0 ]] || { exit 1; }

cd $WORKSPACE/mender-convert

./mender-convert from-raw-disk-image --raw-disk-image $QEMUX86_64_RAW_DISK_IMAGE --mender-disk-image ${CONVERTED_QEMUX86_64_IMAGE} \
    --device-type qemux86_64 --mender-client $GOPATH/bin/mender-$host --artifact-name release-1_$MENDER_CLIENT_VERSION \
    --demo-host-ip 192.168.10.2 --bootloader-toolchain arm-linux-gnueabihf

rc=$?
[[ $rc -ne 0 ]] && { echo "Building QEMU x86_64 converted image failed. Aborting."; \
                     github_PR_status "failure" "Cannot convert QEMU x86_64 image"; exit 1;} \
                || { echo "Successful QEMU x86_64 conversion."; }

./mender-convert from-raw-disk-image --raw-disk-image $WORKSPACE/${DEBIAN_IMAGE} --mender-disk-image ${CONVERTED_DEBIAN_IMAGE} \
    --device-type beaglebone --mender-client $GOPATH/bin/mender-arm --artifact-name release-1_$MENDER_CLIENT_VERSION \
    --demo-host-ip 192.168.10.2 --bootloader-toolchain arm-linux-gnueabihf

rc=$?
[[ $rc -ne 0 ]] && { echo "Building Debian converted image failed. Aborting."; \
                     github_PR_status "failure" "Cannot convert debian image"; exit 1;} \
                || { echo "Successful Debian for BBB conversion."; }

./mender-convert from-raw-disk-image --raw-disk-image $WORKSPACE/${RASPBIAN_IMAGE} --mender-disk-image ${CONVERTED_RASPBIAN_IMAGE} \
    --device-type raspberrypi3 --mender-client $GOPATH/bin/mender-arm --artifact-name release-1_$MENDER_CLIENT_VERSION \
    --demo-host-ip 192.168.10.2 --bootloader-toolchain arm-linux-gnueabihf

rc=$?
[[ $rc -ne 0 ]] && { echo "Building Raspbian converted image failed. Aborting."; \
                    github_PR_status "failure" "Cannot convert raspbian image"; exit 1;} \
                || { echo "Successful Raspbian for Raspberry Pi3 conversion."; }

get_pytest_files

cd $WORKSPACE/mender-image-tests

testing_status=0

py.test --verbose --junit-xml=results.xml --test-conversion --test-variables=../mender-convert/output/qemux86_64_variables.cfg \
        --board-type=qemux86_64 --mender-image=${CONVERTED_QEMUX86_64_IMAGE} --sdimg-location=../mender-convert/output || testing_status=$?

if [ $testing_status -ne 0 ]; then
    github_PR_status "failure" "Cannot pass qemu x86-64 acceptance tests"
    exit $testing_status
fi

py.test --verbose --junit-xml=results.xml --test-conversion --test-variables=../mender-convert/output/beaglebone_variables.cfg \
        --board-type=beaglebone --mender-image=${CONVERTED_DEBIAN_IMAGE} --sdimg-location=../mender-convert/output || testing_status=$?

if [ $testing_status -ne 0 ]; then
    github_PR_status "failure" "Cannot pass beaglebone acceptance tests"
    exit $testing_status
fi

py.test --verbose --junit-xml=results.xml --test-conversion --test-variables=../mender-convert/output/raspberrypi3_variables.cfg \
        --board-type=raspberrypi3 --mender-image=${CONVERTED_RASPBIAN_IMAGE} --sdimg-location=../mender-convert/output || testing_status=$?

if [ $testing_status -ne 0 ]; then
    github_PR_status "failure" "Cannot pass raspberry acceptance tests"
    exit $testing_status
fi

github_PR_status "success" "All tests passed"
