#!/bin/bash

set -e -x

echo $WORKSPACE
#----
echo "Debug Jenkins setup"
ls /home/jenkins/.ssh
#----

disable_mender_service() {
    if [ "$DISABLE_MENDER_SERVICE" = "true" ]
    then
        cat >> "$BUILDDIR"/conf/local.conf <<EOF
SYSTEMD_AUTO_ENABLE_pn-mender = "disable"
EOF
    fi
}

export PATH=$WORKSPACE/scripts:$WORKSPACE/bitbake/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games
if [ "$CLEAN_BUILD_CACHE" = "true" ]
then
    sudo rm -rf /mnt/sstate-cache/*
fi

if [ "$BUILD_QEMU" = "true" ]
then
    source oe-init-build-env
    cd ../

    if [ ! -d mender-qa ]
    then
      echo "JENKINS SCRIPT: mender-qa directory is not present"
      exit 1
    else
      /bin/rm -f $BUILDDIR/conf/*
      /bin/cp mender-qa/build-conf/*  $BUILDDIR/conf/
      # See comment in local.conf
      cat >> $BUILDDIR/conf/local.conf <<EOF
EXTERNALSRC_pn-mender = "$WORKSPACE/mender"
EXTERNALSRC_pn-mender-artifact = "$WORKSPACE/mender-artifact"
EXTERNALSRC_pn-mender-artifact-native = "$WORKSPACE/mender-artifact"
SSTATE_DIR = "/mnt/sstate-cache"
EOF
    fi
    disable_mender_service
    source oe-init-build-env
    bitbake core-image-full-cmdline

    mkdir -p $WORKSPACE/vexpress-qemu
    cp -L $BUILDDIR/tmp/deploy/images/vexpress-qemu/u-boot.elf $WORKSPACE/vexpress-qemu/u-boot.elf
    cp -L $BUILDDIR/tmp/deploy/images/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.ext4 $WORKSPACE/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.ext4
    cp -L $BUILDDIR/tmp/deploy/images/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.sdimg $WORKSPACE/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.sdimg
    export PATH=$PATH:$BUILDDIR/tmp/sysroots/x86_64-linux/usr/bin

    cd $WORKSPACE/meta-mender/tests/acceptance/

    export UBOOT_ELF=$WORKSPACE/vexpress-qemu/u-boot.elf
    export VEXPRESS_SDIMG=$WORKSPACE/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.sdimg
    export QEMU_SYSTEM_ARM="qemu-system-arm"
    cp $WORKSPACE/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.ext4 image.dat

    mender-artifact write rootfs-image -t vexpress-qemu -n test-update -u $BUILDDIR/tmp/deploy/images/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.ext4 -o successful_image_update.mender
    # run tests on qemu
    if [ "$TEST_QEMU" = "true" ]
    then
        py.test
    fi

    (cd $WORKSPACE/meta-mender && cp -L $BUILDDIR/tmp/deploy/images/vexpress-qemu/u-boot.elf . )
    (cd $WORKSPACE/meta-mender && cp -L $BUILDDIR/tmp/deploy/images/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.sdimg . )
    cd $WORKSPACE/


    if [ "$UPLOAD_OUTPUT" = "true" ]
    then
    # store useful output to directory
    mkdir -p "vexpress-qemu-deploy"
        mv $BUILDDIR/tmp/deploy/* "vexpress-qemu-deploy"
    fi

    rm -rf build
fi

if [ "$BUILD_BBB" = "true" ]
then
    source oe-init-build-env
    cp ../mender-qa/build-conf/*  ./conf/

    cat >> ./conf/local.conf <<EOF
EXTERNALSRC_pn-mender = "$WORKSPACE/mender"
EXTERNALSRC_pn-mender-artifact = "$WORKSPACE/mender-artifact"
EXTERNALSRC_pn-mender-artifact-native = "$WORKSPACE/mender-artifact"
SSTATE_DIR = "/mnt/sstate-cache"
EOF
    disable_mender_service
    export MACHINE="beaglebone"
    bitbake core-image-base

    mkdir -p $WORKSPACE/beaglebone

    cp -L $BUILDDIR/tmp/deploy/images/beaglebone/core-image-base-beaglebone.ext4 $WORKSPACE/beaglebone/core-image-base-beaglebone.ext4
    cp -L $BUILDDIR/tmp/deploy/images/beaglebone/core-image-base-beaglebone.sdimg $WORKSPACE/beaglebone/core-image-base-beaglebone.sdimg
    cp -L $BUILDDIR/tmp/deploy/images/beaglebone/core-image-base-beaglebone.ext4 $WORKSPACE/beaglebone/core-image-base-beaglebone.ext4.clean
    cp -L $BUILDDIR/tmp/deploy/images/beaglebone/core-image-base-beaglebone.sdimg $WORKSPACE/beaglebone/core-image-base-beaglebone.sdimg.clean

    cd $WORKSPACE/meta-mender/tests/acceptance/
    export PATH=$PATH:$BUILDDIR/tmp/sysroots/x86_64-linux/usr/bin
    export BBB_IMAGE_DIR=$WORKSPACE/beaglebone

    if [ "$TEST_BBB" = "true" ]
    then
    bash prepare_ext4_testing.sh
    mender-artifact write rootfs-image -t beaglebone -n test-update -u core-image-base-beaglebone-modified-testing.ext4 -o successful_image_update.mender

        bash prepare_bbb_testing.sh || {
            kill -s TERM $(ps aux | grep ssh| grep wmd | awk '{print $2}') || true
            exit 1;
    }
    fi


    cp -L $WORKSPACE/beaglebone/core-image-base-beaglebone.ext4.clean $WORKSPACE/beaglebone/core-image-base-beaglebone.ext4
    cp -L $WORKSPACE/beaglebone/core-image-base-beaglebone.sdimg.clean  $WORKSPACE/beaglebone/core-image-base-beaglebone.sdimg

    # store useful output to directory

    if [ "$UPLOAD_OUTPUT" = "true" ]
    then
        cd $WORKSPACE/
    mkdir -p "beaglebone-deploy"
        mv $BUILDDIR/tmp/deploy/* "beaglebone-deploy"
    fi
fi

if [ "$UPLOAD_OUTPUT" = "true" ]
then
    cd $WORKSPACE
    tar acvf output.tar.xz  --ignore-failed-read "vexpress-qemu-deploy" "beaglebone-deploy"
    s3cmd put output.tar.xz s3://mender/temp/yoctobuilds/$BUILD_TAG/
    s3cmd setacl s3://mender/temp/yoctobuilds/$BUILD_TAG/output.tar.xz --acl-public
    echo "Download build output from: https://s3.amazonaws.com/mender/temp/yoctobuilds/${BUILD_TAG}/output.tar.xz"
fi
