#!/bin/bash

set -e -x -E

if [ -n "$JENKINS_URL" ]; then
    $WORKSPACE/mender-qa/scripts/wait-until-build-host-ready.sh
fi

echo $WORKSPACE

if [ -n "$CI_JOB_NAME" ]; then
    # Disable updating pull requests status for Gitlab. In Gitlab we do it
    # directly in the .gitlab-ci.yml file instead.
    export DISABLE_GITHUB_PULL_REQUEST_STATUS=true
fi

# Jenkins builds will install docker here. Gitlab runners have it already in the image
if [ -n "$JENKINS_URL" ]; then
    sudo apt-get -qy --force-yes install docker-ce || apt-get -qy --force-yes install docker-ce
    # make sure Docker uses the block storage to store docker containers.
    sudo bash -c 'cat << EOF > /etc/docker/daemon.json
{
"data-root": "/var/lib/docker/",
"storage-driver": "overlay2"
}
EOF'
    sudo service docker restart
fi

SSH_TUNNEL_IP=188.166.29.46
RASPBERRYPI3_PORT=2210
BEAGLEBONEBLACK_PORT=2211

declare -a CONFIG_MACHINE_NAMES
declare -a CONFIG_BOARD_NAMES
declare -a CONFIG_IMAGE_NAMES
declare -a CONFIG_DEVICE_TYPES

export PATH=$PATH:$WORKSPACE/go/bin

declare -A TEST_TRACKER

# patch Fabric
wget https://github.com/fabric/fabric/commit/b60247d78e9a7b541b3ed5de290fdeef2039c6df.patch || true
sudo patch -p1 /usr/local/lib/python2.7/dist-packages/fabric/network.py b60247d78e9a7b541b3ed5de290fdeef2039c6df.patch || true

is_poky_branch() {
    if egrep -q "^ *DISTRO_CODENAME *= *\"$1\" *\$" $WORKSPACE/meta-poky/conf/distro/poky.conf; then
        return 0
    else
        return 1
    fi
}

is_building_dockerized_board() {
    local ret=0
    is_building_board vexpress-qemu \
        || is_building_board qemux86-64-uefi-grub \
        || ret=$?
    return $ret
}

is_building_board() {
    local ret=0
    local uc_board="$(tr [a-z-] [A-Z_] <<<$1)"
    local lc_board="$(tr [A-Z-] [a-z_] <<<$1)"
    eval test "\$BUILD_${uc_board}" = true && egrep "(^|[^_]\b)mender_${lc_board}(\$|\b[^_])" <<<"$JOB_BASE_NAME" || ret=$?
    return $ret
}

is_testing_board() {
    local ret=0
    local uc_board="$(tr [a-z-] [A-Z_] <<<$1)"
    local lc_board="$(tr [A-Z-] [a-z_] <<<$1)"
    eval test "\$TEST_${uc_board}" = true && egrep "(^|[^_]\b)mender_${lc_board}(\$|\b[^_])" <<<"$JOB_BASE_NAME" || ret=$?
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

s3cmd_put() {
    if [ -z "$JENKINS_URL" ]; then return; fi
    local local_path=$1
    local remote_url=$2
    shift 2
    local cmd_options=$@
    s3cmd $cmd_options put $local_path $remote_url
}

s3cmd_put_public() {
    if [ -z "$JENKINS_URL" ]; then return; fi
    s3cmd_put $@
    local remote_url=$2
    s3cmd setacl $remote_url --acl-public
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
    local board
    board=$2

    if [ -d $WORKSPACE/meta-mender/tests/build-conf/${board} ]; then
        copy_build_conf $WORKSPACE/meta-mender/tests/build-conf/${board}/*  $BUILDDIR/conf/
    elif [ -d $WORKSPACE/meta-mender/tests/build-conf/${machine} ]; then
        # Fallback for older branches, should not be necessary on any new
        # branch.
        copy_build_conf $WORKSPACE/meta-mender/tests/build-conf/${machine}/*  $BUILDDIR/conf/
    else
        echo "Could not find build-conf for $board board."
        return 1
    fi

    local client_version=$($WORKSPACE/integration/extra/release_tool.py --version-of mender --in-integration-version HEAD)
    local mender_artifact_version=$($WORKSPACE/integration/extra/release_tool.py --version-of mender-artifact --in-integration-version HEAD)

    cat >> $BUILDDIR/conf/local.conf <<EOF
LICENSE_FLAGS_WHITELIST = "commercial_mender-binary-delta"
FILESEXTRAPATHS_prepend_pn-mender-binary-delta := "${WORKSPACE}/mender-binary-delta:"
EOF

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

    cat >> $BUILDDIR/conf/local.conf <<EOF
MENDER_ARTIFACT_NAME = "mender-image-$client_version"
EOF

    local mender_on_exact_tag=$(test "$MENDER_REV" != "master" && \
        cd $WORKSPACE/go/src/github.com/mendersoftware/mender && \
        git tag --points-at HEAD 2>/dev/null | egrep ^"$MENDER_REV"$ ) || \
        mender_on_exact_tag=
    local mender_artifact_on_exact_tag=$(test "$MENDER_ARTIFACT_REV" != "master" && \
        cd $WORKSPACE/go/src/github.com/mendersoftware/mender-artifact && \
        git tag --points-at HEAD 2>/dev/null | egrep ^"$MENDER_ARTIFACT_REV"$ ) || \
        mender_artifact_on_exact_tag=

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

    if is_poky_branch morty; then
        # Morty needs oe-meta-go
        cat >> $BUILDDIR/conf/bblayers.conf <<EOF
BBLAYERS_append = " $WORKSPACE/oe-meta-go"
EOF
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

# private docker containers, require login:
docker login -u menderbuildsystem -p ${DOCKER_PASSWORD}
docker login -u ntadm_menderci -p ${REGISTRY_MENDER_IO_PASSWORD} registry.mender.io

# if we abort a build, docker might still be up and running
docker ps -q -a | xargs -r docker stop || true
docker ps -q -a | xargs -r docker rm -f || true
docker system prune -f -a
sudo killall -s9 mender-stress-test-client || true

# For Jenkins builds, manipulate also the socket permissions.
if [ -n "$JENKINS_URL" ]; then
    sudo chmod 777 /var/run/docker.sock
    sudo systemctl restart docker
fi

# For some reason Jenkins is not able to do this properly itself after having
# used a submodule.
( cd $WORKSPACE/meta-mender && git clean -dxff )

# ---------------------------------------------------
# Generic setup.
# ---------------------------------------------------

# Handle sub modules. This is a noop for branches that don't have them. It only
# looks complicated because in Jenkins we want to build the repository it
# cloned, not the upstream repository.
cd $WORKSPACE/meta-mender
git submodule deinit -f . || true
rm -rf .git/modules
git submodule init
git config submodule.tests/acceptance/image-tests.url $WORKSPACE/mender-image-tests
# This may fail if a branch is missing from Jenkins' clone. Doesn't matter, we
# will checkout HEAD instead.
git submodule update || git submodule foreach git reset --hard
git submodule foreach "git fetch origin HEAD && git checkout FETCH_HEAD"
cd $WORKSPACE

# ---------------------------------------------------
# Build server repositories.
# ---------------------------------------------------

# Build Go repositories.
export GOPATH="$WORKSPACE/go"
(
    cd $WORKSPACE/go/src/github.com/mendersoftware/mender-artifact
    make install
    if grep -q build-natives-contained Makefile; then
        make build-natives-contained
    fi
)
# Build fake client
(
    cd go/src/github.com/mendersoftware/mender-stress-test-client
    go build
    go install
)

if grep mender_servers <<<"$JOB_BASE_NAME"; then
    # Use release tool to query for available docker names.
    for docker in $($WORKSPACE/integration/extra/release_tool.py --list docker -a ); do (

        git=$($WORKSPACE/integration/extra/release_tool.py --map-name docker $docker git)
        docker_url=$($WORKSPACE/integration/extra/release_tool.py --map-name docker $docker docker_url)

        case "$docker" in
            deployments|deployments-enterprise|deviceauth|inventory|tenantadm|useradm|useradm-enterprise)
                cd go/src/github.com/mendersoftware/$git
                # Versions before 2.0.0 used "go build", later ones
                # build everything inside multi-stage docker builds.
                if ! grep "COPY --from=build" Dockerfile; then
                    CGO_ENABLED=0 go build
                fi
                docker build -t $docker_url:pr .
                $WORKSPACE/integration/extra/release_tool.py --set-version-of $docker --version pr
                ;;

            gui)
                cd gui
                # Versions of gui before 2.0.0 used "gulp build", later ones
                # build everything inside multi-stage docker builds.
                if ! grep "COPY --from=build" Dockerfile; then
                    gulp build
                fi
                docker build -t $docker_url:pr .
                $WORKSPACE/integration/extra/release_tool.py --set-version-of $docker --version pr
                ;;

            mender-client-docker)
                # We build the docker-client here, as well as some support
                # tools, but the Yocto based image is too expensive to build
                # here, since this section is run by pure server builds as
                # well. See the build_and_test_client function for that.
                cd go/src/github.com/mendersoftware/mender

                ./tests/build-docker -t $docker_url:pr
                $WORKSPACE/integration/extra/release_tool.py --set-version-of $docker --version pr

                make prefix=$WORKSPACE/go bindir=/bin install-modules-gen
                ;;

            mender-client-qemu*)
                # Built in build_and_test_client.
                :
                ;;

            api-gateway)
                cd $git
                docker build -t $docker_url:pr .
                $WORKSPACE/integration/extra/release_tool.py --set-version-of $docker --version pr
                ;;

            mender-conductor|mender-conductor-enterprise)
                cd go/src/github.com/mendersoftware/$git
                docker build --build-arg REVISION=pr -t $docker_url:pr ./server
                $WORKSPACE/integration/extra/release_tool.py --set-version-of $docker --version pr
                ;;

            email-sender)
                cd go/src/github.com/mendersoftware/$git
                docker build -t $docker_url:pr ./workers/send_email
                $WORKSPACE/integration/extra/release_tool.py --set-version-of $docker --version pr
                ;;

            org-welcome-email-preparer)
                cd go/src/github.com/mendersoftware/$git
                docker build --build-arg REVISION=pr -t $docker_url:pr ./workers/prepare_org_welcome_email
                $WORKSPACE/integration/extra/release_tool.py --set-version-of $docker --version pr
                ;;

            *)
                echo "Don't know how to build docker image $docker"
                exit 1
                ;;
        esac
    ); done

    # Builds that don't use Docker
    for git in $($WORKSPACE/integration/extra/release_tool.py --list git -a ); do (
        case "$git" in
            mender-cli)
                cd $WORKSPACE/go/src/github.com/mendersoftware/$git
                make install
                ;;
        esac
    ); done
fi

# -----------------------
# Done with server build.
# -----------------------

# -----------------------
# Get mender-binary-delta
# -----------------------

if [ -d $WORKSPACE/meta-mender/meta-mender-commercial ]; then
    RECIPE=$(ls $WORKSPACE/meta-mender/meta-mender-commercial/recipes-mender/mender-binary-delta | sort | head -n1)
    mkdir -p $WORKSPACE/mender-binary-delta
    s3cmd get --recursive s3://$(sed -e 's,delta_,delta/,; s/\.bb$//' <<<$RECIPE)/ $WORKSPACE/mender-binary-delta/
fi

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
        "mender-qa activate-test-image off"
    ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        -t root@${SSH_TUNNEL_IP} \
        -p $(port_for_board $board_name) \
        "reboot" \
        || true
}

# Takes three arguments, the machine name, the board name, and image name.
deploy_image_to_board() {
    local counter=0
    local machine_name="$1"
    local board_name="$2"
    local image_name="$3"
    local device_type="$4"
    while [  $counter -lt 5 ]; do
        local scp_exit_code=0
        scp -o UserKnownHostsFile=/dev/null \
            -o StrictHostKeyChecking=no -C \
            -oPort=$(port_for_board $board_name) \
            "$BUILDDIR"/tmp/deploy/images/$machine_name/$image_name-$device_type.sdimg \
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
                "env IMAGE_FILE=$image_name-$device_type.sdimg mender-qa deploy-test-image"
            ssh -o UserKnownHostsFile=/dev/null \
                -o StrictHostKeyChecking=no \
                -t root@${SSH_TUNNEL_IP} \
                -p $(port_for_board $board_name) \
                "reboot" \
                || true
            break
        fi
    done
}

# ------------------------------------------------------------------------------
# Adds the given build configuration to the list of possibilities. Later, the
# correct one will be chosen with build_and_test().
#
# Parameters:
#   - machine name - Yocto MACHINE name
#   - board name - usually the same or similar to machine name, but each machine
#                  name can have several boards
#   - image name - Yocto image name
#   - device type - Mender device type. In most cases the same as machine name,
#                   but some machines and boards may have more than one device
#                   type, for example with different boot loaders
# The last three parameters can be omitted, which indicates a server-only build,
# using the given machine name.
# The last one argument may also be omitted, in which case it device type is set
# to machine name.
# ------------------------------------------------------------------------------
add_to_build_list() {
    CONFIG_MACHINE_NAMES[${#CONFIG_MACHINE_NAMES[@]}]="$1"
    CONFIG_BOARD_NAMES[${#CONFIG_BOARD_NAMES[@]}]="$2"
    CONFIG_IMAGE_NAMES[${#CONFIG_IMAGE_NAMES[@]}]="$3"
    if [ -n "$4" ]; then
        CONFIG_DEVICE_TYPES[${#CONFIG_DEVICE_TYPES[@]}]="$4"
    else
        CONFIG_DEVICE_TYPES[${#CONFIG_DEVICE_TYPES[@]}]="$1"
    fi
}

# Selects a configuration from the list to build. Client builds override
# server-only builds, but the function otherwise tries to detect whether two
# configurations conflict.
INTEGRATION_TEST_SUITE=$($WORKSPACE/integration/extra/release_tool.py --select-test-suite || echo "all")

build_and_test() {
    local machine_to_build=
    local board_to_build=
    local image_to_build=

    for config in ${!CONFIG_MACHINE_NAMES[@]}; do
        local machine=${CONFIG_MACHINE_NAMES[$config]}
        local board=${CONFIG_BOARD_NAMES[$config]}
        local image=${CONFIG_IMAGE_NAMES[$config]}
        local device_type=${CONFIG_DEVICE_TYPES[$config]}
        if [ -n "$board" ]; then
            # Configuration with client.
            if is_building_board $board; then
                if [ -n "$board_to_build" ]; then
                    echo "Configurations ($machine_to_build, $board_to_build, $image_to_build) and ($machine, $board, $image) both scheduled to build! This is an error!"
                    exit 1
                fi
                machine_to_build=$machine
                board_to_build=$board
                image_to_build=$image
                device_type_to_build=$device_type
            fi
        else
            if [ -n "$board_to_build" ]; then
                # Some client build is selected. Skip server-only build.
                continue
            fi
            # Configuration with just servers.
            if [ -n "$machine_to_build" ]; then
                echo "Configurations ($machine_to_build, $board_to_build, $image_to_build) and ($machine, $board, $image) both scheduled to build! This is an error!"
                exit 1
            fi
            machine_to_build=$machine
            board_to_build=$board
            image_to_build=$image
            device_type_to_build=$device_type
        fi
    done

    if [ -z "$machine_to_build" ]; then
        echo "No build configuration selected!"
        exit 1
    fi

    if [ -n "$board_to_build" ]; then
        build_and_test_client $machine_to_build $board_to_build $image_to_build $device_type_to_build

    fi

    if [ "$machine_to_build" = "mender_servers" ]; then
        run_backend_integration_tests && \
        run_integration_tests
    else
        run_integration_tests $machine_to_build $board_to_build
    fi
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
        if [ -z "$4" -o -n "$5" ]; then
            echo "Incorrect number of parameters passed"
            exit 1
        fi

        local machine_name="$1"
        local board_name="$2"
        local image_name="$3"
        local device_type="$4"

        if ! is_building_board $board_name; then
            echo "Not building board? We should never get here."
            exit 1
        fi

        "$(dirname "$0")"/github_pull_request_status "pending" "$board_name integration:${INTEGRATION_REV} poky:${POKY_REV} build started" "$BUILD_URL" "${board_name}_${INTEGRATION_REV}_${POKY_REV}_build"
        source oe-init-build-env build-$board_name
        cd ../

        prepare_build_config $machine_name $board_name
        disable_mender_service

        cd $BUILDDIR
        local bitbake_result=0
        bitbake $image_name || bitbake_result=$?

        # Check if there is a R/O rootfs recipe available.
        if [[ $bitbake_result -eq 0 ]] \
               && [[ $image_name == core-image-full-cmdline ]] \
               && [[ -f $WORKSPACE/meta-mender/meta-mender-demo/recipes-extended/images/mender-image-full-cmdline-rofs.bb ]]; then

            bitbake mender-image-full-cmdline-rofs || bitbake_result=$?
        fi

        if [[ $bitbake_result -eq 0 ]]; then
            "$(dirname "$0")"/github_pull_request_status "success" "$board_name integration:${INTEGRATION_REV} poky:${POKY_REV} build completed" "$BUILD_URL" "${board_name}_${INTEGRATION_REV}_${POKY_REV}_build"
        else
            "$(dirname "$0")"/github_pull_request_status "failure" "$board_name integration:${INTEGRATION_REV} poky:${POKY_REV} build failed" "$BUILD_URL" "${board_name}_${INTEGRATION_REV}_${POKY_REV}_build"
            exit $bitbake_result
        fi

        mkdir -p $WORKSPACE/$board_name
        cp -vL $BUILDDIR/tmp/deploy/images/$machine_name/$image_name-$device_type.* $WORKSPACE/$board_name
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

            "$(dirname "$0")"/github_pull_request_status "pending" "$board_name integration:${INTEGRATION_REV} poky:${POKY_REV} acceptance tests started in Jenkins" "$BUILD_URL" "${board_name}_${INTEGRATION_REV}_${POKY_REV}_acceptance_tests"

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
                deploy_image_to_board $machine_name $board_name $image_name $device_type
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

            local pytest_args=
            if ! ( is_poky_branch morty || is_poky_branch pyro || is_poky_branch rocko || is_poky_branch sumo ); then
                pytest_args="--no-pull"
            fi
            if ! ( is_poky_branch morty || is_poky_branch pyro ); then
                pytest_args="$pytest_args --commercial-tests"
            fi

            # run tests with xdist explicitly disabled
            local qemu_testing_status=0
            py.test -p no:xdist --verbose --junit-xml=results.xml $host_args \
                    --bitbake-image $image_name --board-type=$board_name $pytest_args \
                    $html_report_args $acceptance_test_to_run || qemu_testing_status=$?

            local html_report=$(find . -iname report.html  | head -n 1)
            local report_dir=$BUILD_NUMBER
            s3cmd_put \
                $html_report \
                s3://mender-testing-reports/acceptance-$board_name/$report_dir/
            local report_url=https://s3-eu-west-1.amazonaws.com/mender-testing-reports/acceptance-$board_name/$report_dir/report.html

            if [ $qemu_testing_status -ne 0 ]; then
                if is_hardware_board "$board_name"; then
                    board_support_update "$board_name" "failed"
                fi
                "$(dirname "$0")"/github_pull_request_status "failure" "$board_name integration:${INTEGRATION_REV} poky:${POKY_REV} acceptance tests failed" $report_url "${board_name}_${INTEGRATION_REV}_${POKY_REV}_acceptance_tests"
                exit $qemu_testing_status
            else
                if is_hardware_board "$board_name"; then
                    board_support_update "$board_name" "passed"
                fi
                "$(dirname "$0")"/github_pull_request_status "success" "$board_name integration:${INTEGRATION_REV} poky:${POKY_REV} acceptance tests passed!" $report_url "${board_name}_${INTEGRATION_REV}_${POKY_REV}_acceptance_tests"
            fi

            if [ $qemu_testing_status -ne 0 ]; then
                exit $qemu_testing_status
            fi

            cd $WORKSPACE/
        fi

        # Restore earlier backups of clean images.
        for clean_image in $WORKSPACE/$board_name/*.clean; do
            image=$(sed -e 's/\.clean$//' <<<$clean_image)
            cp $clean_image $image
            # Restore Yocto BUILDDIR images as well, since the integration tests
            # make references to it.
            cp $clean_image $BUILDDIR/tmp/deploy/images/$machine_name/$(basename $image)
        done

        if [ "$UPLOAD_OUTPUT" = "true" ]
        then
            # store useful output to directory
            cd $WORKSPACE
            mkdir -p "$board_name-deploy"
            cp -r $BUILDDIR/tmp/deploy/* "$board_name-deploy"
            upload_output
        fi

        if [ "$PUBLISH_ARTIFACTS" = true ]; then
            publish_artifacts $machine_name $board_name $image_name $device_type
        fi

        if is_building_dockerized_board; then
            cd $WORKSPACE/meta-mender/meta-mender-qemu
            if [ -x docker/build-docker ]; then
                # New style.
                cd docker
                ./build-docker $machine_name -t mendersoftware/mender-client-qemu:pr

                # Check if there is a R/O rootfs recipe available.
                if [[ -f $WORKSPACE/meta-mender/meta-mender-demo/recipes-extended/images/mender-image-full-cmdline-rofs.bb ]]; then
                    ./build-docker -i mender-image-full-cmdline-rofs $machine_name -t mendersoftware/mender-client-qemu-rofs:pr
                    # It's ok if the next step fails, it just means we are
                    # testing a version of integration that neither has a rofs
                    # image, nor any tests for it.
                    $WORKSPACE/integration/extra/release_tool.py --set-version-of mender-client-qemu-rofs --version pr || true
                fi

            elif is_building_board vexpress-qemu; then
                # Old style.
                cp $BUILDDIR/tmp/deploy/images/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.{ext4,sdimg} .
                cp $BUILDDIR/tmp/deploy/images/vexpress-qemu/u-boot.elf .

                docker build -t mendersoftware/mender-client-qemu:pr --build-arg VEXPRESS_IMAGE=core-image-full-cmdline-vexpress-qemu.sdimg --build-arg UBOOT_ELF=u-boot.elf .
            fi

            $WORKSPACE/integration/extra/release_tool.py --set-version-of mender-client-qemu --version pr
        fi
    )
}

# Published the artifacts for the board in the argument.
publish_artifacts() {
    # Arguments
    local machine_name="$1"
    local board_name="$2"
    local image_name="$3"
    local device_type="$4"

    # This makes the whole function run in a subshell. So no need for path
    # cleanups.
    (
        if [ ! -e "$WORKSPACE/$board_name/$image_name-$device_type.ext4" ]; then
            # Currently we don't support publishing non-ext4 images.
            return
        fi

        local client_version=$($WORKSPACE/integration/extra/release_tool.py --version-of mender --in-integration-version HEAD)
        local mender_artifact_version=$($WORKSPACE/integration/extra/release_tool.py --version-of mender-artifact --in-integration-version HEAD)

        if grep -q build-natives-contained $WORKSPACE/go/src/github.com/mendersoftware/mender-artifact/Makefile; then
            # New style platform-indexed mender-artifact upload.
            for bin in mender-artifact-darwin mender-artifact-linux mender-artifact-windows.exe; do
                platform=${bin#mender-artifact-}
                platform=${platform%.*}
                s3cmd_put_public \
                    $WORKSPACE/go/src/github.com/mendersoftware/mender-artifact/${bin} \
                    s3://mender/mender-artifact/${mender_artifact_version}/${platform}/mender-artifact \
                    --cf-invalidate -F
            done
        else
            # Old style Linux-only mender-artifact upload.
            s3cmd_put_public \
                $WORKSPACE/go/bin/mender-artifact \
                s3://mender/mender-artifact/${mender_artifact_version}/mender-artifact \
                --cf-invalidate -F
        fi

        cd $WORKSPACE/$board_name/
        s3cmd_put_public \
            $image_name-$device_type.ext4 \
            s3://mender/temp_${client_version}/$image_name-$device_type.ext4 \
            -F

        # Artifact may have more than one device type defined (beaglebone-yocto
        # and beaglebone, for example), and the only way we can find out is to
        # inspect the artifact that Yocto built, since the job info itself does
        # not provide this info.
        device_types="$(mender-artifact read $image_name-$device_type.mender | sed -rne "/^ *Compatible devices:/ {
            s/^[^[]*\\[//;
            s/][^]]*$//;
            s/ +/ -t /g;
            s/^/-t /;
            p;
        }")"

        if mender-artifact write rootfs-image --help | grep -e '-u FILE'; then
            # Pre-3.0.0
            file_flag=-u
        else
            # Post-3.0.0
            file_flag=-f
        fi

        modify_ext4 $image_name-$device_type.ext4 release-1_${client_version}
        mender-artifact write rootfs-image $device_types -n release-1_${client_version} $file_flag $image_name-$device_type.ext4 -o ${board_name}_release_1_${client_version}.mender
        modify_ext4 $image_name-$device_type.ext4 release-2_${client_version}
        mender-artifact write rootfs-image $device_types -n release-2_${client_version} $file_flag $image_name-$device_type.ext4 -o ${board_name}_release_2_${client_version}.mender
        if is_hardware_board $board_name; then
            gzip -c $image_name-$device_type.sdimg > mender-${board_name}_${client_version}.sdimg.gz
            s3cmd_put_public \
                mender-${board_name}_${client_version}.sdimg.gz \
                s3://mender/${client_version}/$board_name/mender-${board_name}_${client_version}.sdimg.gz \
                --cf-invalidate -F
        fi
        s3cmd_put_public \
            ${board_name}_release_1_${client_version}.mender \
            s3://mender/${client_version}/$board_name/${board_name}_release_1_${client_version}.mender \
            --cf-invalidate -F
        s3cmd_put_public \
            ${board_name}_release_2_${client_version}.mender \
            s3://mender/${client_version}/$board_name/${board_name}_release_2_${client_version}.mender \
            --cf-invalidate -F
    )
}

upload_output() {
    (
        cd $WORKSPACE
        tar acvf output.tar.xz  --ignore-failed-read *-deploy
        s3cmd_put_public \
            output.tar.xz \
            s3://mender/temp/yoctobuilds/$BUILD_TAG/output.tar.xz
        echo "Download build output from: https://s3.amazonaws.com/mender/temp/yoctobuilds/${BUILD_TAG}/output.tar.xz"
    )
}

# ------------------------------------------------------------------------------
# Function for running integration tests.
#
# Parameters:
#   - machine name
#   - board name (usually the same or similar to machine name, but each machine
#                 name can have several boards)
# ------------------------------------------------------------------------------
run_integration_tests() {

    # Install Python dependency pymongo.
    # This is a Jenkins specific hack to not mofidy jenkins-yoctobuild-init-script.sh and rebuild the image
    sudo pip2 install pymongo==3.6.1

    (
        local machine_name="$1"
        local board_name="$2"

        if [ "$RUN_INTEGRATION_TESTS" != "true" ] || ! grep mender_servers <<<"$JOB_BASE_NAME"; then
            return
        fi

        local extra_job_string=
        local extra_job_info="tests"
        if [ -n "$SPECIFIC_INTEGRATION_TEST" ]; then
            extra_job_string="_$SPECIFIC_INTEGRATION_TEST"
            extra_job_info="specific test:$SPECIFIC_INTEGRATION_TEST"
        else
            # only do automatic test suite selection if the user wasn't specific
            # run.sh will pick up the SPECIFIC_INTEGRATION_TEST var
            case $INTEGRATION_TEST_SUITE in
                "enterprise")
                    export SPECIFIC_INTEGRATION_TEST="Enterprise"
                    ;;
                "open")
                    export SPECIFIC_INTEGRATION_TEST="not Enterprise"
                    ;;
            esac
        fi

        "$(dirname "$0")"/github_pull_request_status \
            "pending" \
            "${board_name:+${board_name} }integration:${INTEGRATION_REV} $extra_job_info have started in Jenkins" \
            "$BUILD_URL" \
            "${board_name:+${board_name}_}integration_${INTEGRATION_REV}$extra_job_string"

        if is_building_dockerized_board; then
            cd $WORKSPACE
            source oe-init-build-env build-$board_name
        fi

        local testing_status=0
        cd $WORKSPACE/integration/tests && ./run.sh ${machine_name:+--machine-name=$machine_name} || testing_status=$?

        local html_report=$(find . -iname report.html  | head -n 1)
        local report_dir=$BUILD_NUMBER

        s3cmd_put \
            $html_report \
            s3://mender-testing-reports/integration-reports${board_name:+-${board_name}}/$report_dir/
        local report_url=https://s3-eu-west-1.amazonaws.com/mender-testing-reports/integration-reports${board_name:+-${board_name}}/$report_dir/report.html

        if [ $testing_status -ne 0 ]; then
            "$(dirname "$0")"/github_pull_request_status \
                "failure" \
                "${board_name:+${board_name} }integration:${INTEGRATION_REV} $extra_job_info failed" \
                $report_url \
                "${board_name:+${board_name}_}integration_${INTEGRATION_REV}$extra_job_string"
        else
            "$(dirname "$0")"/github_pull_request_status \
                "success" \
                "${board_name:+${board_name} }integration:${INTEGRATION_REV} $extra_job_info passed!" \
                $report_url \
                "${board_name:+${board_name}_}integration_${INTEGRATION_REV}$extra_job_string"
        fi

        if [ "$testing_status" -ne 0 ]; then
            exit $testing_status
        fi
    )
}

# ------------------------------------------------------------------------------
# Function for running backend specific integration tests.
# ------------------------------------------------------------------------------
run_backend_integration_tests() {
    (
        if [ "$RUN_INTEGRATION_TESTS" != "true" ] || ! grep mender_servers <<<"$JOB_BASE_NAME"; then
            return
        fi

        "$(dirname "$0")"/github_pull_request_status \
            "pending" \
            "integration:${INTEGRATION_REV} have started in Jenkins" \
            "$BUILD_URL" \
            "backend_integration_${INTEGRATION_REV}"

        local testing_status=0


        if [ -f $WORKSPACE/integration/docker-compose.enterprise.yml ]; then
            cd $WORKSPACE/integration/backend-tests && \

                case $INTEGRATION_TEST_SUITE in
                    "enterprise")
                        PYTEST_ARGS="-k Enterprise" ./run -f=../docker-compose.enterprise.yml -f=../docker-compose.storage.minio.yml || \
                        testing_status=$?
                        ;;
                    "open")
                        PYTEST_ARGS="-k 'not Enterprise and not Multitenant'" ./run || \
                        testing_status=$?
                        ;;
                    *)
                        PYTEST_ARGS="-k 'not Enterprise and not Multitenant'" ./run && \
                        PYTEST_ARGS="-k Enterprise" ./run -f=../docker-compose.enterprise.yml -f=../docker-compose.storage.minio.yml || \
                        testing_status=$?
                        ;;
                esac
        else
            # for older releases, ignore test suite selection and just run open tests
            cd $WORKSPACE/integration/backend-tests && \
                PYTEST_ARGS="-k 'not Multitenant'" ./run || \
                testing_status=$?

        fi

        if [ $testing_status -ne 0 ]; then
            "$(dirname "$0")"/github_pull_request_status \
                "failure" \
                "integration:${INTEGRATION_REV}" \
                "$BUILD_URL" \
                "backend_integration_${INTEGRATION_REV}"
        else
            "$(dirname "$0")"/github_pull_request_status \
                "success" \
                "integration:${INTEGRATION_REV}" \
                "$BUILD_URL" \
                "backend_integration_${INTEGRATION_REV}"
        fi

        docker ps -q | xargs -r docker rm -v -f

        if [ "$testing_status" -ne 0 ]; then
            exit $testing_status
        fi
    )
}

# Arguments:
# add_to_build_list        MACHINE_NAME              BOARD_NAME                     IMAGE_NAME               [DEVICE_TYPE]
#
# If DEVICE_TYPE is not given, MACHINE_NAME is assumed.
add_to_build_list          qemux86-64                qemux86-64-uefi-grub           core-image-full-cmdline
add_to_build_list          vexpress-qemu             vexpress-qemu                  core-image-full-cmdline
add_to_build_list          vexpress-qemu-flash       vexpress-qemu-flash            core-image-minimal
add_to_build_list          raspberrypi3              raspberrypi3                   core-image-full-cmdline
# Server build, without client build.
add_to_build_list          mender_servers

if is_poky_branch morty || is_poky_branch pyro || is_poky_branch rocko; then
    # Rocko and earlier used "beaglebone" MACHINE name.
    add_to_build_list      beaglebone                beagleboneblack                core-image-base
else
    if is_poky_branch sumo; then
        add_to_build_list  beaglebone-yocto          beagleboneblack                core-image-base
    else
        # In post-sumo we started compiling for Beaglebone using GRUB instead.
        add_to_build_list  beaglebone-yocto          beagleboneblack                core-image-base          beaglebone-yocto-grub

        add_to_build_list  qemux86-64                qemux86-64-bios-grub-gpt       core-image-full-cmdline  qemux86-64-bios-grub-gpt
    fi

    add_to_build_list      qemux86-64                qemux86-64-bios-grub           core-image-full-cmdline  qemux86-64-bios
    add_to_build_list      vexpress-qemu             vexpress-qemu-uboot-uefi-grub  core-image-full-cmdline  vexpress-qemu-grub
fi

build_and_test

# Reset docker tag names to their cloned values after tests are done.
cd $WORKSPACE/integration
git checkout -f -- .

if [ "$PUBLISH_ARTIFACTS" = true ]; then
    if grep mender_servers <<<"$JOB_BASE_NAME"; then
        # Use release tool to query for available docker images.
        for image in $($WORKSPACE/integration/extra/release_tool.py --list docker ); do (
            version=$($WORKSPACE/integration/extra/release_tool.py --version-of $image --in-integration-version HEAD)
            docker_url=$($WORKSPACE/integration/extra/release_tool.py --map-name docker $image docker_url)
            # Upload containers.
            case "$image" in
                api-gateway|deployments|deployments-enterprise|deviceauth|email-sender|gui|inventory|mender-client-docker|mender-conductor|mender-conductor-enterprise|org-welcome-email-preparer|tenantadm|useradm|useradm-enterprise)
                    docker tag $docker_url:pr $docker_url:${version}
                    docker push $docker_url:${version}
                    ;;
                mender-client-qemu|mender-client-qemu-rofs)
                    # Handled below.
                    :
                    ;;
                *)
                    echo "Don't know how to upload containers for $image!"
                    exit 1
                    ;;
            esac
        ); done
        # Listing all git components.
        for image in $($WORKSPACE/integration/extra/release_tool.py --list git ); do (
            version=$($WORKSPACE/integration/extra/release_tool.py --version-of $image --in-integration-version HEAD)
            # Upload binaries.
            case "$image" in
                deployments|deployments-enterprise|deviceauth|gui|integration|inventory|mender-api-gateway-docker|mender-conductor|mender-conductor-enterprise|tenantadm|useradm|useradm-enterprise)
                    # No binaries.
                    :
                    ;;
                mender-cli)
                    s3cmd_put_public \
                        $WORKSPACE/go/bin/$image \
                        s3://mender/$image/$version/$image \
                        --cf-invalidate -F
                    ;;
                mender-artifact|mender)
                    # Handled in publish_artifacts().
                    :
                    ;;
                *)
                    echo "Don't know how to upload binaries for $image!"
                    exit 1
                    ;;
            esac
        ); done
    fi

    if is_poky_branch morty || is_poky_branch pyro; then
        board_to_publish=vexpress-qemu
    else
        board_to_publish=qemux86-64-uefi-grub
    fi
    if is_building_board $board_to_publish; then
        for container in mender-client-qemu mender-client-qemu-rofs; do
            if ! docker inspect mendersoftware/$container:pr >/dev/null; then
                continue
            fi

            version=$($WORKSPACE/integration/extra/release_tool.py --version-of $container --in-integration-version HEAD)
            docker tag mendersoftware/$container:pr mendersoftware/$container:${version}
            docker push mendersoftware/$container:${version}
        done
    fi
fi
