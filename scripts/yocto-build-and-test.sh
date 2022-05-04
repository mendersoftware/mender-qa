#!/bin/bash

set -e -x -E

export S3_BUCKET_NAME=${S3_BUCKET_NAME:-"mender-binaries"}

echo "WORKSPACE=$WORKSPACE"

declare -a CONFIG_MACHINE_NAMES
declare -a CONFIG_BOARD_NAMES
declare -a CONFIG_IMAGE_NAMES
declare -a CONFIG_DEVICE_TYPES

export PATH=$PATH:$WORKSPACE/go/bin

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
    local mender_connect_version=$($WORKSPACE/integration/extra/release_tool.py --version-of mender-connect --in-integration-version HEAD)


    local mender_binary_delta_version=$($WORKSPACE/mender-binary-delta/x86_64/mender-binary-delta --version | egrep -o '[0-9]+\.[0-9]+\.[0-9b]+(-build[0-9]+)?')
    cat >> $BUILDDIR/conf/local.conf <<EOF
LICENSE_FLAGS_WHITELIST = "commercial_mender-binary-delta"
FILESEXTRAPATHS_prepend_pn-mender-binary-delta := "$WORKSPACE/mender-binary-delta:"
PREFERRED_VERSION_pn-mender-binary-delta = "$mender_binary_delta_version"
EOF

    if has_component monitor-client; then
        local mender_monitor_filename=$(find $WORKSPACE/stage-artifacts/ -maxdepth 1  -name "mender-monitor-*.tar.gz" | head -n1 | xargs basename)
        local mender_monitor_version=$(tar -Oxf $WORKSPACE/stage-artifacts/$mender_monitor_filename ./mender-monitor/.version | egrep -o '[0-9]+\.[0-9]+\.[0-9b]+(-build[0-9]+)?')
        if [ -z "$mender_monitor_version" ]; then
            mender_monitor_version="master-git%"
        fi
    cat >> $BUILDDIR/conf/local.conf <<EOF
LICENSE_FLAGS_WHITELIST += "commercial_mender-monitor"
SRC_URI_pn-mender-monitor = "file:///$WORKSPACE/stage-artifacts/$mender_monitor_filename"
PREFERRED_VERSION_pn-mender-monitor = "$mender_monitor_version"
EOF
    fi

    if has_component mender-gateway; then
        local mender_gateway_filename=$(find $WORKSPACE/stage-artifacts/ -maxdepth 1  -name "mender-gateway-*.tar.xz" | head -n1 | xargs basename)
        tar -C /tmp -xf $WORKSPACE/stage-artifacts/$mender_gateway_filename ./${mender_gateway_filename%.tar.xz}/x86_64/mender-gateway
        local mender_gateway_version=$(/tmp/${mender_gateway_filename%.tar.xz}/x86_64/mender-gateway --version | egrep -o '[0-9]+\.[0-9]+\.[0-9b]+(-build[0-9]+)?')
        rm /tmp/${mender_gateway_filename%.tar.xz}/x86_64/mender-gateway
        if [ -z "$mender_gateway_version" ]; then
            mender_gateway_version="master-git%"
        fi
        local mender_gateway_examples_filename=$(find $WORKSPACE/stage-artifacts/ -maxdepth 1  -name "mender-gateway-examples-*.tar" | head -n1 | xargs basename)
        cat >> $BUILDDIR/conf/local.conf <<EOF
LICENSE_FLAGS_WHITELIST += "commercial_mender-gateway"
SRC_URI_pn-mender-gateway = "file:///$WORKSPACE/stage-artifacts/$mender_gateway_filename"
SRC_URI_pn-mender-gateway_append = " file:///$WORKSPACE/stage-artifacts/$mender_gateway_examples_filename"
PREFERRED_VERSION_pn-mender-gateway = "$mender_gateway_version"
EOF
    fi

    if [ "$MENDER_CONFIGURE_MODULE_VERSION" != "latest" ]; then
        cat >> $BUILDDIR/conf/local.conf <<EOF
PREFERRED_VERSION_pn-mender-configure = "$MENDER_CONFIGURE_MODULE_VERSION"
EOF
    fi

    # Assuming sumo or newer
    cat >> $BUILDDIR/conf/local.conf <<EOF
# MEN-2948: Renamed mender recipe -> mender-client
# But the "mender" reference has to be kept for backwards compatibility
# with 2.1.x, 2.2.x, and 2.3.x
EXTERNALSRC_pn-mender = "$WORKSPACE/go"
EXTERNALSRC_pn-mender-client = "$WORKSPACE/go"
EXTERNALSRC_pn-mender-client-native = "$WORKSPACE/go"
EXTERNALSRC_pn-mender-artifact = "$WORKSPACE/go"
EXTERNALSRC_pn-mender-artifact-native = "$WORKSPACE/go"
EXTERNALSRC_pn-mender-connect= "$WORKSPACE/go"
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
    local mender_connect_on_exact_tag=$(test "$MENDER_CONNECT_REV" != "master" && \
        cd $WORKSPACE/go/src/github.com/mendersoftware/mender-connect && \
        git tag --points-at HEAD 2>/dev/null | egrep ^"$MENDER_CONNECT_REV"$ ) || \
        mender_connect_on_exact_tag=

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
PREFERRED_VERSION_pn-mender-client-native = "$mender_on_exact_tag"
EOF
    else
        cat >> $BUILDDIR/conf/local.conf <<EOF
# MEN-2948: Renamed mender recipe -> mender-client
# But the "mender" reference has to be kept for backwards compatibility
# with 2.1.x, 2.2.x, and 2.3.x
PREFERRED_VERSION_pn-mender = "$client_version-git%"
PREFERRED_VERSION_pn-mender-client = "$client_version-git%"
PREFERRED_VERSION_pn-mender-client-native = "$client_version-git%"
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

    if [ -n "$mender_connect_on_exact_tag" ]; then
        cat >> $BUILDDIR/conf/local.conf <<EOF
PREFERRED_VERSION_pn-mender-connect = "$mender_connect_on_exact_tag"
EOF
    else
        cat >> $BUILDDIR/conf/local.conf <<EOF
PREFERRED_VERSION_pn-mender-connect = "$mender_connect_version-git%"
EOF
    fi
}

# prepares the configuration for the so-called clean image. this is the image
# that will be embedded in the client containers and then used in integartion tests
# see integration/tests/run.sh
# the main idea is to change the artifact_info and the additional targets are added 
# in order to distinguish this image (for instance so we can recognize it from
# the inside in the tests)
clean_build_config() {
    sed -i.backup -e 's/^MENDER_ARTIFACT_NAME = .*/MENDER_ARTIFACT_NAME = "mender-image-clean"/' $BUILDDIR/conf/local.conf
    echo 'IMAGE_INSTALL_append = " sqlite3 lsof"' >> "$BUILDDIR/conf/local.conf"
    echo "using following $BUILDDIR/conf/local.conf as clean image {{{"
    cat "$BUILDDIR/conf/local.conf" | grep -v '^#' | grep -v ^$ || true
    echo "}}}"
}

# restore the changes made by clean_build_config and to build the regular images
# regular being the ones that run on the devices initially
# the bitbake mannder-artifact-info part is needed to pickup the MENDER_ARTIFACT_NAME
# change
restore_build_config() {
    mv -fv "${BUILDDIR}/conf/local.conf.backup" "${BUILDDIR}/conf/local.conf"
    bitbake mender-artifact-info
}

# copies and returns the file path to the clean image, used later in the tests to update to
# (see above comment in clean_build_config)
copy_clean_image() {
    local machine_name="$1"
    local board_name="$2"
    local image_name="$3"
    local device_type="$4"
    local extension=""
    local filename
    local features

    features=`bitbake -e $image_name | egrep '^MENDER_FEATURES='`
    # fall back to DISTRO_FEATURES if we found no MENDER_FEATURES
    [[ "$features" == "" ]] && features=`bitbake -e $image_name | egrep '^DISTRO_FEATURES='`
    egrep -q '\bmender-image-uefi\b' <<<${features} && extension="uefiimg"
    egrep -q '\bmender-image-sd\b' <<<${features} && extension="sdimg"
    filename="$(bitbake -e $image_name | egrep '^IMAGE_LINK_NAME=' | sed -e 's/.*=//' -e 's/\"//g').${extension}"
    cp -Lv "${BUILDDIR}/tmp/deploy/images/${machine_name}/${filename}" "${BUILDDIR}/tmp/deploy/images/${machine_name}/clean-${filename}" 1>&2
    # we need to compress the image otherwise we catch the payload too large 413 on publish
    gzip -8 ${BUILDDIR}/tmp/deploy/images/${machine_name}/clean-${filename} || true
    echo "${BUILDDIR}/tmp/deploy/images/${machine_name}/clean-${filename}.gz"
}

init_environment() {
    # Verify mender-qa directory exists
    if [ ! -d mender-qa ]
    then
        echo "mender-qa directory is not present"
        exit 1
    fi

    # Clean up build slave.
    if [ "$CLEAN_BUILD_CACHE" = "true" ]
    then
        sudo rm -rf /mnt/sstate-cache/*
    fi

    # Handle meta-mender sub modules.
    cd $WORKSPACE/meta-mender
    git submodule update --init --recursive
    cd $WORKSPACE

    # Get mender-binary-delta and add it to the PATH
    if [ -d $WORKSPACE/meta-mender/meta-mender-commercial ]; then
        if [ -z "$MENDER_BINARY_DELTA_VERSION" -o "$MENDER_BINARY_DELTA_VERSION" = "latest" ]; then
            RECIPE=$(ls $WORKSPACE/meta-mender/meta-mender-commercial/recipes-mender/mender-binary-delta/*.bb | sort | tail -n1)
        else
            RECIPE=$(ls $WORKSPACE/meta-mender/meta-mender-commercial/recipes-mender/mender-binary-delta/*$MENDER_BINARY_DELTA_VERSION*.bb)
        fi
        mkdir -p $WORKSPACE/mender-binary-delta
        s3cmd get --recursive s3://${S3_BUCKET_NAME}/$(sed -e 's,.*/,,; s,delta_,delta/,; s/\.bb$//' <<<$RECIPE)/ $WORKSPACE/mender-binary-delta/
        chmod ugo+x $WORKSPACE/mender-binary-delta/x86_64/mender-binary-delta
        chmod ugo+x $WORKSPACE/mender-binary-delta/x86_64/mender-binary-delta-generator
        export PATH=$PATH:$WORKSPACE/mender-binary-delta/x86_64
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

# often we are started getting
# "fatal: unsafe repository ('/builds/Northern.tech/Mender/go/src/github.com/mendersoftware/mender' is owned by someone else)"
# * happens a lot, but not always
# * debugged, stopped at the error, cannot reproduce: make command passes, owners match
# * once mender directory (last element of the above path) is chown root error can be seen
# * this is the only workaround we have for now
prepare_git_repos_settings() {
    git config --global --add safe.directory "${WORKSPACE}/go/src/github.com/mendersoftware/mender"
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
        local clean_image

        if ! is_building_board $board_name; then
            echo "Not building board? We should never get here."
            exit 1
        fi

        source oe-init-build-env build-$board_name
        cd ../

        prepare_build_config $machine_name $board_name

        cd $BUILDDIR

        # Additional git settings on repos
        prepare_git_repos_settings

        # Base image clean
        clean_build_config
        bitbake $image_name
        clean_image=`copy_clean_image "${machine_name}" "${board_name}" "${image_name}" "${device_type}"`
        restore_build_config

        # Base image
        bitbake $image_name
        if ${BUILD_DOCKER_IMAGES:-false}; then
            $WORKSPACE/meta-mender/meta-mender-qemu/docker/build-docker \
                -I "${clean_image}" \
                $machine_name \
                -t mendersoftware/mender-client-qemu:pr
            $WORKSPACE/integration/extra/release_tool.py \
                --set-version-of mender-client-qemu \
                --version pr
        fi

        # R/O image
        if [[ $image_name == core-image-full-cmdline ]]; then
            clean_build_config
            bitbake mender-image-full-cmdline-rofs
            clean_image=`copy_clean_image "${machine_name}" "${board_name}" "mender-image-full-cmdline-rofs" "${device_type}"`
            restore_build_config
            bitbake mender-image-full-cmdline-rofs
            if ${BUILD_DOCKER_IMAGES:-false}; then
                $WORKSPACE/meta-mender/meta-mender-qemu/docker/build-docker \
                    -I "${clean_image}" \
                    -i mender-image-full-cmdline-rofs \
                    $machine_name \
                    -t mendersoftware/mender-client-qemu-rofs:pr
                $WORKSPACE/integration/extra/release_tool.py \
                    --set-version-of mender-client-qemu-rofs \
                    --version pr
            fi
        fi

        # Check if there is a mender-monitor image recipe available.
        if has_component monitor-client \
               && [[ $image_name == core-image-full-cmdline ]] \
               && [[ -f $WORKSPACE/meta-mender/meta-mender-commercial/recipes-extended/images/mender-monitor-image-full-cmdline.bb ]]; then
            bitbake-layers add-layer $WORKSPACE/meta-mender/meta-mender-commercial
            clean_build_config
            bitbake mender-monitor-image-full-cmdline
            clean_image=`copy_clean_image "${machine_name}" "${board_name}" "mender-monitor-image-full-cmdline" "${device_type}"`
            restore_build_config
            bitbake mender-monitor-image-full-cmdline
            if ${BUILD_DOCKER_IMAGES:-false}; then
                $WORKSPACE/meta-mender/meta-mender-qemu/docker/build-docker \
                    -I "${clean_image}" \
                    -i mender-monitor-image-full-cmdline \
                    $machine_name \
                    -t registry.mender.io/mendersoftware/mender-monitor-qemu-commercial:pr
                # It's ok if the next step fails, it just means we are
                # testing a version of integration that neither has a monitor
                # image, nor any tests for it.
                $WORKSPACE/integration/extra/release_tool.py \
                    --set-version-of mender-monitor-qemu-commercial \
                    --version pr || true
            fi
            bitbake-layers remove-layer $WORKSPACE/meta-mender/meta-mender-commercial
        fi

        # Check if there is a mender-gateway image recipe available.
        if has_component mender-gateway \
               && [[ $image_name == core-image-full-cmdline ]] \
               && [[ -f $WORKSPACE/meta-mender/meta-mender-commercial/recipes-extended/images/mender-gateway-image-full-cmdline.bb ]]; then
            bitbake-layers add-layer $WORKSPACE/meta-mender/meta-mender-commercial
            clean_build_config
            bitbake mender-gateway-image-full-cmdline
            clean_image=`copy_clean_image "${machine_name}" "${board_name}" "mender-gateway-image-full-cmdline" "${device_type}"`
            restore_build_config
            bitbake mender-gateway-image-full-cmdline
            if ${BUILD_DOCKER_IMAGES:-false}; then
                $WORKSPACE/meta-mender/meta-mender-qemu/docker/build-docker \
                    -I "${clean_image}" \
                    -i mender-gateway-image-full-cmdline \
                    $machine_name \
                    -t registry.mender.io/mendersoftware/mender-gateway-qemu-commercial:pr
                # It's ok if the next step fails, it just means we are
                # testing a version of integration that neither has a gateway
                # image, nor any tests for it.
                $WORKSPACE/integration/extra/release_tool.py \
                    --set-version-of mender-gateway-qemu-commercial \
                    --version pr || true
            fi
            bitbake-layers remove-layer $WORKSPACE/meta-mender/meta-mender-commercial
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
            # TODO: clean-up python2 support after warrior goes unsupported
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

            # Zeus and older do not have this.
            if grep -q mender-testing-enabled $WORKSPACE/meta-mender/meta-mender-core/classes/mender-maybe-setup.bbclass; then
            echo 'MENDER_FEATURES_ENABLE_append = " mender-testing-enabled"' >> $BUILDDIR/conf/local.conf
            fi

            bitbake $image_name

            cd $WORKSPACE/meta-mender/tests/acceptance/

            # check if we can generate an HTML report
            local html_report_args="--html=report.html --self-contained-html"
            if ! $pip_cmd list|grep -e pytest-html >/dev/null 2>&1; then
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
