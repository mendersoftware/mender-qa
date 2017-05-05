#!/bin/bash

set -e -x

echo $WORKSPACE
#----
echo "Debug Jenkins setup"
ls /home/jenkins/.ssh
#----

PR_COMMENT_ENDPOINT=https://api.github.com/repos/mendersoftware/$REPO_TO_TEST/issues/$PR_TO_TEST/comments
PR_STATUS_ENDPOINT=https://api.github.com/repos/mendersoftware/$REPO_TO_TEST/statuses/$GIT_COMMIT

declare -A TEST_TRACKER

function testFinished {
    for i in "${!TEST_TRACKER[@]}"
    do
        if [[ "${TEST_TRACKER[$i]}" == "pending" ]]; then
            github_pull_request_status "failure" "tests errored." $BUILD_URL $i
            return
        fi
    done

    if [[ ${#TEST_TRACKER[@]} -eq 0 ]]; then
        github_pull_request_comment "Jenkins build [job]($BUILD_URL) failed."
    fi
}

if [ -n "$PR_TO_TEST" ]; then
    trap testFinished SIGHUP SIGINT SIGTERM SIGKILL EXIT
fi

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

github_pull_request_comment() {
    local request_body=$(cat <<EOF
    {
      "body": "$1"
    }
EOF
)
    curl --user "$GITHUB_BOT_USER:$GITHUB_BOT_PASSWORD" \
         -d "$request_body" \
         "$PR_COMMENT_ENDPOINT"
}

github_pull_request_status() {
    if [[ -z $PR_TO_TEST ]]; then
        return
    fi

    TEST_TRACKER[$4]=$1
    local request_body=$(cat <<EOF
    {
      "state": "$1",
      "description": "$2",
      "target_url": "$3",
      "context": "$4"
    }
EOF
)
    curl --user "$GITHUB_BOT_USER:$GITHUB_BOT_PASSWORD" \
         -d "$request_body" \
         "$PR_STATUS_ENDPOINT"
}

prepare_and_set_PATH() {
    # On branches without recipe specific sysroots, the next step will fail
    # because the prepare_recipe_sysroot task doesn't exist. Use that failure
    # to fall back to the old generic sysroot path.
    if bitbake -c prepare_recipe_sysroot mender-test-dependencies; then
        eval `bitbake -e mender-test-dependencies | grep '^export PATH='`:$PATH
    else
        eval `bitbake -e core-image-minimal | grep '^export PATH='`:$PATH
    fi
}

prepare_build_config() {
    /bin/cp $WORKSPACE/mender-qa/build-conf/*  $BUILDDIR/conf/

    CLIENT_VERSION=$($WORKSPACE/integration/extra/release_tool.py --version-of mender)

    # See comment in local.conf
    cat >> $BUILDDIR/conf/local.conf <<EOF
EXTERNALSRC_pn-mender = "$WORKSPACE/mender"
EXTERNALSRC_pn-mender-artifact = "$WORKSPACE/mender-artifact"
EXTERNALSRC_pn-mender-artifact-native = "$WORKSPACE/mender-artifact"
SSTATE_DIR = "/mnt/sstate-cache"

MENDER_ARTIFACT_NAME = "mender-image-${CLIENT_VERSION}"
EOF

    # Setting these PREFERRED_VERSIONs doesn't influence which version we build,
    # since we are building the one that Jenkins has cloned, but it does
    # influence which version Yocto and the binaries will show.
    if [ "$PUSH_CONTAINERS" = true ]; then
        cat >> $BUILDDIR/conf/local.conf <<EOF
PREFERRED_VERSION_mender = "${CLIENT_VERSION}%"
PREFERRED_VERSION_mender-artifact = "${CLIENT_VERSION}%"
PREFERRED_VERSION_mender-artifact-native = "${CLIENT_VERSION}%"
EOF
    else
        cat >> $BUILDDIR/conf/local.conf <<EOF
PREFERRED_VERSION_mender = "master-git%"
PREFERRED_VERSION_mender-artifact = "master-git%"
PREFERRED_VERSION_mender-artifact-native = "master-git%"
EOF
    fi

    # Figure out which branch of poky we're building.
    if egrep -q '^ *DISTRO_CODENAME *= *"morty" *$' $WORKSPACE/meta-poky/conf/distro/poky.conf; then
        # Morty needs oe-meta-go
        cat >> $BUILDDIR/conf/bblayers.conf <<EOF
BBLAYERS_append = " /home/jenkins/workspace/yoctobuild/oe-meta-go"
EOF
    fi
}

# ---------------------------------------------------
# Build server repositories.
# ---------------------------------------------------

# Build Go repositories.
export GOPATH="$WORKSPACE/go"
for build in deployments deviceadm deviceauth inventory useradm; do (

    # If we are testing a specific microservice, only build that one.
    if [[ -n $REPO_TO_TEST && $build != $REPO_TO_TEST ]]; then
        continue
    fi

    $WORKSPACE/integration/extra/release_tool.py --set-version-of $build --version pr
    cd go/src/github.com/mendersoftware/$build
    CGO_ENABLED=0 go build
    docker build -t mendersoftware/$build:pr .
); done
# Build GUI
(
    $WORKSPACE/integration/extra/release_tool.py --set-version-of gui --version pr
    cd gui
    gulp build
    docker build -t mendersoftware/gui:pr .
)
# Build other repositories
(
    $WORKSPACE/integration/extra/release_tool.py --set-version-of mender-api-gateway-docker --version pr
    cd mender-api-gateway-docker
    docker build -t mendersoftware/api-gateway:pr .
)

# -----------------------
# Done with server build.
# -----------------------

if [ "$CLEAN_BUILD_CACHE" = "true" ]
then
    sudo rm -rf /mnt/sstate-cache/*
fi

if [ "$BUILD_QEMU" = "true" ]
then
    github_pull_request_status "pending" "qemu build started" "" "qemu_build"
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

    $? && github_pull_request_status "success" "qemu build complete" "" "qemu_build" \
       || github_pull_request_status "failure" "qemu build failed" "" "qemu_build"

    OLD_PATH="$PATH"
    prepare_and_set_PATH

    mkdir -p $WORKSPACE/vexpress-qemu

    cd $WORKSPACE/meta-mender/tests/acceptance/

    export QEMU_SYSTEM_ARM="/usr/bin/qemu-system-arm"

    mender-artifact write rootfs-image -t vexpress-qemu -n test-update -u $BUILDDIR/tmp/deploy/images/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.ext4 -o successful_image_update.mender
    # run tests on qemu
    if [ "$TEST_QEMU" = "true" ]; then

        HTML_REPORT="--html=report.html --self-contained-html"
        if ! pip list|grep -e pytest-html >/dev/null 2>&1; then
            HTML_REPORT=""
            echo "WARNING: install pytest-html for html results report"
        fi

        github_pull_request_status "pending" "qemu acceptance tests started" "" "qemu_acceptance_tests"
        py.test --verbose --junit-xml=results.xml $HTML_REPORT
        QEMU_TESTING_STATUS=$?

        if [ -n "$PR_TO_TEST" ]; then
            HTML_REPORT=$(find . -iname report.html  | head -n 1)
            REPORT_DIR=$BUILD_NUMBER
            s3cmd put $HTML_REPORT s3://mender-acceptance-reports/$REPORT_DIR/
            REPORT_URL=https://s3-eu-west-1.amazonaws.com/mender-acceptance-reports/$REPORT_DIR/report.html

            if [ $QEMU_TESTING_STATUS -ne 0 ]; then
                github_pull_request_status "failure" "qemu acceptance tests failed" $REPORT_URL "qemu_acceptance_tests"
            else
                github_pull_request_status "success" "qemu acceptance tests passed!" $REPORT_URL "qemu_acceptance_tests"
            fi
        fi

        if [ $QEMU_TESTING_STATUS -ne 0 ]; then
            exit $QEMU_TESTING_STATUS
        fi
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
    if [ "$BUILD_QEMU" = "true" ]; then
        cd $WORKSPACE
        # Set build dir for qemu again, BBB build might possibly have overridden
        # this.
        source oe-init-build-env build-qemu
        prepare_and_set_PATH

        cd $WORKSPACE/meta-mender/meta-mender-qemu
        cp $BUILDDIR/tmp/deploy/images/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.{ext4,sdimg} .
        cp $BUILDDIR/tmp/deploy/images/vexpress-qemu/u-boot.elf .

        docker build -t mendersoftware/mender-client-qemu:pr --build-arg VEXPRESS_IMAGE=core-image-full-cmdline-vexpress-qemu.sdimg --build-arg UBOOT_ELF=u-boot.elf .
        $WORKSPACE/integration/extra/release_tool.py --set-version-of mender --version pr
    fi

    github_pull_request_status "pending" "integration tests have started.." "" "integration"

    cd $WORKSPACE/integration/tests && ./run.sh
    INTEGRATION_TESTING_STATUS=$?

    # if it is a PR, make and publish the report
    if [ -n "$PR_TO_TEST" ]; then
        HTML_REPORT=$(find . -iname report.html  | head -n 1)
        REPORT_DIR=$BUILD_NUMBER

        s3cmd put $HTML_REPORT s3://mender-integration-reports/$REPORT_DIR/
        REPORT_URL=https://s3-eu-west-1.amazonaws.com/mender-integration-reports/$REPORT_DIR/report.html

        if [ $INTEGRATION_TESTING_STATUS -ne 0 ]; then
            github_pull_request_status "failure" "integration tests failed" $REPORT_URL "integration"
        else
            github_pull_request_status "success" "integration tests passed!" $REPORT_URL "integration"
        fi
    fi

    # Reset docker tag names to their cloned values after tests are done.
    cd $WORKSPACE/integration
    git checkout -f -- .

    if [ $INTEGRATION_TESTING_STATUS -ne 0 ]; then
        exit $INTEGRATION_TESTING_STATUS
    fi

    if [ "$PUSH_CONTAINERS" = true ]; then
        CLIENT_VERSION=$($WORKSPACE/integration/extra/release_tool.py --version-of mender)

        cd $WORKSPACE/vexpress-qemu/
        s3cmd -F put core-image-full-cmdline-vexpress-qemu.ext4 s3://mender/temp_${CLIENT_VERSION}/core-image-full-cmdline-vexpress-qemu.ext4
        s3cmd setacl s3://mender/temp_${CLIENT_VERSION}/core-image-full-cmdline-vexpress-qemu.ext4 --acl-public

        modify_ext4 core-image-full-cmdline-vexpress-qemu.ext4 release-1_${CLIENT_VERSION}
        mender-artifact write rootfs-image -t vexpress-qemu -n release-1_${CLIENT_VERSION} -u core-image-full-cmdline-vexpress-qemu.ext4 -o vexpress_release_1_${CLIENT_VERSION}.mender
        modify_ext4 core-image-full-cmdline-vexpress-qemu.ext4 release-2_${CLIENT_VERSION}
        mender-artifact write rootfs-image -t vexpress-qemu -n release-2_${CLIENT_VERSION} -u core-image-full-cmdline-vexpress-qemu.ext4 -o vexpress_release_2_${CLIENT_VERSION}.mender
        s3cmd --cf-invalidate -F put vexpress_release_1_${CLIENT_VERSION}.mender s3://mender/${CLIENT_VERSION}/vexpress-qemu/
        s3cmd --cf-invalidate -F put vexpress_release_2_${CLIENT_VERSION}.mender s3://mender/${CLIENT_VERSION}/vexpress-qemu/
        s3cmd setacl s3://mender/${CLIENT_VERSION}/vexpress-qemu/vexpress_release_1_${CLIENT_VERSION}.mender --acl-public
        s3cmd setacl s3://mender/${CLIENT_VERSION}/vexpress-qemu/vexpress_release_2_${CLIENT_VERSION}.mender --acl-public

        cd $WORKSPACE/beaglebone/
        modify_ext4 core-image-base-beaglebone.ext4 release-1_${CLIENT_VERSION}
        mender-artifact write rootfs-image -t beaglebone -n release-1_${CLIENT_VERSION} -u core-image-base-beaglebone.ext4 -o beaglebone_release_1_${CLIENT_VERSION}.mender
        modify_ext4 core-image-base-beaglebone.ext4 release-2_${CLIENT_VERSION}
        mender-artifact write rootfs-image -t beaglebone -n release-2_${CLIENT_VERSION} -u core-image-base-beaglebone.ext4 -o beaglebone_release_2_${CLIENT_VERSION}.mender
        gzip -c core-image-base-beaglebone.sdimg > mender-beaglebone_${CLIENT_VERSION}.sdimg.gz
        s3cmd --cf-invalidate -F put mender-beaglebone_${CLIENT_VERSION}.sdimg.gz s3://mender/${CLIENT_VERSION}/beaglebone/
        s3cmd setacl s3://mender/${CLIENT_VERSION}/beaglebone/mender-beaglebone_${CLIENT_VERSION}.sdimg.gz --acl-public
        s3cmd --cf-invalidate -F put beaglebone_release_1_${CLIENT_VERSION}.mender s3://mender/${CLIENT_VERSION}/beaglebone/
        s3cmd --cf-invalidate -F put beaglebone_release_2_${CLIENT_VERSION}.mender s3://mender/${CLIENT_VERSION}/beaglebone/
        s3cmd setacl s3://mender/${CLIENT_VERSION}/beaglebone/beaglebone_release_1_${CLIENT_VERSION}.mender --acl-public
        s3cmd setacl s3://mender/${CLIENT_VERSION}/beaglebone/beaglebone_release_2_${CLIENT_VERSION}.mender --acl-public

        docker login -u menderbuildsystem -p ${DOCKER_PASSWORD}

        for container in mender-client-qemu api-gateway deployments deviceadm deviceauth gui inventory useradm; do
            VERSION=$($WORKSPACE/integration/extra/release_tool.py --version-of $container)
            docker tag mendersoftware/$container:pr mendersoftware/$container:${VERSION}
            docker push mendersoftware/$container:${VERSION}
        done
    fi
fi
