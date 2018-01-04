#!/bin/bash

set -e -x

echo $WORKSPACE

PR_COMMENT_ENDPOINT=https://api.github.com/repos/mendersoftware/$REPO_TO_TEST/issues/$PR_TO_TEST/comments
PR_STATUS_ENDPOINT=https://api.github.com/repos/mendersoftware/$REPO_TO_TEST/statuses/$GIT_COMMIT
SSH_TUNNEL_IP=188.166.29.46
RASPBERRYPI3_PORT=2210
BEAGLEBONEBLACK_PORT=2211

export PATH=$PATH:$WORKSPACE/go/bin

declare -A TEST_TRACKER

if [[ $STOP_SLAVE = "true" ]]; then
	touch $HOME/stop_slave
else
	if [[ -f $HOME/stop_slave ]]; then
        rm $HOME/stop_slave
    fi
fi

# patch Fabric
wget https://github.com/fabric/fabric/commit/b60247d78e9a7b541b3ed5de290fdeef2039c6df.patch || true
sudo patch -p1 /usr/local/lib/python2.7/dist-packages/fabric/network.py b60247d78e9a7b541b3ed5de290fdeef2039c6df.patch || true

# required to enable multi-tenant tests
cp $WORKSPACE/go/src/github.com/mendersoftware/tenantadm/docker-compose.mt.yml $WORKSPACE/integration/

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

is_poky_branch() {
    if egrep -q "^ *DISTRO_CODENAME *= *\"$1\" *\$" $WORKSPACE/meta-poky/conf/distro/poky.conf; then
        return 0
    else
        return 1
    fi
}

# Should not be called directly. See next two functions.
is_doing_board() {
    local ret=0
    # The param is just to be able to test for both "BUILD" and "TEST" variables
    # in the same case statement.
    local param="$2"
    case "$1" in
        vexpress-qemu)
            eval test "\$${param}_QEMU_SDIMG" = true && grep "mender_qemu_sdimg" <<<"$JOB_BASE_NAME" || ret=$?
            ;;
        vexpress-qemu-flash)
            eval test "\$${param}_QEMU_RAW_FLASH" = true && grep "mender_qemu_flash" <<<"$JOB_BASE_NAME" || ret=$?
            ;;
        beagleboneblack)
            eval test "\$${param}_BEAGLEBONEBLACK" = true && grep "mender_beagleboneblack" <<<"$JOB_BASE_NAME" || ret=$?
            ;;
        raspberrypi3)
            eval test "\$${param}_RASPBERRYPI3" = true && grep "mender_raspberrypi3" <<<"$JOB_BASE_NAME" || ret=$?
            ;;
        *)
            echo "Unrecognized board: $1"
            exit 1
            ;;
    esac
    return $ret
}

is_building_board() {
    local ret=0
    is_doing_board "$1" "BUILD" || ret=$?
    return $ret
}

is_testing_board() {
    local ret=0
    is_doing_board "$1" "TEST" || ret=$?
    return $ret
}

port_for_board() {
    eval echo \$$(tr '[:lower:]' '[:upper:]' <<<"$1")_PORT
}

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


board_support_update() {
    local board=$1
    local status=$2

    local git_commit=$(cd "$WORKSPACE"/meta-mender/ && git log --pretty=format:"%h" | head -n 1)
    local request_body=$(cat <<EOF
    {
      "jenkins_url": "$BUILD_URL",
      "commit": "$git_commit",
      "branch": "$META_MENDER_REV",
      "build": $BUILD_NUMBER,
      "status": "$status"
    }
EOF
)

    curl -u "$BS_JENKINS_AUTH" -H "Content-Type: application/json" \
         -d "$request_body" \
         -X POST https://board-support.mender.io/board/"$board"/ci_report || true
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

copy_build_conf() {
    # Get dst from last argument.
    eval "local dst=\"\$$#\""

    while [ -n "$2" ]; do
        local src="$1"
        local tmpfile="$(mktemp)"

        if grep /home/jenkins "$src"; then
            echo "Please do not specify /home/jenkins directly in any build-conf files. Use @WORKSPACE@."
            return 1
        fi

        sed -e "s%@WORKSPACE@%$WORKSPACE%g" "$src" > "$tmpfile"

        if [ -d "$dst" ]; then
            mv "$tmpfile" "$dst/$(basename "$src")"
        else
            mv "$tmpfile" "$dst"
        fi

        shift
    done
}

prepare_build_config() {
    local machine
    machine=$1

    if [ -n "$machine" ]; then
        if [ -d $WORKSPACE/meta-mender/tests/build-conf/${machine} ]; then
            copy_build_conf $WORKSPACE/meta-mender/tests/build-conf/${machine}/*  $BUILDDIR/conf/
        fi
    fi

    local client_version=$($WORKSPACE/integration/extra/release_tool.py --version-of mender)
    local mender_artifact_version=$($WORKSPACE/integration/extra/release_tool.py --version-of mender-artifact)

    # See comment in local.conf
    if is_poky_branch morty || is_poky_branch pyro; then
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

MENDER_ARTIFACT_NAME = "mender-image-$client_version"
EOF

    local mender_on_exact_tag=$(cd $WORKSPACE/go/src/github.com/mendersoftware/mender && git describe --tags --exact-match HEAD 2>/dev/null) || mender_on_exact_tag=
    local mender_artifact_on_exact_tag=$(cd $WORKSPACE/go/src/github.com/mendersoftware/mender-artifact && git describe --tags --exact-match HEAD 2>/dev/null) || mender_artifact_on_exact_tag=

    # Setting these PREFERRED_VERSIONs doesn't influence which version we build,
    # since we are building the one that Jenkins has cloned, but it does
    # influence which version Yocto and the binaries will show.
    if [ -n "$mender_on_exact_tag" ]; then
        cat >> $BUILDDIR/conf/local.conf <<EOF
PREFERRED_VERSION_pn-mender = "$mender_on_exact_tag"
EOF
    else
        cat >> $BUILDDIR/conf/local.conf <<EOF
PREFERRED_VERSION_pn-mender = "$client_version-git%"
EOF
    fi

    if [ -n "$mender_artifact_on_exact_tag" ]; then
        cat >> $BUILDDIR/conf/local.conf <<EOF
PREFERRED_VERSION_pn-mender-artifact = "$mender_artifact_on_exact_tag"
PREFERRED_VERSION_pn-mender-artifact-native = "$mender_artifact_on_exact_tag"
EOF
    else
        cat >> $BUILDDIR/conf/local.conf <<EOF
PREFERRED_VERSION_pn-mender-artifact = "$mender_artifact_version-git%"
PREFERRED_VERSION_pn-mender-artifact-native = "$mender_artifact_version-git%"
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

# Make sure that a stop_slave does not linger from a previous build.
if [[ $STOP_SLAVE = "true" ]]; then
    touch $HOME/stop_slave
else
    if [[ -f $HOME/stop_slave ]]; then
        rm $HOME/stop_slave
    fi
fi

if [ ! -d mender-qa ]
then
    echo "JENKINS SCRIPT: mender-qa directory is not present"
    exit 1
fi

# ---------------------------------------------------
# Clean up build server.
# ---------------------------------------------------

if [ "$CLEAN_BUILD_CACHE" = "true" ]
then
    sudo rm -rf /mnt/sstate-cache/*
fi

# if we abort a build, docker might still be up and running
docker ps -q -a | xargs -r docker stop || true
docker ps -q -a | xargs -r docker rm -f || true
sudo chmod 777 /var/run/docker.sock

docker system prune -f -a
sudo systemctl restart docker
sudo killall -s9 mender-stress-test-client || true

# ---------------------------------------------------
# Generic setup.
# ---------------------------------------------------

# required to enable multi-tenant tests
cp $WORKSPACE/go/src/github.com/mendersoftware/tenantadm/docker-compose.mt.yml $WORKSPACE/integration/

if is_testing_board vexpress-qemu || is_testing_board vexpress-qemu-flash; then
    build_custom_qemu
fi

# ---------------------------------------------------
# Build server repositories.
# ---------------------------------------------------

# Build Go repositories.
export GOPATH="$WORKSPACE/go"
(
    cd $WORKSPACE/go/src/github.com/mendersoftware/mender-artifact
    make install
)
# Build fake client
(
    cd go/src/github.com/mendersoftware/mender-stress-test-client
    go build
    go install
)

if grep mender_servers <<<"$JOB_BASE_NAME"; then
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
fi

# -----------------------
# Done with server build.
# -----------------------

# Check whether the given board name is a hardware board or not.
# Takes one argument: Board name
is_hardware_board() {
    case "$1" in
        *qemu*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# Prepare the board for testing. Arguments.
# - machine name
# - board name
prepare_board_for_testing() {
    local machine_name="$1"
    local board_name="$2"

    /bin/cp ~/.ssh/id_rsa* "$WORKSPACE"/meta-mender/tests/meta-mender-$machine_name-ci/recipes-mender/mender-qa/files/$board_name
    ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        -t root@${SSH_TUNNEL_IP} \
        -p $(port_for_board $board_name) \
        "mender-qa activate-test-image off" \
        || true
}

# Takes three arguments, the machine name, the board name, and image name.
deploy_image_to_board() {
    local counter=0
    local machine_name="$1"
    local board_name="$2"
    local image_name="$3"
    while [  $counter -lt 5 ]; do
        local scp_exit_code=0
        scp -o UserKnownHostsFile=/dev/null \
            -o StrictHostKeyChecking=no -C \
            -oPort=$(port_for_board $board_name) \
            "$BUILDDIR"/tmp/deploy/images/$machine_name/$image_name-$machine_name.sdimg \
            root@${SSH_TUNNEL_IP}:/tmp/ \
            || scp_exit_code=$?
        if [ "$scp_exit_code" -ne 0 ]; then
            let counter=counter+1
            sleep 30
        else
            ssh -o UserKnownHostsFile=/dev/null \
                -o StrictHostKeyChecking=no \
                -t root@${SSH_TUNNEL_IP} \
                -p $(port_for_board $board_name) \
                "env IMAGE_FILE=$image_name-$machine_name.sdimg mender-qa deploy-test-image" \
                || true
            break
        fi
    done
}

# ------------------------------------------------------------------------------
# Generic function for building and testing client.
#
# Parameters:
#   - machine name
#   - board name (usually the same or similar to machine name, but each machine
#                 name can have several boards)
#   - image name
# ------------------------------------------------------------------------------
build_and_test_client() {
    # This makes the whole function run in a subshell. So no need for path
    # cleanups.
    (
        # Should be changed when the number of parameters below changes.
        if [ -z "$3" -o -n "$4" ]; then
            echo "Incorrect number of parameters passed"
            exit 1
        fi

        local machine_name="$1"
        local board_name="$2"
        local image_name="$3"

        if ! is_building_board $board_name; then
            return
        fi

        github_pull_request_status "pending" "$board_name build started" "$BUILD_URL" "${board_name}_build"
        source oe-init-build-env build-$machine_name
        cd ../

        prepare_build_config $machine_name
        disable_mender_service

        cd $BUILDDIR
        local bitbake_result=0
        bitbake $image_name || bitbake_result=$?

        if [[ $bitbake_result -eq 0 ]]; then
            github_pull_request_status "success" "$board_name build completed" "$BUILD_URL" "${board_name}_build"
        else
            github_pull_request_status "failure" "$board_name build failed" "$BUILD_URL" "${board_name}_build"
            exit $bitbake_result
        fi

        mkdir -p $WORKSPACE/$board_name
        cp -vL $BUILDDIR/tmp/deploy/images/$machine_name/$image_name-$machine_name.* $WORKSPACE/$board_name
        if [ -e $BUILDDIR/tmp/deploy/images/$machine_name/u-boot.elf ]; then
            cp -vL $BUILDDIR/tmp/deploy/images/$machine_name/u-boot.elf $WORKSPACE/$board_name
        fi
        for image in $WORKSPACE/$board_name/*; do
            cp $image $image.clean
        done

        prepare_and_set_PATH

        # run tests on qemu
        if is_testing_board $board_name; then
            export QEMU_SYSTEM_ARM="/usr/bin/qemu-system-arm"

            local html_report_args="--html=report.html --self-contained-html"
            if ! pip list|grep -e pytest-html >/dev/null 2>&1; then
                html_report_args=""
                echo "WARNING: install pytest-html for html results report"
            fi

            github_pull_request_status "pending" "$board_name acceptance tests started in Jenkins" "$BUILD_URL" "${board_name}_acceptance_tests"

            bitbake-layers add-layer "$WORKSPACE"/meta-mender/tests/meta-mender-ci
            if [ -d "$WORKSPACE"/meta-mender/tests/meta-mender-$machine_name-ci ]; then
                bitbake-layers add-layer "$WORKSPACE"/meta-mender/tests/meta-mender-$machine_name-ci
            fi

            # install test dependencies
            sudo pip2 install -r $WORKSPACE/meta-mender/tests/acceptance/requirements.txt

            if is_hardware_board $board_name; then
                prepare_board_for_testing $machine_name $board_name
            fi

            bitbake $image_name

            if is_hardware_board $board_name; then
                deploy_image_to_board $machine_name $board_name $image_name
            fi

            cd $WORKSPACE/meta-mender/tests/acceptance/

            local acceptance_test_to_run=""

            # make it possible to run specific test
            if [ -n "$ACCEPTANCE_TEST" ]; then
                acceptance_test_to_run=" -k $ACCEPTANCE_TEST"
            fi

            local host_args
            if is_hardware_board $board_name; then
                host_args="--host=$SSH_TUNNEL_IP:$(port_for_board $board_name)"
            else
                host_args=
            fi

            # run tests with xdist explicitly disabled
            local qemu_testing_status=0
            py.test -p no:xdist --verbose --junit-xml=results.xml $host_args \
                    --bitbake-image $image_name --board-type=$board_name \
                    $html_report_args $acceptance_test_to_run || qemu_testing_status=$?

            if [ -n "$PR_TO_TEST" ]; then
                local html_report=$(find . -iname report.html  | head -n 1)
                local report_dir=$BUILD_NUMBER
                s3cmd put $html_report s3://mender-acceptance-$board_name/$report_dir/
                local report_url=https://s3-eu-west-1.amazonaws.com/$report_bucket/$report_dir/report.html

                if [ $qemu_testing_status -ne 0 ]; then
                    if is_hardware_board "$board_name"; then
                        board_support_update "$board_name" "failed"
                    fi
                    github_pull_request_status "failure" "$board_name acceptance tests failed" $report_url "${board_name}_acceptance_tests"
                    exit $qemu_testing_status
                else
                    if is_hardware_board "$board_name"; then
                        board_support_update "$board_name" "passed"
                    fi
                    github_pull_request_status "success" "$board_name acceptance tests passed!" $report_url "${board_name}_acceptance_tests"
                fi
            fi

            if [ $qemu_testing_status -ne 0 ]; then
                exit $qemu_testing_status
            fi

            cd $WORKSPACE/
        fi

        # Restore earlier backups of clean images.
        for image in $WORKSPACE/$board_name/*.clean; do
            cp $image $(sed -e 's/\.clean$//' <<<$image)
        done

        if [ "$UPLOAD_OUTPUT" = "true" ]
        then
            # store useful output to directory
            mkdir -p "$board_name-deploy"
            cp -r $BUILDDIR/tmp/deploy/* "$board_name-deploy"
        fi

        if [ "$PUBLISH_ARTIFACTS" = true ]; then
            publish_artifacts $machine_name $board_name $image_name
        fi
    )
}

# Published the artifacts for the board in the argument.
publish_artifacts() {
    # Arguments
    local machine_name="$1"
    local board_name="$2"
    local image_name="$3"

    # This makes the whole function run in a subshell. So no need for path
    # cleanups.
    (
        if [ ! -e "$WORKSPACE/$board_name/$image_name-$machine_name.ext4" ]; then
            # Currently we don't support publishing non-ext4 images.
            return
        fi

        local client_version=$($WORKSPACE/integration/extra/release_tool.py --version-of mender)
        local mender_artifact_version=$($WORKSPACE/integration/extra/release_tool.py --version-of mender-artifact)

        s3cmd --cf-invalidate -F put $WORKSPACE/go/bin/mender-artifact s3://mender/mender-artifact/${mender_artifact_version}/
        s3cmd setacl s3://mender/mender-artifact/${mender_artifact_version}/mender-artifact --acl-public

        cd $WORKSPACE/$board_name/
        s3cmd -F put core-image-full-cmdline-$machine_name.ext4 s3://mender/temp_${client_version}/core-image-full-cmdline-$machine_name.ext4
        s3cmd setacl s3://mender/temp_${client_version}/core-image-full-cmdline-$machine_name.ext4 --acl-public

        modify_ext4 core-image-full-cmdline-$machine_name.ext4 release-1_${client_version}
        mender-artifact write rootfs-image -t $machine_name -n release-1_${client_version} -u core-image-full-cmdline-$machine_name.ext4 -o vexpress_release_1_${client_version}.mender
        modify_ext4 core-image-full-cmdline-$machine_name.ext4 release-2_${client_version}
        mender-artifact write rootfs-image -t $machine_name -n release-2_${client_version} -u core-image-full-cmdline-$machine_name.ext4 -o vexpress_release_2_${client_version}.mender
        if is_hardware_board $board_name; then
            gzip -c core-image-base-$machine_name.sdimg > mender-$machine_name_${client_version}.sdimg.gz
            s3cmd --cf-invalidate -F put mender-$machine_name_${client_version}.sdimg.gz s3://mender/${client_version}/$board_name/
            s3cmd setacl s3://mender/${client_version}/$board_name/mender-$machine_name_${client_version}.sdimg.gz --acl-public
        fi
        s3cmd --cf-invalidate -F put vexpress_release_1_${client_version}.mender s3://mender/${client_version}/$board_name/
        s3cmd --cf-invalidate -F put vexpress_release_2_${client_version}.mender s3://mender/${client_version}/$board_name/
        s3cmd setacl s3://mender/${client_version}/$board_name/vexpress_release_1_${client_version}.mender --acl-public
        s3cmd setacl s3://mender/${client_version}/$board_name/vexpress_release_2_${client_version}.mender --acl-public
    )
}

upload_output() {
    (
        cd $WORKSPACE
        tar acvf output.tar.xz  --ignore-failed-read *-deploy
        s3cmd put output.tar.xz s3://mender/temp/yoctobuilds/$BUILD_TAG/
        s3cmd setacl s3://mender/temp/yoctobuilds/$BUILD_TAG/output.tar.xz --acl-public
        echo "Download build output from: https://s3.amazonaws.com/mender/temp/yoctobuilds/${BUILD_TAG}/output.tar.xz"
    )
}

run_integration_tests() {
    (
        if ! grep mender_servers <<<"$JOB_BASE_NAME"; then
            return
        fi

        if is_building_board vexpress-qemu; then
            cd $WORKSPACE
            source oe-init-build-env build-vexpress-qemu
            prepare_and_set_PATH

            cd $WORKSPACE/meta-mender/meta-mender-qemu
            cp $BUILDDIR/tmp/deploy/images/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.{ext4,sdimg} .
            cp $BUILDDIR/tmp/deploy/images/vexpress-qemu/u-boot.elf .

            docker build -t mendersoftware/mender-client-qemu:pr --build-arg VEXPRESS_IMAGE=core-image-full-cmdline-vexpress-qemu.sdimg --build-arg UBOOT_ELF=u-boot.elf .
            $WORKSPACE/integration/extra/release_tool.py --set-version-of mender --version pr
        fi

        github_pull_request_status "pending" "integration tests have started in Jenkins" "$BUILD_URL" "integration_$INTEGRATION_REV"

        local testing_status=0
        cd $WORKSPACE/integration/tests && ./run.sh || testing_status=$?

        local html_report=$(find . -iname report.html  | head -n 1)
        local report_dir=$BUILD_NUMBER

        s3cmd put $html_report s3://mender-integration-reports/$report_dir/
        local report_url=https://s3-eu-west-1.amazonaws.com/mender-integration-reports/$report_dir/report.html

        if [ $testing_status -ne 0 ]; then
            github_pull_request_status "failure" "integration tests failed" $report_url "integration_$INTEGRATION_REV"
        else
            github_pull_request_status "success" "integration tests passed!" $report_url "integration_$INTEGRATION_REV"
        fi

        # Reset docker tag names to their cloned values after tests are done.
        cd $WORKSPACE/integration
        git checkout -f -- .

        if [ "$testing_status" -ne 0 ]; then
            exit $testing_status
        fi

        if [ "$PUBLISH_ARTIFACTS" = true ]; then
            docker login -u menderbuildsystem -p ${DOCKER_PASSWORD}

            for container in mender-client-qemu api-gateway deployments deviceadm deviceauth gui inventory useradm; do
                local version=$($WORKSPACE/integration/extra/release_tool.py --version-of $container)
                docker tag mendersoftware/$container:pr mendersoftware/$container:${version}
                docker push mendersoftware/$container:${version}
            done
        fi
    )
}

if is_poky_branch morty || is_poky_branch pyro || is_poky_branch rocko; then
    # Rocko and earlier used this name.
    beaglebone_machine_name=beaglebone
else
    beaglebone_machine_name=beaglebone-yocto
fi

build_and_test_client  vexpress-qemu             vexpress-qemu        core-image-full-cmdline
build_and_test_client  vexpress-qemu-flash       vexpress-qemu-flash  core-image-minimal
build_and_test_client  $beaglebone_machine_name  beagleboneblack      core-image-base
build_and_test_client  raspberrypi3              raspberrypi3         core-image-full-cmdline

if [ "$UPLOAD_OUTPUT" = "true" ]; then
    upload_output
fi

if [ "$RUN_INTEGRATION_TESTS" = "true" ]; then
    run_integration_tests
fi
