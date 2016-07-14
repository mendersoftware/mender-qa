#!/bin/bash
shopt -s extglob
set -x
export PATH=$WORKSPACE/scripts:$WORKSPACE/bitbake/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games

rm -rf "$WORKSPACE/build/tmp/"

# If a build is triggered between 1:00 and 1:59, clean the builds and start from scratch
if [[ $(date +%H) -eq 1 ]]; then
   source oe-init-build-env
   bitbake -c cleanall core-image-full-cmdline
   MACHINE="beaglebone" bitbake -c cleanall core-image-base
   rm -rf sstate-cache/
fi


source oe-init-build-env
pwd
cd ../
pwd

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

source oe-init-build-env
#(cd tmp && rm -rf !(deploy/images))
bitbake-prserv --start
export PRSERV_HOST="localhost:8585"
bitbake core-image-full-cmdline


#Beaglebone stopped compiling without this
#(cd tmp && rm -rf !(deploy/images))

export MACHINE="beaglebone"
bitbake core-image-base

cd ../meta-mender/tests/acceptance/
rm -f image.dat

ORIGINAL_BBB_SDIMG=$(mktemp)
ORIGINAL_BBB_EXT3=$(mktemp)
VEXPRESS_SDIMG=$(mktemp)
VEXPRESS_EXT3=$(mktemp)

BUILD_DIR="$WORKSPACE/build/tmp/deploy/images"
cp $BUILD_DIR/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.sdimg $VEXPRESS_SDIMG
cp $BUILD_DIR/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.ext3  $VEXPRESS_EXT3
cp $BUILD_DIR/beaglebone/core-image-base-beaglebone.sdimg $ORIGINAL_BBB_SDIMG
cp $BUILD_DIR/beaglebone/core-image-base-beaglebone.ext3 $ORIGINAL_BBB_EXT3

e2rm $BUILD_DIR/beaglebone/core-image-base-beaglebone.ext3:/lib/systemd/system/mender.service
e2rm $BUILD_DIR/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.ext3:/lib/systemd/system/mender.service

PART_OFFSET_VEXPRESS=$(sudo fdisk -l $BUILD_DIR/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.sdimg | grep core-image-full-cmdline-vexpress-qemu.sdimg2 | awk '{sum = $2 * 512; print sum}')
PART_OFFSET_BBB=$(sudo fdisk -l $BUILD_DIR/beaglebone/core-image-base-beaglebone.sdimg | grep core-image-base-beaglebone.sdimg2 | awk '{sum = $2 * 512; print sum}')

sudo mkdir -p /mnt/loop1 >/dev/null
sudo mkdir -p /mnt/loop2 >/dev/null

sudo mount -t ext3 -o loop,offset=${PART_OFFSET_VEXPRESS} ${BUILD_DIR}/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.sdimg /mnt/loop1/
sudo rm /mnt/loop1/lib/systemd/system/mender.service

sudo mount -t ext3 -o loop,offset=${PART_OFFSET_BBB} ${BUILD_DIR}/beaglebone/core-image-base-beaglebone.sdimg /mnt/loop2/
sudo rm /mnt/loop2/lib/systemd/system/mender.service

sudo umount /mnt/loop1
sudo umount /mnt/loop2

cp $WORKSPACE/build/tmp/deploy/images/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.ext3 image.dat


py.test && bash prepare_bbb_testing.sh || { 
    rm {$VEXPRESS_SDIMG,$VEXPRESS_EXT3,$ORIGINAL_BBB_SDIMG,$ORIGINAL_BBB_EXT3};
    exit 1;
}

cp $VEXPRESS_SDIMG $BUILD_DIR/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.sdimg
cp $VEXPRESS_EXT3 $BUILD_DIR/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.ext3
cp $ORIGINAL_BBB_SDIMG $BUILD_DIR/beaglebone/core-image-base-beaglebone.sdimg
cp $ORIGINAL_BBB_EXT3 $BUILD_DIR/beaglebone/core-image-base-beaglebone.ext3

rm {$VEXPRESS_SDIMG,$VEXPRESS_EXT3,$ORIGINAL_BBB_SDIMG,$ORIGINAL_BBB_EXT3}
