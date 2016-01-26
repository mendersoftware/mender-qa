# meta-mender-qemu

This document outlines the steps needed to build a Yocto image containing a testable version of `Mender`, including the required partitioning and boot configuration.
The image is built for qemu, in particular it uses the the ```vexpress-qemu``` machine type.

Dependencies
============

This layer depends on:

```
  URI: git://git.yoctoproject.org/poky
  branch: master or jethro

  URI: git://github.com/mendersoftware/meta-mender
  branch: master

  URI: git://github.com/mem/oe-meta-go
  branch: master
```

Table of  contents:
=========
1. Pre-configuration
2. Yocto build configuration
3. Image building
4. Booting the images with Qemu
5. Testing OTA image update
6. Mender overview
7. Project roadmap


1. Pre-configuration
====================

We first need to clone the latest Yocto sources from:

```
git://git.yoctoproject.org/git/poky
```

Having done that, clone the rest of the needed dependencies into the top level of the Yocto build tree (usually yocto/poky). All the required dependencies are provided in the 'Dependencies' section above. At the moment, the needed Yocto layers for building a complete image are:

```
git://github.com/mendersoftware/meta-mender
git://github.com/mendersoftware/meta-mender-qemu
git://github.com/mem/oe-meta-go
```

After cloning these dependencies to the top of the build tree, the image can be built by adding the location of the layers `meta-mender`, `meta-mender-qemu` and `oe-meta-go` to `bblayers.conf`.

In order to do so, first create the build directory for Yocto and set build environment:

```
    $ source oe-init-build-env
```

This should create the build environment and build directory, and running the command should change the current directory to the build directory. In this document, we assume that the name of the build directory is `build`.


2. Yocto build configuration
============================

In order to support building Mender, the following changes are needed in the ```conf/local.conf``` file:

```
    MACHINE ??= "vexpress-qemu"
```

The layers used for building the image need to be included.
In order to do so, edit `conf/bblayers.conf` and make sure that `BBLAYERS` looks like the following:

```
    BBLAYERS ?= " \
      <YOCTO-INSTALL-DIR>/yocto/poky/meta \
      <YOCTO-INSTALL-DIR>/yocto/poky/meta-yocto \
      <YOCTO-INSTALL-DIR>/yocto/poky/meta-yocto-bsp \
      <YOCTO-INSTALL-DIR>/yocto/poky/meta-mender-qemu \
      <YOCTO-INSTALL-DIR>/yocto/poky/meta-mender \
      <YOCTO-INSTALL-DIR>/yocto/poky/oe-meta-go \
      "
```


3. Image building
=================

Once all the configuration steps are done, the image can be built like this:

```
    $ bitbake core-image-full-cmdline
```

This will build the `core-image-full-cmdline` image type. It is possible to build other image types, but for the simplicity of this document we will assume that `core-image-full-cmdline` is the selected type.

At the end of a successful build, the image can be tested in qemu.
The images and build artifacts are placed in `tmp/deploy/images/vexpress-qemu/`. The directory should contain a file named ```core-image-full-cmdline-vexpress-qemu.sdimg```, which is an image that contains a boot partition and two other partitions, each with the kernel and rootfs.
This image will be used later to test Mender with qemu (more on that in the section 'Booting the images with Qemu' below).

For more information about getting started with Yocto, it is recommended to read the [Yocto Project Quick Start guide](http://www.yoctoproject.org/docs/2.0/yocto-project-qs/yocto-project-qs.html).


4. Booting the images with Qemu
===============================

This layer contains bootable Yocto images, which can be used to boot Mender directly using qemu. In order to simplify the boot process there are qemu boot scripts provided in the directory `meta-mender-qemu/scripts`. To boot Mender, follow the instructions below:

```
    $ cd ../meta-mender-qemu/scripts
    $ ./mender-qemu
```

The above should start qemu and boot the kernel and rootfs from the active partition.
There should also be an inactive partition available where the update will be stored.

In order to access the U-Boot bootloader, the qemu-launching script can be run with the ```nographic``` option. This will give access to the bootloader and boot process:

```
    $ ./mender-qemu -nographic
```


5. Testing OTA image update
===========================

In the standard partitioning, there isn't enough space to put the image in a file before flashing it. For the test purposes this can be solved the following way:

Inside qemu create a FIFO (e.g. in /root):

```
    $ mkfifo image
```

On the build host, the image to update to can be copied using the following command:

```
    $ ssh -p8822 -l root localhost cat \> image < ../../build/tmp/deploy/images/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.ext3
```

We are assuming that the above command is run from the directory `meta-mender-qemu/scripts` and `image` points to the Yocto build deploy directory where Mender images were built in the previous steps. Please also note that the terminal will hang as ssh will wait for qemu to accept the transferred image.
While the pipe is open on the server side, run Mender inside qemu to start the remote update process:

```
    $ mender -rootfs image
```

Having that done reboot the system:

```
    $ reboot
```

Now the system should boot the kernel and corresponding rootfs from the previously inactive partition where the update was copied (after first update it should be `mmcblk0p3`). Please note that the previously active partition was `mmcblk0p2`.

If the update was successful and (currently manual) verification of the installation is successful, run:

```
    $ mender -commit
```

This ensures that the current kernel and rootfs pair will become the active. If the change is not committed after the reboot, the kernel and rootfs will be booted from the *previously active partition* (`mmcblk0p2`).

This is a mechanism for verifying the update and rolling-back to a previous working version if the new image is broken.


6. Mender overview
==================

For more information of what Mender is and how it works, please see the documentation in the [mender Github repository](https://github.com/mendersoftware/mender) or visit [the official Mender website](https://mender.io).



7. Project roadmap
==================

The update process currently consists of several manual steps.
There is ongoing development to make it fully automated so that the image will be delivered to a device automatically and the whole update and roll-back process will be automatic.
There is also ongoing work on the server side of Mender, where it will be possible to schedule image updates and get reports for the update status for each and every device connected to the server.
