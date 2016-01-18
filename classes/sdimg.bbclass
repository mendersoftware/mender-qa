IMAGE_TYPEDEP_sdimg = "ext3.gz"

SDIMG      = "${DEPLOY_DIR_IMAGE}/${IMAGE_NAME}.rootfs.sdimg"

IMAGE_CMD_sdimg () {

    set -x

    test -e  ${DEPLOY_DIR_IMAGE}/${IMAGE_NAME}.rootfs.ext3.gz
    rm -f ${SDIMG}
    rm -f ${SDIMG_LINK}

    # fdisk and mkfs are not in the common path
    PATH=$PATH:/sbin:/usr/sbin

    dd if=/dev/zero of=${SDIMG} bs=1M count=0 seek=300
    fdisk ${SDIMG} <<EOF
o
n
p
1
2048
100000
n
p
2
100001
350000
n
p
3
350001
614399
t
1
c
p
w
EOF

    dd if=/dev/zero of=fat.dat bs=1M count=0 seek=10
    mkfs.vfat fat.dat
    dd if=fat.dat of=${SDIMG} bs=512 seek=2048 conv=notrunc
    rm -f fat.dat

    gzip -dc ${DEPLOY_DIR_IMAGE}/${IMAGE_NAME}.rootfs.ext3.gz | dd of=${SDIMG} bs=512 seek=100001 conv=notrunc
    gzip -dc ${DEPLOY_DIR_IMAGE}/${IMAGE_NAME}.rootfs.ext3.gz | dd of=${SDIMG} bs=512 seek=350001 conv=notrunc
}
