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

modify_ext4() {
    echo -n "artifact_name=$2" > /tmp/artifactfile
    debugfs -w -R "rm /etc/mender/artifact_info" $1
    printf "cd %s\nwrite %s %s\n" /etc/mender /tmp/artifactfile artifact_info | debugfs -w $1
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

prepare_build_config() {
    /bin/cp $WORKSPACE/mender-qa/build-conf/*  $BUILDDIR/conf/

    # See comment in local.conf
    cat >> $BUILDDIR/conf/local.conf <<EOF
EXTERNALSRC_pn-mender = "$WORKSPACE/mender"
EXTERNALSRC_pn-mender-artifact = "$WORKSPACE/mender-artifact"
EXTERNALSRC_pn-mender-artifact-native = "$WORKSPACE/mender-artifact"
SSTATE_DIR = "/mnt/sstate-cache"
EOF

    # Setting these PREFERRED_VERSIONs doesn't influence which version we build,
    # since we are building the one that Jenkins has cloned, but it does
    # influence which version Yocto and the binaries will show.
    if [ -n "$RELEASE_VERSION" ]; then
        cat >> $BUILDDIR/conf/local.conf <<EOF
PREFERRED_VERSION_mender = "${RELEASE_VERSION}%"
PREFERRED_VERSION_mender-artifact = "${RELEASE_VERSION}%"
PREFERRED_VERSION_mender-artifact-native = "${RELEASE_VERSION}%"
EOF
    else
        cat >> $BUILDDIR/conf/local.conf <<EOF
PREFERRED_VERSION_mender = "master-git%"
PREFERRED_VERSION_mender-artifact = "master-git%"
PREFERRED_VERSION_mender-artifact-native = "master-git%"
EOF
    fi
}

if [ "$CLEAN_BUILD_CACHE" = "true" ]
then
    sudo rm -rf /mnt/sstate-cache/*
fi

if [ "$BUILD_QEMU" = "true" ]
then
    source oe-init-build-env build-qemu
    cd ../

    if [ ! -d mender-qa ]
    then
        echo "JENKINS SCRIPT: mender-qa directory is not present"
        exit 1
    fi

    prepare_build_config
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
    (cd $WORKSPACE/meta-mender && cp {core-image-full-cmdline-vexpress-qemu.ext4,core-image-full-cmdline-vexpress-qemu.sdimg,u-boot.elf} $WORKSPACE/vexpress-qemu )
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
    prepare_build_config
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
    cd $WORKSPACE
    # Set build dir for qemu again, BBB build might possibly have overridden
    # this.
    source oe-init-build-env build-qemu
    prepare_and_set_PATH


    cd $WORKSPACE/meta-mender/meta-mender-qemu
    cp $BUILDDIR/tmp/deploy/images/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.{ext4,sdimg} .
    cp $BUILDDIR/tmp/deploy/images/vexpress-qemu/u-boot.elf .

    docker build -t mendersoftware/mender-client-qemu:pr --build-arg VEXPRESS_IMAGE=core-image-full-cmdline-vexpress-qemu.sdimg --build-arg UBOOT_ELF=u-boot.elf .
    cat > $WORKSPACE/integration/docker-compose-pr-client.yml <<EOF
version: '2'
services:
    mender-client:
        image: mendersoftware/mender-client-qemu:pr
EOF
    cd $WORKSPACE/integration/tests && ./run.sh --docker-compose-file=../docker-compose-pr-client.yml

    if [ -n "$RELEASE_VERSION" ]; then
        s3cmd -F put core-image-full-cmdline-vexpress-qemu.ext4 s3://mender/temp_${RELEASE_VERSION}/core-image-full-cmdline-vexpress-qemu.ext4
        s3cmd setacl s3://mender/temp_${RELEASE_VERSION}/core-image-full-cmdline-vexpress-qemu.ext4 --acl-public

        cd $WORKSPACE/vexpress-qemu/
        modify_ext4 core-image-full-cmdline-vexpress-qemu.ext4 release-1
        mender-artifact write rootfs-image -t vexpress-qemu -n release-1 -u core-image-full-cmdline-vexpress-qemu.ext4 -o vexpress_release_1.mender
        modify_ext4 core-image-full-cmdline-vexpress-qemu.ext4 release-2
        mender-artifact write rootfs-image -t vexpress-qemu -n release-2 -u core-image-full-cmdline-vexpress-qemu.ext4 -o vexpress_release_2.mender
        s3cmd --cf-invalidate -F put vexpress_release_1.mender s3://mender/${RELEASE_VERSION}/vexpress-qemu/
        s3cmd --cf-invalidate -F put vexpress_release_2.mender s3://mender/${RELEASE_VERSION}/vexpress-qemu/
        s3cmd setacl s3://mender/${RELEASE_VERSION}/vexpress-qemu/vexpress_release_1.mender --acl-public
        s3cmd setacl s3://mender/${RELEASE_VERSION}/vexpress-qemu/vexpress_release_2.mender --acl-public

        cd $WORKSPACE/beaglebone/
        modify_ext4 core-image-base-beaglebone.ext4 release-1
        mender-artifact write rootfs-image -t beaglebone -n release-1 -u core-image-base-beaglebone.ext4 -o beaglebone_release_1.mender
        modify_ext4 core-image-base-beaglebone.ext4 release-2
        mender-artifact write rootfs-image -t beaglebone -n release-2 -u core-image-base-beaglebone.ext4 -o beaglebone_release_2.mender
        gzip -c core-image-base-beaglebone.sdimg > mender-beaglebone.sdimg.gz
        s3cmd --cf-invalidate -F put mender-beaglebone.sdimg.gz s3://mender/${RELEASE_VERSION}/beaglebone/
        s3cmd setacl s3://mender/${RELEASE_VERSION}/beaglebone/mender-beaglebone.sdimg.gz --acl-public
        s3cmd --cf-invalidate -F put beaglebone_release_1.mender s3://mender/${RELEASE_VERSION}/beaglebone/
        s3cmd --cf-invalidate -F put beaglebone_release_2.mender s3://mender/${RELEASE_VERSION}/beaglebone/
        s3cmd setacl s3://mender/${RELEASE_VERSION}/beaglebone/beaglebone_release_1.mender --acl-public
        s3cmd setacl s3://mender/${RELEASE_VERSION}/beaglebone/beaglebone_release_2.mender --acl-public

        docker login -u menderbuildsystem -p ${DOCKER_PASSWORD}
        docker tag mendersoftware/mender-client-qemu:pr mendersoftware/mender-client-qemu:${RELEASE_VERSION}
        docker push mendersoftware/mender-client-qemu:${RELEASE_VERSION}
    fi
fi
