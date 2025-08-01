#!/bin/bash

set -e -x -E

# This script provides functionality to mount and unmount raw disk images
# using Linux loop devices. It's designed to work with partitioned disk images
# and automatically associates the image with an available loop device
#
# USAGE:
#   ./mount-image.sh mount <image_path> <mount_point>
#   ./mount-image.sh umount <mount_point>
#
# EXAMPLES:
#   ./mount-image.sh mount /path/to/disk.img /mnt/myimage
#   ./mount-image.sh umount /mnt/myimage
#
# ASSUMPTIONS:
#   - The script assumes the target partition is always the second partition (p2)
#   - Requires root privileges

# ------------------------------------------------------------------------------
# Associate a raw image with a loop device and mount it.
#
# Arguments:
#   Image path to mount.
#   Mount point directory path.
# Outputs:
#   Info and error messages to STDOUT and STDERR.
# Returns:
#   0 on successful mount, 1 on error.
# ------------------------------------------------------------------------------
mount_image() {
    local IMG_PATH="$1"
    local MOUNT_POINT="$2"

    if [ -z "$IMG_PATH" ] || [ -z "$MOUNT_POINT" ]; then
        echo "Error: Both image path and mount point are required for mounting."
        exit 1
    fi

    echo "Info: Attempting to associate and mount image: $IMG_PATH to $MOUNT_POINT"

    LOOP_DEV=$(losetup --find --partscan --show "$IMG_PATH")

    if [ -z "$LOOP_DEV" ]; then
        echo "Error: Could not find a loop device for $IMG_PATH."
        exit 1
    fi

    mkdir -p "$MOUNT_POINT"

    # NOTE: assuming it's always the second partition
    if ! mount "${LOOP_DEV}p2" "$MOUNT_POINT"; then
        echo "Error: Could not mount ${LOOP_DEV}p2 to $MOUNT_POINT."
        losetup -d "$LOOP_DEV" # clean up if mount fails
        exit 1
    fi

    echo "Info: Image mounted successfully at $MOUNT_POINT using loop device $LOOP_DEV."
}

# ------------------------------------------------------------------------------
# Unmount the image and clean up the associated loop device.
#
# Arguments:
#   Mount point directory path to unmount.
# Outputs:
#   Info, warning, and error messages to STDOUT and STDERR.
# Returns:
#   0 on successful unmount and cleanup, 1 on error.
# ------------------------------------------------------------------------------
umount_image() {
    local MOUNT_POINT="$1"

    if [ -z "$MOUNT_POINT" ]; then
        echo "Error: Mount point is required for umounting."
        exit 1
    fi
    
    LOOP_DEV=$(findmnt -no SOURCE --target "$MOUNT_POINT" 2>/dev/null)

    echo "Info: Attempting to umount image from: $MOUNT_POINT"

    if mountpoint -q "$MOUNT_POINT"; then
        if ! umount "$MOUNT_POINT"; then
            echo "Error: Could not umount $MOUNT_POINT."
            exit 1
        fi
        echo "Info: Image umounted from $MOUNT_POINT"
    else
        echo "Info: $MOUNT_POINT is not mounted."
    fi

    
    # get the base of loop device eg. /dev/loop0 from /dev/loop0p2
    if [ -n "$LOOP_DEV" ]; then
        # NOTE: assumes the partition suffix is always two chars
        LOOP_DEV_TO_DETACH="${LOOP_DEV%%??}"
        echo "Info: Found associated loop device: $LOOP_DEV_TO_DETACH"

        if losetup -a | grep -q "$LOOP_DEV_TO_DETACH"; then # check if active
            if ! losetup -d "$LOOP_DEV_TO_DETACH"; then
                echo "Error: Could not detach $LOOP_DEV_TO_DETACH."
                exit 1
            fi
            echo "Info: $LOOP_DEV_TO_DETACH detached."
        else
            echo "Info: $LOOP_DEV_TO_DETACH is not active or already detached."
        fi
    else
        echo "Warning: Could not determine the specific loop device for $MOUNT_POINT"
        echo "Tried $LOOP_DEV Falling back to /dev/loop0"
        if losetup -a | grep -q "/dev/loop0"; then
            if ! losetup -d /dev/loop0; then
                echo "Error: Could not detach /dev/loop0."
                exit 1
            fi
            echo "Info: /dev/loop0 detached."
        else
            echo "Info: /dev/loop0 is not active."
        fi
    fi
}

case "$1" in
    mount)
        if [ "$#" -ne 3 ]; then
            echo "Usage for mount: $0 mount <image_path> <mount_point>"
            exit 1
        fi
        mount_image "$2" "$3"
        ;;
    umount)
        if [ "$#" -ne 2 ]; then
            echo "Usage for umount: $0 umount <mount_point>"
            exit 1
        fi
        umount_image "$2"
        ;;
    *)
        echo "Usage: $0 {mount|umount}"
        echo "  mount <image_path> <mount_point>"
        echo "  umount <mount_point>"
        exit 1
        ;;
esac
