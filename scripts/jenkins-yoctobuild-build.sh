#!/bin/bash
set -e -x


export WORKSPACE="/home/jenkins/workspace/yoctobuild/"
export PATH=${WORKSPACE}/scripts:${WORKSPACE}/bitbake/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games
BUILD_DIR=${WORKSPACE}/build/tmp/deploy/images

#replace filenames with variable
ORIGINAL_BBB_SDIMG=$BUILD_DIR/beaglebone/core-image-base-beaglebone.sdimg
ORIGINAL_BBB_EXT3=$BUILD_DIR/beaglebone/core-image-base-beaglebone.ext3
ORIGINAL_VEXPRESS_SDIMG=$BUILD_DIR/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.sdimg
ORIGINAL_VEXPRESS_EXT3=$BUILD_DIR/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.ext3

#unmodified copies of our build
ORIGINAL_BBB_SDIMG_COPY=$(mktemp)
ORIGINAL_BBB_EXT3_COPY=$(mktemp)
ORIGINAL_VEXPRESS_SDIMG_COPY=$(mktemp)
ORIGINAL_VEXPRESS_EXT3_COPY=$(mktemp)

#unmodified vexpress image for docker
MODIFIED_VEXPRESS_SDIMG="$BUILD_DIR"/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.sdimg.modified

function cleanup() {
    rm "$ORIGINAL_BBB_EXT3_COPY" "$ORIGINAL_BBB_SDIMG_COPY" "$ORIGINAL_VEXPRESS_EXT3_COPY" "$ORIGINAL_VEXPRESS_SDIMG_COPY"
}

function create_img_copies() {
    cp "$ORIGINAL_VEXPRESS_SDIMG" "$ORIGINAL_VEXPRESS_SDIMG_COPY"
    cp "$ORIGINAL_VEXPRESS_EXT3" "$ORIGINAL_VEXPRESS_EXT3_COPY"
    cp "$ORIGINAL_BBB_SDIMG" "$ORIGINAL_BBB_SDIMG_COPY"
    cp "$ORIGINAL_BBB_EXT3" "$ORIGINAL_BBB_EXT3_COPY"
    trap cleanup EXIT
}

function remove_file_sdimg() {
    local sdimg_file=$1
    local remove_file=$2
    local partition=$3
    local mnt_point="/mnt/loop_edit_sdimg/"

    sudo umount ${mnt_point} 2>/dev/null || true

    PART_OFFSET=$(sudo fdisk -l "$sdimg_file" | grep $(basename $sdimg_file)"${partition}" | awk '{sum = $2 * 512; print sum}')
    sudo mkdir -p ${mnt_point} >/dev/null
    sudo mount -t ext4 -o loop,offset="${PART_OFFSET}" "${sdimg_file}" ${mnt_point}
    sudo rm "${mnt_point}""${remove_file}"

    sudo umount ${mnt_point}
}

function add_file_sdimg() {
    local sdimg_file=$1
    local add_file=$2
    local add_file_path=$3
    local partition=$4
    local mnt_point="/mnt/loop_edit_sdimg/"

    sudo umount ${mnt_point} 2>/dev/null || true

    PART_OFFSET=$(sudo fdisk -l "$sdimg_file" | grep $(basename $sdimg_file)"${partition}" | awk '{sum = $2 * 512; print sum}')
    sudo mkdir -p ${mnt_point} >/dev/null
    sudo mount -t ext4 -o loop,offset="${PART_OFFSET}" "${sdimg_file}" ${mnt_point}
    sudo cp "${add_file}" "${mnt_point}""${add_file_path}"

    sudo umount ${mnt_point}
}


function clean_up_build() {
    source oe-init-build-env
    bitbake -c cleanall core-image-full-cmdline
    MACHINE="beaglebone" bitbake -c cleanall core-image-base
    rm -rf tmp/
    rm -rf sstate-cache/
}

function do_build() {
    source oe-init-build-env
    set +e

    bitbake core-image-full-cmdline
    export MACHINE="beaglebone"
    bitbake core-image-base
    set -e
}

function setup_build() {

    source oe-init-build-env
    cd ..

    if [ ! -d meta-mender-qemu ]; then
        echo "JENKINS SCRIPT: meta-mender-qemu directory is not present"
        exit 1
    else

    /bin/rm -f build/conf/bblayers.conf
    echo $?
    /bin/rm -f build/conf/local.conf
    echo $?
    /bin/cp meta-mender-qemu/build-conf/bblayers.conf  build/conf/bblayers.conf
    echo $?
    /bin/cp meta-mender-qemu/build-conf/local.conf  build/conf/local.conf
    echo $?
    # See comment in local.conf
    cat >> build/conf/local.conf <<EOF
EXTERNALSRC_pn-mender = "$WORKSPACE/mender"
EOF
fi


}

function run_tests() {
  for i in "$@" ; do
     if [[ $i == "--qemu" ]] ; then
        ( cd $WORKSPACE/meta-mender/tests/acceptance/ && py.test || exit 1 )
     fi

     if [[ $i == "--bbb" ]] ; then
       ( cd $WORKSPACE/meta-mender/tests/acceptance/ bash prepare_bbb_testing.sh || exit 1 )
     fi
  done
}

# If a build is triggered between 1:00 and 1:59, clean the builds and start from scratch
if [[ $(date +%H) -eq 1 ]]; then
    clean_up_build
fi

for i in "$@" ; do
    if [[ $i == "--skip-build" ]] ; then
        break
    fi

    setup_build && do_build
done

if [ "$#" -eq 0 ]; then
  setup_build && do_build
fi

create_img_copies

( cd $WORKSPACE/meta-mender/tests/acceptance/ && rm -f image.dat || true && cp $ORIGINAL_VEXPRESS_EXT3 image.dat)

run_tests "$@"

# we need this for the docker image later
cp "$ORIGINAL_VEXPRESS_SDIMG_COPY" "$MODIFIED_VEXPRESS_SDIMG"

# Restore original images with the mender service removed.
cp "$ORIGINAL_VEXPRESS_SDIMG_COPY" "$ORIGINAL_VEXPRESS_SDIMG"
cp "$ORIGINAL_VEXPRESS_EXT3_COPY" "$ORIGINAL_VEXPRESS_EXT3"
cp "$ORIGINAL_BBB_SDIMG_COPY" "$ORIGINAL_BBB_SDIMG"
cp "$ORIGINAL_BBB_EXT3_COPY" "$ORIGINAL_BBB_EXT3"

add_file_sdimg $MODIFIED_VEXPRESS_SDIMG ${WORKSPACE}/meta-mender/recipes-mender/mender/files/mender.service /etc/systemd/system/multi-user.target.wants/ 2
add_file_sdimg $MODIFIED_VEXPRESS_SDIMG ${WORKSPACE}/meta-mender/recipes-mender/mender/files/mender.service /lib/systemd/system/ 2
