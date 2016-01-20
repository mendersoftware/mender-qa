# CONFIGURATION START - YOU CAN (SHOULD) OVERRIDE THE DEFAULT VALUES

SDIMG_SIZE_MB ?= "1000"
SDIMG_PARTITION_ALIGNMENT_MB ?= "8"
SDIMG_PART1_SIZE_MB ?= "128"

# CONFIGURATION END


IMAGE_TYPEDEP_sdimg = "ext3"

IMAGE_DEPENDS_sdimg = " mtools-native"

IMAGE_CMD_sdimg () {

    set -x                                      # debug output
    set -e                                      # exit on error
    set -u                                      # exit on unset variable
    # Needs bash, TODO can I require that this runs under bash?
    # set -o pipefail                             # don't hide pipeline errors

    cd ${DEPLOY_DIR_IMAGE}
    # Assert rootfs has been correctly generated
    test -e  ${IMAGE_NAME}.rootfs.ext3
    SDIMG=${IMAGE_NAME}.rootfs.sdimg
    rm -f ${SDIMG}

    # fdisk and mkfs are not in the common path
    PATH=$PATH:/sbin:/usr/sbin


    # Compute partition borders and sizes, EVERYTHING IN SECTORS (512 bytes)

    SDIMG_SIZE_SECTORS=$(expr ${SDIMG_SIZE_MB} \* 2048)
    PART1_SIZE=$(expr ${SDIMG_PART1_SIZE_MB} \* 2048)

    ALIGNMENT=$(expr ${SDIMG_PARTITION_ALIGNMENT_MB} \* 2048)
    PART1_START=${ALIGNMENT}
    PART1_END=$(expr ${PART1_START} + ${PART1_SIZE} - 1)
    PART2_START=$(expr \( 1 + ${PART1_END} / ${ALIGNMENT} \) \* ${ALIGNMENT})
    PART23_SIZE_UNALIGNED=$(expr \( ${SDIMG_SIZE_SECTORS} - ${PART2_START} \) / 2)
    PART23_SIZE=$(expr ${PART23_SIZE_UNALIGNED} - ${PART23_SIZE_UNALIGNED} % ${ALIGNMENT})
    PART2_END=$(expr ${PART2_START} + ${PART23_SIZE} - 1)
    PART3_START=$(expr \( 1 + ${PART2_END} / ${ALIGNMENT} \) \* ${ALIGNMENT})
    PART3_END=$(expr ${PART3_START} + ${PART23_SIZE} - 1)

    # Assert we are not past the limits of the SD card size
    test ${PART3_END} -lt ${SDIMG_SIZE_SECTORS}

    # Assert that the rootfs size is smaller than PART23_SIZE
    ROOTFS_SIZE=$(wc -c ${IMAGE_NAME}.rootfs.ext3 | cut -d\  -f1 )
    test ${ROOTFS_SIZE} -lt $(expr ${PART23_SIZE} \* 512)

    dd if=/dev/zero of=${SDIMG} count=0 seek=${SDIMG_SIZE_SECTORS}
    export PART1_START PART1_END PART2_START PART2_END PART3_START PART3_END
    (
        # Create DOS partition table
        echo o
        # 1st partition (FAT32)
        echo n
        echo p
        echo 1
        echo ${PART1_START}
        echo ${PART1_END}
        # 2nd partition (1st rootfs)
        echo n
        echo p
        echo 2
        echo ${PART2_START}
        echo ${PART2_END}
        # 3rd partition (2nd root)
        echo n
        echo p
        echo 3
        echo ${PART3_START}
        echo ${PART3_END}
        # 1st partition: bootable
        echo a
        echo 1
        # 1st partition: type W95 FAT16 (LBA)
        echo t
        echo 1
        echo e
        # 2nd partition: type Linux
        echo t
        echo 2
        echo 83
        # 3rd partition: type Linux
        echo t
        echo 3
        echo 83
        # COMMIT changes to image file
        echo p
        echo w

    ) | fdisk --compatibility=nondos --units=sectors ${SDIMG}

    dd if=/dev/zero of=fat.dat count=${PART1_SIZE}
    mkfs.vfat fat.dat

    # Create empty environment. Just so that the file is available.
    dd if=/dev/zero of=uboot.env count=0 bs=1K seek=256
    mcopy -i fat.dat -v uboot.env ::
    rm -f uboot.env
    
    dd if=fat.dat of=${SDIMG} seek=${PART1_START} conv=notrunc
    rm -f fat.dat

    dd if=${IMAGE_NAME}.rootfs.ext3 of=${SDIMG} seek=${PART2_START} conv=notrunc
    dd if=${IMAGE_NAME}.rootfs.ext3 of=${SDIMG} seek=${PART3_START} conv=notrunc

    # Print partition table, assert partitions are aligned and as expected
    #TODO
}
