#!/bin/bash

set -e -x -E

export S3_BUCKET_NAME=${S3_BUCKET_NAME:-"mender-binaries"}

echo "WORKSPACE=$WORKSPACE"

declare -a CONFIG_MACHINE_NAMES
declare -a CONFIG_BOARD_NAMES
declare -a CONFIG_IMAGE_NAMES
declare -a CONFIG_DEVICE_TYPES

export PATH=$PATH:$WORKSPACE/go/bin

# Get revision for a repository (i.e mender-something to $MENDER_SOMETHING_REV)
repo_to_rev() {
    echo "$(eval echo \$$(echo $1 | tr [a-z-] [A-Z_])_REV)"
}

is_building_board() {
    local ret=0
    local uc_board="$(tr [a-z-] [A-Z_] <<<$1)"
    local lc_board="$(tr [A-Z-] [a-z_] <<<$1)"
    eval test "\$BUILD_${uc_board}" = true && egrep -q "(^|[^_]\b)mender_${lc_board}(\$|\b[^_])" <<<"$JOB_BASE_NAME" || ret=$?
    return $ret
}

is_testing_board() {
    local ret=0
    local uc_board="$(tr [a-z-] [A-Z_] <<<$1)"
    local lc_board="$(tr [A-Z-] [a-z_] <<<$1)"
    eval test "\$TEST_${uc_board}" = true && egrep -q "(^|[^_]\b)mender_${lc_board}(\$|\b[^_])" <<<"$JOB_BASE_NAME" || ret=$?
    return $ret
}

# Here is the rationale behind this function: It takes a lot of time to build
# all the extra Yocto images apart from the base image, like the read-only
# image, commercial image, etc. We only need them to build Docker images, so we
# could simply test for that. However, there is testing value in simply building
# the image for a given board type, even if we won't actually use the image. So
# use either of those two as triggers. If we are not building Docker images, and
# not testing this board, then disable the image building, which saves a lot of
# time when doing pure builds.
is_building_extra_images_for_board() {
    local ret=0
    local board_name="$1"
    ${BUILD_DOCKER_IMAGES:-false} || is_testing_board "$board_name" || ret=$?
    return $ret
}

has_component() {
    test -d $WORKSPACE/go/src/github.com/mendersoftware/$1
    return $?
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

run_bitbake() {
    local ret=0
    bitbake "$@" || ret=$?
    if [ $ret -ne 0 ]; then
        for log in $(find $WORKSPACE -name pseudo.log); do
            echo "Printing $log:"
            cat "$log"
        done
    fi
    return $ret
}

prepare_and_set_PATH() {
    bitbake -c prepare_recipe_sysroot mender-test-dependencies
    eval `bitbake -e mender-test-dependencies | grep '^export PATH='`:$PATH
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

# Get the yocto recipe name from the repo
repo_to_recipe() {
    case "$1" in
    mender-configure-module)
        echo "mender-configure"
        ;;
    monitor-client)
        echo "mender-monitor"
        ;;
    *)
        echo $1
        ;;
    esac
}

# Repo is closed source (installs prebuilt tarball)
is_closed_source() {
    case "$1" in
    mender-binary-delta|monitor-client|mender-gateway)
        return 0
        ;;
    *)
        return 1
        ;;
    esac
}

prepare_build_config() {
    local machine
    machine=$1
    local board
    board=$2

    if [ -d $WORKSPACE/meta-mender/tests/build-conf/${board} ]; then
        copy_build_conf $WORKSPACE/meta-mender/tests/build-conf/${board}/*  $BUILDDIR/conf/
    else
        echo "Could not find build-conf for $board board."
        return 1
    fi

    # Checked out open source components:
    # -> preferred version can be a tag or <branch>-git%, with special handling for PRs
    # -> external source is the GO src dir or the actual subdir

    for source_repository in $(ls $WORKSPACE/go/src/github.com/mendersoftware/); do
        if is_closed_source $source_repository; then
            # Explicit handling below
            continue
        fi

        # Version from env variables
        local env_version=$(repo_to_rev $source_repository)

        # Yocto version in order of preference:
        # -> if exact Git tag, use that
        # -> if PR, use master-git%
        # -> otherwise env ver + git% (maser-git, 5.0.x-git, etc)
        local yocto_version="$env_version-git%"
        if [[ "$env_version" =~ ^pull/[0-9]+/head$ ]]; then
            yocto_version="master-git%"
        fi
        local on_exact_tag=$(test "$env_version" != "master" && \
            cd $WORKSPACE/go/src/github.com/mendersoftware/$source_repository && \
            git tag --points-at HEAD 2>/dev/null | egrep ^"$env_version"$ ) || \
            on_exact_tag=
        if [ -n "$on_exact_tag" ]; then
            yocto_version="$on_exact_tag"
        fi

        # Handling of external source path for go software
        if [ -e "$WORKSPACE/go/src/github.com/mendersoftware/$source_repository/go.mod" ]; then
            externalsrc="$WORKSPACE/go"
        else
            externalsrc="$WORKSPACE/go/src/github.com/mendersoftware/$source_repository"
        fi

        recipe=$(repo_to_recipe $source_repository)

        cat >> $BUILDDIR/conf/local.conf <<EOF
EXTERNALSRC:pn-${recipe} = "$externalsrc"
EXTERNALSRC:pn-${recipe}-native = "$externalsrc"
PREFERRED_VERSION:pn-${recipe} = "$yocto_version"
PREFERRED_VERSION:pn-${recipe}-native = "$yocto_version"
EOF
    done

    # Closed source components:
    # -> if checked out, locate the package
    # -> otherwise fetch from S3 bucket

    if has_component mender-binary-delta; then
        # MEN-5268 TODO: locate the local package instead
        echo "mender-binary-delta cannot (yet) be integrated from master."
        exit 1
    else
        local version="$MENDER_BINARY_DELTA_VERSION"
        if [ -z "$version" -o "$version" = "latest" ]; then
            version=$(get_latest_recipe_version meta-mender-commercial/recipes-mender/mender-binary-delta)
        fi
        s3cmd get s3://${S3_BUCKET_NAME}/mender-binary-delta/${version}/mender-binary-delta-${version}.tar.xz $WORKSPACE/downloads
        cat >> $BUILDDIR/conf/local.conf <<EOF
PREFERRED_VERSION:pn-mender-binary-delta = "$version"
SRC_URI:pn-mender-binary-delta = "file:///$WORKSPACE/downloads/mender-binary-delta-${version}.tar.xz"
EOF
    fi

    if has_component monitor-client; then
        local mender_monitor_filename=$(find $WORKSPACE/stage-artifacts/ -maxdepth 1  -name "mender-monitor-*.tar.gz" | head -n1 | xargs basename)
        local mender_monitor_version=$(tar -Oxf $WORKSPACE/stage-artifacts/$mender_monitor_filename ./mender-monitor/.version | egrep -o '[0-9]+\.[0-9]+\.[0-9b]+(-build[0-9]+)?')
        if [ -z "$mender_monitor_version" ]; then
            mender_monitor_version="master-git%"
        fi
    cat >> $BUILDDIR/conf/local.conf <<EOF
SRC_URI:pn-mender-monitor = "file:///$WORKSPACE/stage-artifacts/$mender_monitor_filename"
PREFERRED_VERSION:pn-mender-monitor = "$mender_monitor_version"
EOF
    else
        local version="$MONITOR_CLIENT_REV"
        if [ -z "$version" -o "$version" = "latest" ]; then
            version=$(get_latest_recipe_version meta-mender-commercial/conditional/mender-monitor)
        fi
        s3cmd get s3://${S3_BUCKET_NAME}/mender-monitor/yocto/${version}/mender-monitor-${version}.tar.gz $WORKSPACE/downloads
        cat >> $BUILDDIR/conf/local.conf <<EOF
PREFERRED_VERSION:pn-mender-monitor = "$version"
SRC_URI:pn-mender-monitor = "file:///$WORKSPACE/downloads/mender-monitor-${version}.tar.gz"
EOF
    fi

    if has_component mender-gateway; then
        local mender_gateway_filename=$(find $WORKSPACE/stage-artifacts/ -maxdepth 1  -name "mender-gateway-*.tar.xz" | head -n1 | xargs basename)
        tar -C /tmp -xf $WORKSPACE/stage-artifacts/$mender_gateway_filename ./${mender_gateway_filename%.tar.xz}/x86_64/mender-gateway
        local mender_gateway_version=$(/tmp/${mender_gateway_filename%.tar.xz}/x86_64/mender-gateway --version | head -n 1 | egrep -o '([0-9]+\.[0-9]+\.[0-9b]+(-build[0-9]+)?)')
        rm /tmp/${mender_gateway_filename%.tar.xz}/x86_64/mender-gateway
        if [ -z "$mender_gateway_version" ]; then
            mender_gateway_version="master-git%"
        fi
        local mender_gateway_examples_filename=$(find $WORKSPACE/stage-artifacts/ -maxdepth 1  -name "mender-gateway-examples-*.tar" | head -n1 | xargs basename)
        cat >> $BUILDDIR/conf/local.conf <<EOF
PREFERRED_VERSION:pn-mender-gateway = "$mender_gateway_version"
SRC_URI:pn-mender-gateway = "file:///$WORKSPACE/stage-artifacts/$mender_gateway_filename"
SRC_URI:pn-mender-gateway:append = " file:///$WORKSPACE/stage-artifacts/$mender_gateway_examples_filename"
EOF
    else
        local version="$MENDER_GATEWAY_REV"
        if [ -z "$version" -o "$version" = "latest" ]; then
            version=$(get_latest_recipe_version meta-mender-commercial/recipes-mender/mender-gateway)
        fi
        s3cmd get s3://${S3_BUCKET_NAME}/mender-gateway/yocto/${version}/mender-gateway-${version}.tar.xz $WORKSPACE/downloads
        s3cmd get s3://${S3_BUCKET_NAME}/mender-gateway/examples/${version}/mender-gateway-examples-${version}.tar $WORKSPACE/downloads
        cat >> $BUILDDIR/conf/local.conf <<EOF
PREFERRED_VERSION:pn-mender-gateway = "$version"
SRC_URI:pn-mender-gateway = "file:///$WORKSPACE/downloads/mender-gateway-${version}.tar.xz"
SRC_URI:pn-mender-gateway:append = " file:///$WORKSPACE/downloads/mender-gateway-examples-${version}.tar"
EOF
    fi

    # For now the mender-orchestrator version is hardcoded to master as we don't yet
    # have the logic to checkout revisions and build from source.
    # This will be aligned with the other closed-source components in QA-1180
    local version="master"
    s3cmd get s3://${S3_BUCKET_NAME}/mender-orchestrator/${version}/mender-orchestrator-${version}.tar.xz $WORKSPACE/downloads
    cat >> $BUILDDIR/conf/local.conf <<EOF
PREFERRED_VERSION:pn-mender-orchestrator = "$version"
SRC_URI:pn-mender-orchestrator = "file:///$WORKSPACE/downloads/mender-orchestrator-${version}.tar.xz"
EOF

    cat >> $BUILDDIR/conf/local.conf <<EOF
# When using externalsrc from CI, we still want to apply patches
SRCTREECOVEREDTASKS:remove = "do_patch"

EOF
    # For now the mender-orchestrator-support version is hardcoded to main as we don't yet
    # have the logic to checkout revisions.
    # This will be aligned with the other closed-source components in QA-1180
    local version="main-git%"
    cat >> $BUILDDIR/conf/local.conf <<EOF
PREFERRED_VERSION:pn-mender-orchestrator-support = "$version"
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
MENDER_ARTIFACT_NAME = "mender-image-$(date +%Y%m%d-%H%M%S)"
EOF

    # Set preferred versions for components known to have major upgrades
    for recipe_dir in "meta-mender-core/recipes-mender/mender-artifact" \
            "meta-mender-core/recipes-mender/mender-client" \
            "meta-mender-commercial/recipes-mender/mender-gateway"; do
        local recipe=$(basename "$recipe_dir")
        if [ "$recipe" = "mender-client" ]; then
            recipe=mender
        fi

        if ! grep -q "^PREFERRED_VERSION:pn-${recipe} =" "$BUILDDIR/conf/local.conf"; then
            # Using latest version instead of "M.%"" due to a bug in yocto. See:
            #  https://bugzilla.yoctoproject.org/show_bug.cgi?id=15967
            local latest_version=$(get_latest_recipe_version "$recipe_dir")
            cat >> $BUILDDIR/conf/local.conf <<EOF
PREFERRED_VERSION:pn-${recipe} = "${latest_version}"
PREFERRED_VERSION:pn-${recipe}-native = "${latest_version}"
EOF
        fi
    done

    # Select provider in LTS branches that have both golang and C++ client
    # TODO: Remove after kirkstone goes end of life
    cat >> $BUILDDIR/conf/local.conf <<EOF
PREFERRED_PROVIDER_mender-native  = "mender-native"
PREFERRED_RPROVIDER_mender-auth   = "mender"
PREFERRED_RPROVIDER_mender-update = "mender"
EOF
}

# prepares the configuration for the so-called clean image. this is the image
# that will be embedded in the client containers and then used in integration tests
# see integration/tests/run.sh
# the main idea is to change the artifact_info and the additional targets are added
# in order to distinguish this image (for instance so we can recognize it from
# the inside in the tests)
clean_build_config() {
    sed -i.backup -e 's/^MENDER_ARTIFACT_NAME = .*/MENDER_ARTIFACT_NAME = "mender-image-clean"/' $BUILDDIR/conf/local.conf
    echo "IMAGE_INSTALL:append = \" sqlite3 lsof\"" >> "$BUILDDIR/conf/local.conf"
    echo "using following $BUILDDIR/conf/local.conf as clean image {{{"
    cat "$BUILDDIR/conf/local.conf" | grep -v '^#' | grep -v ^$ || true
    echo "}}}"
}

# restore the changes made by clean_build_config and to build the regular images
# regular being the ones that run on the devices initially
restore_build_config() {
    mv -fv "${BUILDDIR}/conf/local.conf.backup" "${BUILDDIR}/conf/local.conf"
}

# copies and returns the file path to the clean image, used later in the tests to update to
# (see above comment in clean_build_config)
copy_clean_image() {
    local machine_name="$1"
    local board_name="$2"
    local image_name="$3"
    local device_type="$4"
    local extension="$5"
    local filename
    local features

    filename="${image_name}-${machine_name}.${extension}"
    # we need to compress the image otherwise we catch the payload too large 413 on publish
    gzip -8 -c "${BUILDDIR}/tmp/deploy/images/${machine_name}/${filename}" \
        > "${BUILDDIR}/tmp/deploy/images/${machine_name}/clean-${filename}.gz"
}

# copies the bootable QEMU images and other related files to the workspace
# directory so they can be collected by CI as build artifacts to allow local testing
copy_build_artifacts_to_workspace() {
    local machine_name="$1"
    local board_name="$2"
    local image_name="$3"
    local device_type="$4"

    local deploy_dir="${BUILDDIR}/tmp/deploy/images/${machine_name}"

    local files_to_copy=(
        "${image_name}-${machine_name}.uefiimg:UEFI image"
        "${image_name}-${machine_name}.sdimg:SD image"
        "${image_name}-${machine_name}.wic:WIC image"
        "ovmf.qcow2:OVMF UEFI firmware"
        "bzImage:bzImage"
        "${image_name}-${machine_name}.cpio.gz:cpio.gz image"
    )

    for file_entry in "${files_to_copy[@]}"; do
        local file_path="${file_entry%:*}"
        local description="${file_entry#*:}"

        if [ -f "${deploy_dir}/${file_path}" ]; then
            echo "Copying ${description} for QEMU to be archived..."
            cp -flv "${deploy_dir}/${file_path}" "$WORKSPACE/$board_name/"
        fi
    done
}


# returns the latest available version of a recipe
get_latest_recipe_version() {
    local recipe_dir="$1"
    ls ${WORKSPACE}/meta-mender/${recipe_dir}/*.bb \
        | grep -E '[0-9]+\.[0-9]+\.[0-9b]+(-build[0-9]+)?' \
        | sort -V \
        | tail -n1 \
        | egrep -o '[0-9]+\.[0-9]+\.[0-9b]+(-build[0-9]+)?'
}


init_environment() {
    # Verify mender-qa directory exists
    if [ ! -d mender-qa ]
    then
        echo "mender-qa directory is not present"
        exit 1
    fi

    if [ ! -w /dev/kvm ] || [ ! -r /dev/kvm ]; then
        echo "/dev/kvm is not properly configured for user: $(whoami)"
        echo "user groups: $(groups)"
        echo "$(ls -l /dev/kvm)"
        echo "the tests need read and write access to the KVM device"
        exit 1
    fi

    # Directory for pre-built S3 packages
    mkdir -p $WORKSPACE/downloads

    # Get mender-binary-delta generator
    # MEN-5268 TODO: move somewhere else (acceptance tests?)
    if [ -d $WORKSPACE/meta-mender/meta-mender-commercial ]; then
        local version=$(get_latest_recipe_version meta-mender-commercial/recipes-mender/mender-binary-delta)
        mkdir -p $WORKSPACE/bin
        s3cmd get s3://${S3_BUCKET_NAME}/mender-binary-delta/${version}/x86_64/mender-binary-delta-generator $WORKSPACE/bin
        chmod +x $WORKSPACE/bin/mender-binary-delta-generator
        export PATH=$PATH:$WORKSPACE/bin
    fi
}

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
# correct one will be chosen with select_build_config().
#
# Parameters:
#   - machine name - Yocto MACHINE name
#   - board name - usually the same or similar to machine name, but each machine
#                  name can have several boards
#   - image name - Yocto image name
#   - device type - Mender device type. In most cases the same as machine name,
#                   but some machines and boards may have more than one device
#                   type, for example with different boot loaders
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

select_build_config() {
    local machine_to_build=
    local board_to_build=
    local image_to_build=

    for config in ${!CONFIG_MACHINE_NAMES[@]}; do
        local machine=${CONFIG_MACHINE_NAMES[$config]}
        local board=${CONFIG_BOARD_NAMES[$config]}
        local image=${CONFIG_IMAGE_NAMES[$config]}
        local device_type=${CONFIG_DEVICE_TYPES[$config]}
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
    done

    if [ -z "$machine_to_build" -o -z "$board_to_build" -o -z "$image_to_build" -o -z "$device_type_to_build" ]; then
        echo "No build configuration selected!"
        exit 1
    fi

    echo $machine_to_build $board_to_build $image_to_build $device_type_to_build
}

# ------------------------------------------------------------------------------
# Generic function for building and testing client.
#
# Parameters:
#   - machine name
#   - board name (usually the same or similar to machine name, but each machine
#                 name can have several boards)
#   - image name
#   - device type
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
        local filename
        local extension
        local features

        if ! is_building_board $board_name; then
            echo "Not building board? We should never get here."
            exit 1
        fi

        source oe-init-build-env build-$board_name
        cd ../

        prepare_build_config $machine_name $board_name

        cd $BUILDDIR

        # Base image
        local images_to_build=$image_name

        if is_building_extra_images_for_board "$board_name" \
                && [[ $image_name == core-image-full-cmdline ]]; then
            images_to_build+=" mender-image-full-cmdline-rofs"
            if has_component monitor-client \
                    && [[ -f $WORKSPACE/meta-mender/meta-mender-commercial/recipes-extended/images/mender-monitor-image-full-cmdline.bb ]]; then
                images_to_build+=" mender-monitor-image-full-cmdline"
            fi
            if [[ -f $WORKSPACE/meta-mender/meta-mender-commercial/recipes-extended/images/mender-image-full-cmdline-rofs-commercial.bb ]]; then
                images_to_build+=" mender-image-full-cmdline-rofs-commercial"
            fi
        fi

        # Build once with clean_build_config enabled and keep a copy.
        bitbake-layers add-layer $WORKSPACE/meta-mender/meta-mender-commercial
        clean_build_config
        run_bitbake $images_to_build
        if ${BUILD_DOCKER_IMAGES:-false}; then
            features=`bitbake -e $image_name | egrep '^MENDER_FEATURES=' || true`
            # fall back to DISTRO_FEATURES if we found no MENDER_FEATURES
            [[ "$features" == "" ]] && features=`bitbake -e $image_name | egrep '^DISTRO_FEATURES='`
            egrep -q '\bmender-image-uefi\b' <<<${features} && extension="uefiimg"
            egrep -q '\bmender-image-sd\b' <<<${features} && extension="sdimg"

            for img in ${images_to_build}; do
                copy_clean_image "${machine_name}" "${board_name}" "${img}" "${device_type}" "${extension}"
            done

        fi
        restore_build_config

        # Rebuild without clean_build_config.
        run_bitbake $images_to_build

        if ${BUILD_DOCKER_IMAGES:-false}; then
            filename="clean-${image_name}-${machine_name}.${extension}"
            $WORKSPACE/meta-mender/meta-mender-qemu/docker/build-docker \
                -I "${BUILDDIR}/tmp/deploy/images/${machine_name}/${filename}.gz" \
                $machine_name \
                -t mendersoftware/mender-client-qemu:pr

            if grep mender-image-full-cmdline-rofs <<<"$images_to_build"; then
                filename="clean-mender-image-full-cmdline-rofs-${machine_name}.${extension}"
                $WORKSPACE/meta-mender/meta-mender-qemu/docker/build-docker \
                -I "${BUILDDIR}/tmp/deploy/images/${machine_name}/${filename}.gz" \
                    -i mender-image-full-cmdline-rofs \
                    $machine_name \
                    -t mendersoftware/mender-client-qemu-rofs:pr
            fi

            if grep mender-monitor-image-full-cmdline <<<"$images_to_build"; then
                filename="clean-mender-monitor-image-full-cmdline-${machine_name}.${extension}"
                $WORKSPACE/meta-mender/meta-mender-qemu/docker/build-docker \
                -I "${BUILDDIR}/tmp/deploy/images/${machine_name}/${filename}.gz" \
                    -i mender-monitor-image-full-cmdline \
                    $machine_name \
                    -t registry.mender.io/mendersoftware/mender-monitor-qemu-commercial:pr
            fi

            if grep mender-image-full-cmdline-rofs-commercial <<<"$images_to_build"; then
                filename="clean-mender-image-full-cmdline-rofs-commercial-${machine_name}.${extension}"

                $WORKSPACE/meta-mender/meta-mender-qemu/docker/build-docker \
                    -I "${BUILDDIR}/tmp/deploy/images/${machine_name}/${filename}.gz" \
                    -i mender-image-full-cmdline-rofs-commercial \
                    $machine_name \
                    -t registry.mender.io/mendersoftware/mender-qemu-rofs-commercial:pr
            fi
        fi

        bitbake-layers remove-layer $WORKSPACE/meta-mender/meta-mender-commercial

        mkdir -p $WORKSPACE/$board_name
        cp -vL $BUILDDIR/tmp/deploy/images/$machine_name/$image_name-$device_type.* $WORKSPACE/$board_name
        if [ -e $BUILDDIR/tmp/deploy/images/$machine_name/u-boot.elf ]; then
            cp -vL $BUILDDIR/tmp/deploy/images/$machine_name/u-boot.elf $WORKSPACE/$board_name
        fi

        copy_build_artifacts_to_workspace "$machine_name" "$board_name" "$image_name" "$device_type"

        for image in $WORKSPACE/$board_name/*; do
            cp $image $image.clean
        done

        prepare_and_set_PATH

        # run tests on qemu
        if is_testing_board $board_name; then
            export QEMU_SYSTEM_ARM="/usr/bin/qemu-system-arm"

            bitbake-layers add-layer "$WORKSPACE"/meta-mender/tests/meta-mender-ci
            if [ -d "$WORKSPACE"/meta-mender/tests/meta-mender-$machine_name-ci ]; then
                bitbake-layers add-layer "$WORKSPACE"/meta-mender/tests/meta-mender-$machine_name-ci
            fi

            # install test dependencies
            sudo pip3 install --break-system-packages -r $WORKSPACE/meta-mender/tests/acceptance/requirements_py3.txt

            echo "MENDER_FEATURES_ENABLE:append = \" mender-testing-enabled\"" >> $BUILDDIR/conf/local.conf

            run_bitbake $image_name

            cd $WORKSPACE/meta-mender/tests/acceptance/

            # check if we can generate an HTML report
            local html_report_args="--html=report.html --self-contained-html"
            if ! pip3 list|grep -e pytest-html >/dev/null 2>&1; then
                html_report_args=""
                echo "WARNING: install pytest-html for html results report"
            fi

            # make it possible to run specific test
            local acceptance_test_to_run=""
            if [ -n "$SPECIFIC_ACCEPTANCE_TEST" ]; then
                acceptance_test_to_run=" -k $SPECIFIC_ACCEPTANCE_TEST"
            fi

            local pytest_args=
            # Assuming rocko or newer
            pytest_args="$pytest_args --commercial-tests"

            local xdist_args
            local cross_args
            # Use the exclusivity fixture as a sign that this branch support modern
            # features of mender-image-tests: running tests in parallel and filtering
            # cross platform tests
            if ( cd image-tests && git grep -q '^def exclusivity' ); then
                xdist_args="-n $TESTS_IN_PARALLEL_CLIENT_ACCEPTANCE"
                cross_args="${CROSS_PLATFORM_TESTS_ARG}"
            else
                xdist_args="-p no:xdist"
            fi

            python3 -m pytest $xdist_args --verbose --junit-xml=results.xml \
                    --bitbake-image $image_name --board-type=$board_name $pytest_args \
                    $html_report_args $acceptance_test_to_run \
                    ${cross_args}

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
            local client_version="$MENDER_REV"
            if [[ "$client_version" =~ ^pull/[0-9]+/head$ ]]; then
                client_version="pr"
            fi
            cp $WORKSPACE/$board_name/$image_name-$device_type.ext4 $WORKSPACE/$board_name/$image_name-$device_type-release_1.ext4
            modify_ext4 $WORKSPACE/$board_name/$image_name-$device_type-release_1.ext4 release-1_${client_version}
            modify_artifact $WORKSPACE/$board_name/$image_name-$device_type.mender $WORKSPACE/$board_name/$image_name-$device_type.ext4 release-1_${client_version} $WORKSPACE/$board_name/${board_name}_release_1_${client_version}.mender
            if is_hardware_board $board_name; then
                gzip -c $WORKSPACE/$board_name/$image_name-$device_type.sdimg > $WORKSPACE/$board_name/mender-${board_name}_${client_version}.sdimg.gz
            fi
        fi
    )
}

# add_to_build_list        MACHINE_NAME              BOARD_NAME                     IMAGE_NAME               [DEVICE_TYPE]
add_to_build_list          qemux86-64                qemux86-64-uefi-grub           core-image-full-cmdline
add_to_build_list          vexpress-qemu             vexpress-qemu                  core-image-full-cmdline
add_to_build_list          vexpress-qemu-flash       vexpress-qemu-flash            core-image-minimal
add_to_build_list          raspberrypi3              raspberrypi3                   core-image-full-cmdline
add_to_build_list          raspberrypi4              raspberrypi4                   core-image-full-cmdline
add_to_build_list          beaglebone-yocto          beagleboneblack                core-image-base          beaglebone-yocto-grub
add_to_build_list          qemux86-64                qemux86-64-bios-grub-gpt       core-image-full-cmdline  qemux86-64-bios-grub-gpt
add_to_build_list          qemux86-64                qemux86-64-bios-grub           core-image-full-cmdline  qemux86-64-bios
add_to_build_list          vexpress-qemu             vexpress-qemu-uboot-uefi-grub  core-image-full-cmdline  vexpress-qemu-grub

# main
init_environment
build_config=$(select_build_config)
build_and_test_client $build_config
