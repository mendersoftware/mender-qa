#!/bin/bash

set -e -x -E


echo $WORKSPACE

declare -a CONFIG_MACHINE_NAMES
declare -a CONFIG_BOARD_NAMES
declare -a CONFIG_IMAGE_NAMES
declare -a CONFIG_DEVICE_TYPES

export PATH=$PATH:$WORKSPACE/go/bin

declare -A TEST_TRACKER

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

modify_artifact() {
    local old_artifact=$1
    local new_fs_image=$2
    local new_artifact_name=$3
    local new_artifact_file=$4

    # Artifact may have more than one device type defined (beaglebone-yocto
    # and beaglebone, for example), and the only way we can find out is to
    # inspect the artifact that Yocto built, since the job info itself does
    # not provide this info.
    device_types="$(mender-artifact read $old_artifact | sed -rne "/^ *Compatible devices:/ {
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

    mender-artifact write rootfs-image $device_types -n $new_artifact_name $file_flag $new_fs_image -o $new_artifact_file
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


    local mender_binary_delta_version=$($WORKSPACE/mender-binary-delta/x86_64/mender-binary-delta --version | egrep -o '[0-9]+\.[0-9]+\.[0-9b]+(-build[0-9]+)?')
    cat >> $BUILDDIR/conf/local.conf <<EOF
LICENSE_FLAGS_WHITELIST = "commercial_mender-binary-delta"
FILESEXTRAPATHS_prepend_pn-mender-binary-delta := "${WORKSPACE}/mender-binary-delta:"
PREFERRED_VERSION_pn-mender-binary-delta = "$mender_binary_delta_version"
EOF

    # Assuming sumo or newer
    cat >> $BUILDDIR/conf/local.conf <<EOF
# MEN-2948: Renamed mender recipe -> mender-client
# But the "mender" reference has to be kept for backwards compatibility
# with 2.1.x, 2.2.x, and 2.3.x
EXTERNALSRC_pn-mender = "$WORKSPACE/go"
EXTERNALSRC_pn-mender-client = "$WORKSPACE/go"
EXTERNALSRC_pn-mender-artifact = "$WORKSPACE/go"
EXTERNALSRC_pn-mender-artifact-native = "$WORKSPACE/go"
EOF

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
# MEN-2948: Renamed mender recipe -> mender-client
# But the "mender" reference has to be kept for backwards compatibility
# with 2.1.x, 2.2.x, and 2.3.x
PREFERRED_VERSION_pn-mender = "$mender_on_exact_tag"
PREFERRED_VERSION_pn-mender-client = "$mender_on_exact_tag"
EOF
    else
        cat >> $BUILDDIR/conf/local.conf <<EOF
# MEN-2948: Renamed mender recipe -> mender-client
# But the "mender" reference has to be kept for backwards compatibility
# with 2.1.x, 2.2.x, and 2.3.x
PREFERRED_VERSION_pn-mender = "$client_version-git%"
PREFERRED_VERSION_pn-mender-client= "$client_version-git%"
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

# ---------------------------------------------------
# Preliminary checks.
# ---------------------------------------------------

# Verify that version references are up to date.
$WORKSPACE/integration/extra/release_tool.py --verify-integration-references

# Verify mender-qa directory exists
if [ ! -d mender-qa ]
then
    echo "mender-qa directory is not present"
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
docker login -u menderbuildsystem -p ${DOCKER_HUB_PASSWORD}
docker login -u ntadm_menderci -p ${REGISTRY_MENDER_IO_PASSWORD} registry.mender.io

# if we abort a build, docker might still be up and running
docker ps -q -a | xargs -r docker stop || true
docker ps -q -a | xargs -r docker rm -f || true
docker system prune -f -a
sudo killall -s9 mender-stress-test-client || true

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

if grep mender_servers <<<"$JOB_BASE_NAME"; then
    # Use release tool to query for available docker names.
    for docker in $($WORKSPACE/integration/extra/release_tool.py --list docker ); do (

        git=$($WORKSPACE/integration/extra/release_tool.py --map-name docker $docker git)
        docker_url=$($WORKSPACE/integration/extra/release_tool.py --map-name docker $docker docker_url)

        case "$docker" in
            deployments|deployments-enterprise|deviceauth|inventory|inventory-enterprise|tenantadm|useradm|useradm-enterprise|workflows|workflows-enterprise|workflows-worker|workflows-enterprise-worker|create-artifact-worker)
                cd go/src/github.com/mendersoftware/$git
                # Versions before 2.0.0 used "go build", later ones
                # build everything inside multi-stage docker builds.
                if ! grep "COPY --from=build" Dockerfile; then
                    CGO_ENABLED=0 go build
                fi
                # workflows repoitory builds two different Docker images:
                # - workflows, from Dockerfile
                # - workflows-worker, from Dockerfile.worker
                if [ "$docker" = "workflows-worker" ] || [ "$docker" = "workflows-enterprise-worker" ]; then
                    docker build -t $docker_url:pr -f Dockerfile.worker .
                else
                    docker build -t $docker_url:pr .
                fi
                $WORKSPACE/integration/extra/release_tool.py --set-version-of $docker --version pr
                ;;

            gui)
                cd gui
                # Versions of gui before 2.0.0 used "gulp build", later ones
                # build everything inside multi-stage docker builds.
                if ! grep "COPY --from=build" Dockerfile; then
                    gulp build
                fi
                docker build \
                    -t $docker_url:pr \
                    --build-arg GIT_REF=$(git describe) \
                    --build-arg GIT_COMMIT=$(git rev-parse --short HEAD) \
                    .
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
    for git in $($WORKSPACE/integration/extra/release_tool.py --list git ); do (
        case "$git" in
            mender-cli)
                cd $WORKSPACE/go/src/github.com/mendersoftware/$git
                make install
                if grep -q build-multiplatform Makefile; then
                    make build-multiplatform
                fi
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
    RECIPE=$(ls $WORKSPACE/meta-mender/meta-mender-commercial/recipes-mender/mender-binary-delta/*.bb | sort | tail -n1)
    mkdir -p $WORKSPACE/mender-binary-delta
    s3cmd get --recursive s3://$(sed -e 's,.*/,,; s,delta_,delta/,; s/\.bb$//' <<<$RECIPE)/ $WORKSPACE/mender-binary-delta/
    chmod ugo+x $WORKSPACE/mender-binary-delta/x86_64/mender-binary-delta
    chmod ugo+x $WORKSPACE/mender-binary-delta/x86_64/mender-binary-delta-generator
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

        source oe-init-build-env build-$board_name
        cd ../

        prepare_build_config $machine_name $board_name
        disable_mender_service

        cd $BUILDDIR
        bitbake $image_name

        # Check if there is a R/O rootfs recipe available.
        if [[ $image_name == core-image-full-cmdline ]] \
               && [[ -f $WORKSPACE/meta-mender/meta-mender-demo/recipes-extended/images/mender-image-full-cmdline-rofs.bb ]]; then

            bitbake mender-image-full-cmdline-rofs
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
            local python3_supported=false
            local pip_cmd=pip2
            if [ -f $WORKSPACE/meta-mender/tests/acceptance/requirements_py3.txt ]; then
                python3_supported=true
                pip_cmd=pip3
            fi


            bitbake-layers add-layer "$WORKSPACE"/meta-mender/tests/meta-mender-ci
            if [ -d "$WORKSPACE"/meta-mender/tests/meta-mender-$machine_name-ci ]; then
                bitbake-layers add-layer "$WORKSPACE"/meta-mender/tests/meta-mender-$machine_name-ci
            fi

            # install test dependencies
            if $python3_supported; then
                sudo $pip_cmd install -r $WORKSPACE/meta-mender/tests/acceptance/requirements_py3.txt
            else
                sudo $pip_cmd install -r $WORKSPACE/meta-mender/tests/acceptance/requirements.txt
            fi

            # patch Fabric (Python2 only)
            if ! $python3_supported; then
                wget https://github.com/fabric/fabric/commit/b60247d78e9a7b541b3ed5de290fdeef2039c6df.patch || true
                sudo patch -p1 /usr/local/lib/python2.7/dist-packages/fabric/network.py b60247d78e9a7b541b3ed5de290fdeef2039c6df.patch || true
            fi

            bitbake $image_name

            cd $WORKSPACE/meta-mender/tests/acceptance/

            # check if can generate HTML report
            local html_report_args="--html=report.html --self-contained-html"
            if ! $pip_cmd list|grep -e pytest-html >/dev/null 2>&1; then
                html_report_args=""
                echo "WARNING: install pytest-html for html results report"
            fi

            # make it possible to run specific test
            local acceptance_test_to_run=""
            if [ -n "$ACCEPTANCE_TEST" ]; then
                acceptance_test_to_run=" -k $ACCEPTANCE_TEST"
            fi

            local pytest_args=
            # Assuming thud or newer
            pytest_args="--no-pull"
            # Assuming rocko or newer
            pytest_args="$pytest_args --commercial-tests"

            # run tests with xdist explicitly disabled
            if $python3_supported; then
                python3 -m pytest -p no:xdist --verbose --junit-xml=results.xml \
                        --bitbake-image $image_name --board-type=$board_name $pytest_args \
                        $html_report_args $acceptance_test_to_run
            else
                py.test -p no:xdist --verbose --junit-xml=results.xml \
                    --bitbake-image $image_name --board-type=$board_name $pytest_args \
                    $html_report_args $acceptance_test_to_run
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

        # Currently we don't support publishing non-ext4 images.
        if [ -e "$WORKSPACE/$board_name/$image_name-$device_type.ext4" ]; then

            # Prepare deliveries: modified fs, release_1 artifact, and compressed sdimg for hw boards
            local client_version=$($WORKSPACE/integration/extra/release_tool.py --version-of mender --in-integration-version HEAD)
            cp $WORKSPACE/$board_name/$image_name-$device_type.ext4 $WORKSPACE/$board_name/$image_name-$device_type-release_1.ext4
            modify_ext4 $WORKSPACE/$board_name/$image_name-$device_type-release_1.ext4 release-1_${client_version}
            modify_artifact $WORKSPACE/$board_name/$image_name-$device_type.mender $WORKSPACE/$board_name/$image_name-$device_type.ext4 release-1_${client_version} $WORKSPACE/$board_name/${board_name}_release_1_${client_version}.mender
            if is_hardware_board $board_name; then
                gzip -c $WORKSPACE/$board_name/$image_name-$device_type.sdimg > $WORKSPACE/$board_name/mender-${board_name}_${client_version}.sdimg.gz
            fi
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

# Arguments:
# add_to_build_list        MACHINE_NAME              BOARD_NAME                     IMAGE_NAME               [DEVICE_TYPE]
#
# If DEVICE_TYPE is not given, MACHINE_NAME is assumed.
add_to_build_list          qemux86-64                qemux86-64-uefi-grub           core-image-full-cmdline
add_to_build_list          vexpress-qemu             vexpress-qemu                  core-image-full-cmdline
add_to_build_list          vexpress-qemu-flash       vexpress-qemu-flash            core-image-minimal
add_to_build_list          raspberrypi3              raspberrypi3                   core-image-full-cmdline
add_to_build_list          raspberrypi4              raspberrypi4                   core-image-full-cmdline
# Server build, without client build.
add_to_build_list          mender_servers
# Assuming thud or newer
add_to_build_list          beaglebone-yocto          beagleboneblack                core-image-base          beaglebone-yocto-grub
add_to_build_list          qemux86-64                qemux86-64-bios-grub-gpt       core-image-full-cmdline  qemux86-64-bios-grub-gpt
add_to_build_list          qemux86-64                qemux86-64-bios-grub           core-image-full-cmdline  qemux86-64-bios
add_to_build_list          vexpress-qemu             vexpress-qemu-uboot-uefi-grub  core-image-full-cmdline  vexpress-qemu-grub

build_and_test
