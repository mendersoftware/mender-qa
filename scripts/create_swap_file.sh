#!/usr/bin/env bash
# bash is needed in order to use the "time" built-in and avoid needing
# an external utility.

set -e                                                   # exit on error

# Argument $1 is the size in megabytes
if [ x"$1" = x ]  ||  echo "$1" | grep -q '[^0-9]'
then
    exit 2
fi
SIZE="$1"

# Don't overwrite if file exists
[ -f /swapfile ] && exit 1

time dd if=/dev/zero of=/swapfile bs=1M count=$SIZE
chmod 0600 /swapfile
mkswap /swapfile
swapon /swapfile
