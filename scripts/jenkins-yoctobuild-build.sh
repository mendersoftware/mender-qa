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

prepare_and_set_PATH() {
    # On branches without recipe specific sysroots, the next step will fail
    # because the prepare_recipe_sysroot task doesn't exist. Use that failure
    # to fall back to the old generic sysroot path.
    if bitbake -c prepare_recipe_sysroot mender-test-dependencies; then
        eval `bitbake -e mender-test-dependencies | grep '^export PATH='`
    else
        eval `bitbake -e core-image-minimal | grep '^export PATH='`
    fi
}

if [ "$CLEAN_BUILD_CACHE" = "true" ]
then
    sudo rm -rf /mnt/sstate-cache/*
fi

# Temporary fixes.
cd oe-meta-go
patch -p1 < ../mender-qa/patches/0001-Make-sure-the-sstate-mechanism-doesn-t-try-to-mangle.patch
cd ..

if [ "$BUILD_QEMU" = "true" ]
then
    source oe-init-build-env build-qemu
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
    cd $BUILDDIR
    bitbake core-image-full-cmdline

    OLD_PATH="$PATH"
    prepare_and_set_PATH

    mkdir -p $WORKSPACE/vexpress-qemu

    cd $WORKSPACE/meta-mender/tests/acceptance/

    export QEMU_SYSTEM_ARM="/usr/bin/qemu-system-arm"

    mender-artifact write rootfs-image -t vexpress-qemu -n test-update -u $BUILDDIR/tmp/deploy/images/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.ext4 -o successful_image_update.mender
    # run tests on qemu
    if [ "$TEST_QEMU" = "true" ]
    then
        py.test --junit-xml=results.xml
    fi

    (cd $WORKSPACE/meta-mender && cp -L $BUILDDIR/tmp/deploy/images/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.ext4 . )
    (cd $WORKSPACE/meta-mender && cp -L $BUILDDIR/tmp/deploy/images/vexpress-qemu/u-boot.elf . )
    (cd $WORKSPACE/meta-mender && cp -L $BUILDDIR/tmp/deploy/images/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.sdimg . )
    cd $WORKSPACE/


    if [ "$UPLOAD_OUTPUT" = "true" ]
    then
    # store useful output to directory
    mkdir -p "vexpress-qemu-deploy"
        cp -r $BUILDDIR/tmp/deploy/* "vexpress-qemu-deploy"
    fi

    PATH="$OLD_PATH"

    rm -rf build
fi

if [ "$BUILD_BBB" = "true" ]
then
    source oe-init-build-env build-bbb
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

    OLD_PATH="$PATH"
    prepare_and_set_PATH

    mkdir -p $WORKSPACE/beaglebone

    cp -L $BUILDDIR/tmp/deploy/images/beaglebone/core-image-base-beaglebone.ext4 $WORKSPACE/beaglebone/core-image-base-beaglebone.ext4
    cp -L $BUILDDIR/tmp/deploy/images/beaglebone/core-image-base-beaglebone.sdimg $WORKSPACE/beaglebone/core-image-base-beaglebone.sdimg
    cp -L $BUILDDIR/tmp/deploy/images/beaglebone/core-image-base-beaglebone.ext4 $WORKSPACE/beaglebone/core-image-base-beaglebone.ext4.clean
    cp -L $BUILDDIR/tmp/deploy/images/beaglebone/core-image-base-beaglebone.sdimg $WORKSPACE/beaglebone/core-image-base-beaglebone.sdimg.clean

    cd $WORKSPACE/meta-mender/tests/acceptance/
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
        cp -r $BUILDDIR/tmp/deploy/* "beaglebone-deploy"
    fi

    PATH="$OLD_PATH"
fi

if [ "$UPLOAD_OUTPUT" = "true" ]
then
    cd $WORKSPACE
    tar acvf output.tar.xz  --ignore-failed-read "vexpress-qemu-deploy" "beaglebone-deploy"
    s3cmd put output.tar.xz s3://mender/temp/yoctobuilds/$BUILD_TAG/
    s3cmd setacl s3://mender/temp/yoctobuilds/$BUILD_TAG/output.tar.xz --acl-public
    echo "Download build output from: https://s3.amazonaws.com/mender/temp/yoctobuilds/${BUILD_TAG}/output.tar.xz"
fi


if [ "$RUN_INTEGRATION_TESTS" = "true" ]; then
    cd /home/jenkins/workspace/yoctobuild/meta-mender/meta-mender-qemu
    cp ../core-image-full-cmdline-vexpress-qemu.ext4 ../core-image-full-cmdline-vexpress-qemu.sdimg ../u-boot.elf .

    s3cmd -F put core-image-full-cmdline-vexpress-qemu.ext4 s3://mender/temp/core-image-full-cmdline-vexpress-qemu.ext4
    s3cmd setacl s3://mender/temp/core-image-full-cmdline-vexpress-qemu.ext4 --acl-public

    sudo docker build -t mendersoftware/mender-client-qemu:latest --build-arg VEXPRESS_IMAGE=core-image-full-cmdline-vexpress-qemu.sdimg --build-arg UBOOT_ELF=u-boot.elf .
    cd $WORKSPACE/integration/tests && sudo ./run.sh
fi
