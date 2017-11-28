#!/bin/bash

set -e -x

echo $WORKSPACE
#----
echo "Debug Jenkins setup"
ls /home/jenkins/.ssh
#----

PR_COMMENT_ENDPOINT=https://api.github.com/repos/mendersoftware/$REPO_TO_TEST/issues/$PR_TO_TEST/comments
PR_STATUS_ENDPOINT=https://api.github.com/repos/mendersoftware/$REPO_TO_TEST/statuses/$GIT_COMMIT
SSH_TUNNEL_IP=188.166.29.46
RPI3_PORT=2210
BBB_PORT=2211

export PATH=$PATH:~/workspace/yoctobuild/go/bin

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
    local machine
    machine=$1

    if [ -n "$machine" ]; then
        if [ -d $WORKSPACE/mender-qa/build-conf-${machine} ]; then
            /bin/cp $WORKSPACE/mender-qa/build-conf-${machine}/*  $BUILDDIR/conf/
        fi
    fi

    CLIENT_VERSION=$($WORKSPACE/integration/extra/release_tool.py --version-of mender)
    MENDER_ARTIFACT_VERSION=$($WORKSPACE/integration/extra/release_tool.py --version-of mender-artifact)

    # See comment in local.conf
    if egrep -q '^ *DISTRO_CODENAME *= *"morty" *$' $WORKSPACE/meta-poky/conf/distro/poky.conf || \
            egrep -q '^ *DISTRO_CODENAME *= *"pyro" *$' $WORKSPACE/meta-poky/conf/distro/poky.conf; then
        # Pyro and morty need old style full Go paths.
        cat >> $BUILDDIR/conf/local.conf <<EOF
EXTERNALSRC_pn-mender = "$WORKSPACE/go/src/github.com/mendersoftware/mender"
EXTERNALSRC_pn-mender-artifact = "$WORKSPACE/go/src/github.com/mendersoftware/mender-artifact"
EXTERNALSRC_pn-mender-artifact-native = "$WORKSPACE/go/src/github.com/mendersoftware/mender-artifact"
EOF
    else
        # Newer branches need new style single Go path
        cat >> $BUILDDIR/conf/local.conf <<EOF
EXTERNALSRC_pn-mender = "$WORKSPACE/go"
EXTERNALSRC_pn-mender-artifact = "$WORKSPACE/go"
EXTERNALSRC_pn-mender-artifact-native = "$WORKSPACE/go"
EOF
    fi

    cat >> $BUILDDIR/conf/local.conf <<EOF
SSTATE_DIR = "/mnt/sstate-cache"

MENDER_ARTIFACT_NAME = "mender-image-$CLIENT_VERSION"
EOF

    mender_on_exact_tag=$(cd $WORKSPACE/go/src/github.com/mendersoftware/mender && git describe --tags --exact-match HEAD 2>/dev/null) || mender_on_exact_tag=
    mender_artifact_on_exact_tag=$(cd $WORKSPACE/go/src/github.com/mendersoftware/mender-artifact && git describe --tags --exact-match HEAD 2>/dev/null) || mender_artifact_on_exact_tag=

    # Setting these PREFERRED_VERSIONs doesn't influence which version we build,
    # since we are building the one that Jenkins has cloned, but it does
    # influence which version Yocto and the binaries will show.
    if [ -n "$mender_on_exact_tag" ]; then
        cat >> $BUILDDIR/conf/local.conf <<EOF
PREFERRED_VERSION_pn-mender = "$mender_on_exact_tag"
EOF
    else
        cat >> $BUILDDIR/conf/local.conf <<EOF
PREFERRED_VERSION_pn-mender = "$CLIENT_VERSION-git%"
EOF
    fi

    if [ -n "$mender_artifact_on_exact_tag" ]; then
        cat >> $BUILDDIR/conf/local.conf <<EOF
PREFERRED_VERSION_pn-mender-artifact = "$mender_artifact_on_exact_tag"
PREFERRED_VERSION_pn-mender-artifact-native = "$mender_artifact_on_exact_tag"
EOF
    else
        cat >> $BUILDDIR/conf/local.conf <<EOF
PREFERRED_VERSION_pn-mender-artifact = "$MENDER_ARTIFACT_VERSION-git%"
PREFERRED_VERSION_pn-mender-artifact-native = "$MENDER_ARTIFACT_VERSION-git%"
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

build_custom_qemu() {
    # using released versions of qemu, we end up with this error:
    #   https://bugs.launchpad.net/qemu/+bug/1481272
    # installing from source doesn't exhibit this behaviour

    if [ ! -f /var/tmp/qemu-built ]; then
        git clone -b qemu-system-reset-race-fix \
            https://github.com/mendersoftware/qemu.git
        cd qemu
        git submodule update --init dtc

        ./configure --target-list=arm-softmmu \
                    --disable-werror \
                    --prefix=/usr \
                    --localstatedir=/var \
                        --sysconfdir=/etc \
                            --libexecdir=/usr/lib/qemu \
                        --disable-glusterfs \
                        --disable-debug-info \
                        --disable-bsd-user \
                        --disable-werror \
                        --disable-sdl \
                        --disable-xen \
                    --disable-attr \
                    --disable-gtk \

        sudo make install -j$(grep -c ^processor /proc/cpuinfo) V=1
        cd -
        touch /var/tmp/qemu-built
    fi
}

# ---------------------------------------------------
# Preliminary checks.
# ---------------------------------------------------

# Verify that version references are up to date.
$WORKSPACE/integration/extra/release_tool.py --verify-integration-references


# ---------------------------------------------------
# Build server repositories.
# ---------------------------------------------------

# Build Go repositories.
export GOPATH="$WORKSPACE/go"
(
    cd $WORKSPACE/go/src/github.com/mendersoftware/mender-artifact
    CGO_ENABLED=0 go build
)
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
# Build fake client
(
    cd go/src/github.com/mendersoftware/mender-stress-test-client
    go build
    go install
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
    github_pull_request_status "pending" "qemu build started" "$BUILD_URL" "qemu_build"
    source oe-init-build-env build-qemu
    cd ../

    if [ ! -d mender-qa ]
    then
        echo "JENKINS SCRIPT: mender-qa directory is not present"
        exit 1
    fi

    prepare_build_config qemu
    disable_mender_service
    cd $BUILDDIR
    bitbake core-image-full-cmdline || QEMU_BITBAKE_RESULT=$?

    if [[ $QEMU_BITBAKE_RESULT -eq 0 ]]; then
        github_pull_request_status "success" "qemu build completed" "$BUILD_URL" "qemu_build"
    else
        github_pull_request_status "failure" "qemu build failed" "$BUILD_URL" "qemu_build"
        exit $QEMU_BITBAKE_RESULT
    fi

    OLD_PATH="$PATH"
    prepare_and_set_PATH

    mkdir -p $WORKSPACE/vexpress-qemu

    export QEMU_SYSTEM_ARM="/usr/bin/qemu-system-arm"

    (cd $WORKSPACE/meta-mender && cp -L $BUILDDIR/tmp/deploy/images/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.ext4 . )
    (cd $WORKSPACE/meta-mender && cp -L $BUILDDIR/tmp/deploy/images/vexpress-qemu/u-boot.elf . )
    (cd $WORKSPACE/meta-mender && cp -L $BUILDDIR/tmp/deploy/images/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.sdimg . )
    (cd $WORKSPACE/meta-mender && cp {core-image-full-cmdline-vexpress-qemu.ext4,core-image-full-cmdline-vexpress-qemu.sdimg,u-boot.elf} $WORKSPACE/vexpress-qemu )

    # run tests on qemu
    if [ "$TEST_QEMU" = "true" ]; then

        # use original path when building qemu
        export PATH=$OLD_PATH
        build_custom_qemu
        ( cd $BUILDDIR && prepare_and_set_PATH )

        HTML_REPORT="--html=report.html --self-contained-html"
        if ! pip list|grep -e pytest-html >/dev/null 2>&1; then
            HTML_REPORT=""
            echo "WARNING: install pytest-html for html results report"
        fi

        github_pull_request_status "pending" "qemu acceptance tests started in Jenkins" "$BUILD_URL" "qemu_acceptance_tests"

        bitbake-layers add-layer "$WORKSPACE"/meta-mender/tests/meta-mender-ci

        QEMU_BITBAKE_RESULT=0
        bitbake core-image-full-cmdline || QEMU_BITBAKE_RESULT=$?
        if [ $QEMU_BITBAKE_RESULT -ne 0 ]; then
            github_pull_request_status "failure" "qemu acceptance tests failed" "$BUILD_URL" "qemu_acceptance_tests"
            exit $QEMU_BITBAKE_RESULT
        else
            github_pull_request_status "success" "qemu acceptance tests passed!" "$BUILD_URL" "qemu_acceptance_tests"
        fi

        cd $WORKSPACE/meta-mender/tests/acceptance/

        ACCEPTANCE_TEST_TO_RUN=""

        # make it possible to run specific test
        if [ -n "$ACCEPTANCE_TEST" ]; then
            ACCEPTANCE_TEST_TO_RUN=" -k $ACCEPTANCE_TEST"
        fi

        # run tests with xdist explicitly disabled
        QEMU_TESTING_STATUS=0
        py.test -p no:xdist --verbose --junit-xml=results.xml \
                $HTML_REPORT $ACCEPTANCE_TEST_TO_RUN || QEMU_TESTING_STATUS=$?

        if [ -n "$PR_TO_TEST" ]; then
            HTML_REPORT=$(find . -iname report.html  | head -n 1)
            REPORT_DIR=$BUILD_NUMBER
            s3cmd put $HTML_REPORT s3://mender-acceptance-mmc-reports/$REPORT_DIR/
            REPORT_URL=https://s3-eu-west-1.amazonaws.com/mender-acceptance-mmc-reports/$REPORT_DIR/report.html

            if [ $QEMU_TESTING_STATUS -ne 0 ]; then
                github_pull_request_status "failure" "qemu acceptance tests failed" $REPORT_URL "qemu_acceptance_tests"
                exit $QEMU_TESTING_STATUS
            else
                github_pull_request_status "success" "qemu acceptance tests passed!" $REPORT_URL "qemu_acceptance_tests"
            fi
        fi

        if [ $QEMU_TESTING_STATUS -ne 0 ]; then
            exit $QEMU_TESTING_STATUS
        fi
    fi

    cd $WORKSPACE/


    if [ "$UPLOAD_OUTPUT" = "true" ]
    then
    # store useful output to directory
    mkdir -p "vexpress-qemu-deploy"
        cp -r $BUILDDIR/tmp/deploy/* "vexpress-qemu-deploy"
    fi

    PATH="$OLD_PATH"
fi

if [ "$BUILD_QEMU_RAW_FLASH" = "true" ]
then
    github_pull_request_status "pending" "qemu-raw-flash build started" \
                               "$BUILD_URL" "qemu_flash_build"

    source oe-init-build-env build-qemu-flash
    cd ../

    if [ ! -d mender-qa ]
    then
        echo "JENKINS SCRIPT: mender-qa directory is not present"
        exit 1
    fi

    # use config for vexpress-qemu-flash
    prepare_build_config vexpress-qemu-flash
    disable_mender_service

    cd $BUILDDIR
    bitbake core-image-minimal || QEMU_BITBAKE_RESULT=$?

    if [[ $QEMU_BITBAKE_RESULT -eq 0 ]]; then
        github_pull_request_status "success" "qemu-raw-flash build completed" \
                                   "$BUILD_URL" "qemu_flash_build"
    else
        github_pull_request_status "failure" "qemu-raw-flash build failed" \
                                   "$BUILD_URL" "qemu_flash_build"
        exit $QEMU_BITBAKE_RESULT
    fi

    OLD_PATH="$PATH"
    prepare_and_set_PATH

    mkdir -p $WORKSPACE/vexpress-qemu-flash

    export QEMU_SYSTEM_ARM="/usr/bin/qemu-system-arm"

    # run tests on qemu
    if [ "$TEST_QEMU" = "true" ]; then

        # use original path when building qemu
        export PATH=$OLD_PATH
        build_custom_qemu
        ( cd $BUILDDIR && prepare_and_set_PATH )

        HTML_REPORT="--html=report.html --self-contained-html"
        if ! pip list|grep -e pytest-html >/dev/null 2>&1; then
            HTML_REPORT=""
            echo "WARNING: install pytest-html for html results report"
        fi

        github_pull_request_status "pending" "qemu-raw-flash acceptance tests started in Jenkins" \
                                   "$BUILD_URL" "qemu_flash_acceptance_tests"

        bitbake-layers add-layer "$WORKSPACE"/meta-mender/tests/meta-mender-ci

        bitbake core-image-minimal || QEMU_BITBAKE_RESULT=$?
        if [ $QEMU_BITBAKE_RESULT -ne 0 ]; then
            github_pull_request_status "failure" "qemu-raw-flash acceptance tests failed" \
                                       $REPORT_URL "qemu_flash_acceptance_tests"
            exit $QEMU_BITBAKE_RESULT
        else
            github_pull_request_status "success" "qemu-raw-flash acceptance tests passed!" \
                                       $REPORT_URL "qemu_flash_acceptance_tests"
        fi

        cd $WORKSPACE/meta-mender/tests/acceptance/

        # install test dependencies
        sudo pip2 install -r requirements.txt

        ACCEPTANCE_TEST_TO_RUN=""

        # make it possible to run specific test
        if [ -n "$ACCEPTANCE_TEST" ]; then
            ACCEPTANCE_TEST_TO_RUN=" -k $ACCEPTANCE_TEST"
        fi

        # run tests with xdist explicitly disabled
        QEMU_TESTING_STATUS=0
        py.test -p no:xdist --verbose --junit-xml=results.xml \
                --bitbake-image core-image-minimal \
                $HTML_REPORT $ACCEPTANCE_TEST_TO_RUN || QEMU_TESTING_STATUS=$?

        if [ -n "$PR_TO_TEST" ]; then
            HTML_REPORT=$(find . -iname report.html  | head -n 1)
            REPORT_DIR=$BUILD_NUMBER
            s3cmd put $HTML_REPORT s3://mender-acceptance-raw-flash-reports/$REPORT_DIR/
            REPORT_URL=https://s3-eu-west-1.amazonaws.com/mender-acceptance-raw-flash-reports/$REPORT_DIR/report.html

            if [ $QEMU_TESTING_STATUS -ne 0 ]; then
                github_pull_request_status "failure" "qemu-raw-flash acceptance tests failed" \
                                           $REPORT_URL "qemu_flash_acceptance_tests"
                exit $QEMU_TESTING_STATUS
            else
                github_pull_request_status "success" "qemu-raw-flash acceptance tests passed!" \
                                           $REPORT_URL "qemu_flash_acceptance_tests"
            fi
        fi

        if [ $QEMU_TESTING_STATUS -ne 0 ]; then
            exit $QEMU_TESTING_STATUS
        fi
    fi
fi

if [ "$BUILD_BBB" = "true" ]
then
    github_pull_request_status "pending" "Beaglebone build started" "$BUILD_URL" "beaglebone_build"
    cd "$WORKSPACE"
    source oe-init-build-env build-bbb
    prepare_build_config bbb
    disable_mender_service
    STATUS=0
    bitbake core-image-base || STATUS=$?

    if [[ $STATUS -eq 0 ]]; then
        github_pull_request_status "success" "Beaglebone build completed" "$BUILD_URL" "beaglebone_build"
    else
        github_pull_request_status "failure" "Beaglebone build failed" "$BUILD_URL" "beaglebone_build"
        exit $STATUS
    fi

    OLD_PATH="$PATH"
    prepare_and_set_PATH

    mkdir -p $WORKSPACE/beaglebone

    cp -L $BUILDDIR/tmp/deploy/images/beaglebone/core-image-base-beaglebone.ext4 $WORKSPACE/beaglebone/core-image-base-beaglebone.ext4
    cp -L $BUILDDIR/tmp/deploy/images/beaglebone/core-image-base-beaglebone.sdimg $WORKSPACE/beaglebone/core-image-base-beaglebone.sdimg
    cp -L $BUILDDIR/tmp/deploy/images/beaglebone/core-image-base-beaglebone.ext4 $WORKSPACE/beaglebone/core-image-base-beaglebone.ext4.clean
    cp -L $BUILDDIR/tmp/deploy/images/beaglebone/core-image-base-beaglebone.sdimg $WORKSPACE/beaglebone/core-image-base-beaglebone.sdimg.clean

    if [ "$TEST_BBB" = "true" ]; then
        rm -rf "$BUILDDIR"/tmp/

        /bin/cp ~/.ssh/id_rsa* "$WORKSPACE"/meta-mender/tests/meta-mender-beaglebone-ci/recipes-mender/mender-qa/files/beaglebone/
        bitbake-layers add-layer "$WORKSPACE"/meta-mender/tests/meta-mender-ci
        bitbake-layers add-layer "$WORKSPACE"/meta-mender/tests/meta-mender-beaglebone-ci
        prepare_and_set_PATH

        bitbake core-image-base
        ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t root@${SSH_TUNNEL_IP} -p ${BBB_PORT} "mender-qa activate-test-image off" || true

        COUNTER=0
        while [  $COUNTER -lt 5 ]; do
            SCP_EXIT_CODE=0
            scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -C -oPort=${BBB_PORT} "$BUILDDIR"/tmp/deploy/images/beaglebone/core-image-base-beaglebone.sdimg root@${SSH_TUNNEL_IP}:/tmp/ || SCP_EXIT_CODE=$?
            if [ "$SCP_EXIT_CODE" -ne 0 ]; then
                let COUNTER=COUNTER+1
                sleep 30
            else
                ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t root@${SSH_TUNNEL_IP} -p ${BBB_PORT} "mender-qa deploy-test-image" || true
                break
            fi
        done

        prepare_and_set_PATH
        cd $WORKSPACE/meta-mender/tests/acceptance/
        mender-artifact write rootfs-image -t beaglebone -n test-update -u "$BUILDDIR"/tmp/deploy/images/beaglebone/core-image-base-beaglebone.ext4 -o successful_image_update.mender
        github_pull_request_status "pending" "Beaglebone acceptance tests started" "$BUILD_URL" "beaglebone_acceptance_tests"
        STATUS=0
        pytest --host=${SSH_TUNNEL_IP}:${BBB_PORT} --board-type=bbb || STATUS=$?
        if [[ $STATUS -eq 0 ]]; then
            github_pull_request_status "success" "Beaglebone acceptance tests completed" "$BUILD_URL" "beaglebone_acceptance_tests"
        else
            github_pull_request_status "failure" "Beaglebone acceptance tests failed" "$BUILD_URL" "beaglebone_acceptance_tests"
            exit $STATUS
        fi
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

if [ "$BUILD_RPI3" = "true" ]
then
    github_pull_request_status "pending" "Raspberry Pi 3 build started" "$BUILD_URL" "rpi3_build"
    cd "$WORKSPACE"
    source oe-init-build-env build-rpi3
    prepare_build_config rpi3
    disable_mender_service

    if egrep -q '^ *DISTRO_CODENAME *= *"pyro" *$' $WORKSPACE/meta-poky/conf/distro/poky.conf; then
        sed -i '/USE_U_BOOT/d' conf/local.conf
        echo 'KERNEL_IMAGETYPE = "uImage"' >> conf/local.conf
        echo 'IMAGE_BOOT_FILES_append = " boot.scr u-boot.bin;${SDIMG_KERNELIMAGE}"' >> conf/local.conf
    fi

    cat conf/local.conf

    bitbake core-image-full-cmdline || RPI3_BITBAKE_RESULT=$?

    if [[ $RPI3_BITBAKE_RESULT -eq 0 ]]; then
        github_pull_request_status "success" "Raspberry Pi 3 build completed" \
                                   "$BUILD_URL" "rpi3_build"
    else
        github_pull_request_status "failure" "Raspberry Pi 3 build failed" \
                                   "$BUILD_URL" "rpi3_build"
        exit $RPI3_BITBAKE_RESULT
    fi


    OLD_PATH="$PATH"
    prepare_and_set_PATH

    mkdir -p "$WORKSPACE"/rpi3

    cp -L "$BUILDDIR"/tmp/deploy/images/raspberrypi3/core-image-full-cmdline-raspberrypi3.ext4 "$WORKSPACE"/rpi3/core-image-full-cmdline-raspberrypi3.ext4
    cp -L "$BUILDDIR"/tmp/deploy/images/raspberrypi3/core-image-full-cmdline-raspberrypi3.sdimg "$WORKSPACE"/rpi3/core-image-full-cmdline-raspberrypi3.sdimg


    if [ "$TEST_RPI3" = "true" ]; then
        rm -rf "$BUILDDIR"/tmp/

        bitbake-layers add-layer "$WORKSPACE"/meta-mender/tests/meta-mender-ci
        bitbake-layers add-layer "$WORKSPACE"/meta-mender/tests/meta-mender-raspberrypi3-ci

        cp ~/.ssh/id_rsa* "$WORKSPACE"/meta-mender/tests/meta-mender-raspberrypi3-ci/recipes-mender/mender-qa/files/rpi/
        bitbake core-image-full-cmdline
        ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t root@${SSH_TUNNEL_IP} -p ${RPI3_PORT} "/usr/share/mender-qa/activate-test-image off" || true

        COUNTER=0
        while [  $COUNTER -lt 5 ]; do
            SCP_EXIT_CODE=0
           scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -C -oPort=${RPI3_PORT} "$WORKSPACE"/build-rpi3/tmp/deploy/images/raspberrypi3/core-image-full-cmdline-raspberrypi3.sdimg root@${SSH_TUNNEL_IP}:/tmp/ || SCP_EXIT_CODE=$?
           if [ "$SCP_EXIT_CODE" -ne 0 ]; then
              let COUNTER=COUNTER+1
              sleep 30
           else
              ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t root@${SSH_TUNNEL_IP} -p ${RPI3_PORT} "/usr/share/mender-qa/deploy-test-image" || true
              break
           fi
        done

        prepare_and_set_PATH
        cd "$WORKSPACE"/meta-mender/tests/acceptance/
        mender-artifact write rootfs-image -t raspberrypi3 -n test-update -u "$WORKSPACE"/build-rpi3/tmp/deploy/images/raspberrypi3/core-image-full-cmdline-raspberrypi3.ext4 -o successful_image_update.mender
        github_pull_request_status "pending" "Raspberry Pi 3 acceptance tests started" "$BUILD_URL" "rpi3_acceptance_tests"
        STATUS=0
        pytest --host=${SSH_TUNNEL_IP}:${RPI3_PORT} --board-type=rpi3 || STATUS=$?
        if [[ $STATUS -eq 0 ]]; then
            github_pull_request_status "success" "Raspberry Pi 3 acceptance tests completed" "$BUILD_URL" "rpi3_acceptance_tests"
        else
            github_pull_request_status "failure" "Raspberry Pi 3 acceptance tests failed" "$BUILD_URL" "rpi3_acceptance_tests"
            exit $STATUS
        fi
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

    github_pull_request_status "pending" "integration tests have started in Jenkins" "$BUILD_URL" "integration_$INTEGRATION_REV"

    INTEGRATION_TESTING_STATUS=0
    cd $WORKSPACE/integration/tests && ./run.sh || INTEGRATION_TESTING_STATUS=$?


    HTML_REPORT=$(find . -iname report.html  | head -n 1)
    REPORT_DIR=$BUILD_NUMBER

    s3cmd put $HTML_REPORT s3://mender-integration-reports/$REPORT_DIR/
    REPORT_URL=https://s3-eu-west-1.amazonaws.com/mender-integration-reports/$REPORT_DIR/report.html

    if [ $INTEGRATION_TESTING_STATUS -ne 0 ]; then
        github_pull_request_status "failure" "integration tests failed" $REPORT_URL "integration_$INTEGRATION_REV"
    else
        github_pull_request_status "success" "integration tests passed!" $REPORT_URL "integration_$INTEGRATION_REV"
    fi

    # Reset docker tag names to their cloned values after tests are done.
    cd $WORKSPACE/integration
    git checkout -f -- .

    if [ "$INTEGRATION_TESTING_STATUS" -ne 0 ]; then
        exit $INTEGRATION_TESTING_STATUS
    fi

    if [ "$PUSH_CONTAINERS" = true ]; then
        CLIENT_VERSION=$($WORKSPACE/integration/extra/release_tool.py --version-of mender)
        MENDER_ARTIFACT_VERSION=$($WORKSPACE/integration/extra/release_tool.py --version-of mender-artifact)

        s3cmd --cf-invalidate -F put $WORKSPACE/go/src/github.com/mendersoftware/mender-artifact/mender-artifact s3://mender/mender-artifact/${MENDER_ARTIFACT_VERSION}/
        s3cmd setacl s3://mender/mender-artifact/${MENDER_ARTIFACT_VERSION}/mender-artifact --acl-public

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


        cd $WORKSPACE/rpi3/
        modify_ext4 core-image-full-cmdline-raspberrypi3.ext4 release-1_${CLIENT_VERSION}
        mender-artifact write rootfs-image -t raspberrypi3 -n release-1_${CLIENT_VERSION} -u core-image-full-cmdline-raspberrypi3.ext4 -o raspberrypi3_release_1_${CLIENT_VERSION}.mender
        modify_ext4 core-image-full-cmdline-raspberrypi3.ext4 release-2_${CLIENT_VERSION}
        mender-artifact write rootfs-image -t raspberrypi3 -n release-2_${CLIENT_VERSION} -u core-image-full-cmdline-raspberrypi3.ext4 -o raspberrypi3_release_2_${CLIENT_VERSION}.mender
        gzip -c core-image-full-cmdline-raspberrypi3.sdimg > mender-raspberrypi3_${CLIENT_VERSION}.sdimg.gz
        s3cmd --cf-invalidate -F put mender-raspberrypi3_${CLIENT_VERSION}.sdimg.gz s3://mender/${CLIENT_VERSION}/raspberrypi3/
        s3cmd setacl s3://mender/${CLIENT_VERSION}/raspberrypi3/mender-raspberrypi3_${CLIENT_VERSION}.sdimg.gz --acl-public
        s3cmd --cf-invalidate -F put raspberrypi3_release_1_${CLIENT_VERSION}.mender s3://mender/${CLIENT_VERSION}/raspberrypi3/
        s3cmd --cf-invalidate -F put raspberrypi3_release_2_${CLIENT_VERSION}.mender s3://mender/${CLIENT_VERSION}/raspberrypi3/
        s3cmd setacl s3://mender/${CLIENT_VERSION}/raspberrypi3/raspberrypi3_release_1_${CLIENT_VERSION}.mender --acl-public
        s3cmd setacl s3://mender/${CLIENT_VERSION}/raspberrypi3/raspberrypi3_release_2_${CLIENT_VERSION}.mender --acl-public

        docker login -u menderbuildsystem -p ${DOCKER_PASSWORD}

        for container in mender-client-qemu api-gateway deployments deviceadm deviceauth gui inventory useradm; do
            VERSION=$($WORKSPACE/integration/extra/release_tool.py --version-of $container)
            docker tag mendersoftware/$container:pr mendersoftware/$container:${VERSION}
            docker push mendersoftware/$container:${VERSION}
        done
    fi
fi
