# meta-mender-qemu

This document describes the required steps to build a Yocto image containing fully functional Mender software and all needed partitioning and boot configuration.
In this manual we will provide instructions for how to build and test the image in qemu emulator for ```vexpress-qemu``` machine type.

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

In order to build a Yocto image containing Mender software and all required partitioning setup, together with bootloader configuration, you need to first clone latest the Yocto sources from

```
git://git.yoctoproject.org/git/poky
```

Having done that, clone the rest of the needed dependencies into the top-level of your Yocto build tree (usually yocto/poky). All needed dependencies are provided in 'Dependencies' section above. At the moment all needed Yocto layers for building complete image are:

```
git://github.com/mendersoftware/meta-mender
git://github.com/mendersoftware/meta-mender-qemu
git://github.com/mem/oe-meta-go
```

Assuming that you added needed dependencies at the top of your build tree, you can build the image by adding the location of meta-mender, meta-mender-qemu and oe-meta-go layers to bblayers.conf.

In order to do so, first create the build directory for Yocto and set build environment:

```
    $ source oe-init-build-env
```

This should create the needed build environment and build directory where you should be automatically redirected. We are assuming in this manual that the name of the build directory is ```build```.


2. Yocto build configuration
============================

In order to support building Mender the following changes are needed in ```conf/local.conf``` file:

```
    MACHINE ??= "vexpress-qemu"
```

You will also need to configure all the layers you are using for building the image.
In order to do so, edit conf/bblayers.conf file and make sure that the BBLAYERS look as following:

```
    BBLAYERS ?= " \
      /home/a10053/yocto/poky/meta \
      /home/a10053/yocto/poky/meta-yocto \
      /home/a10053/yocto/poky/meta-yocto-bsp \
      /home/a10053/yocto/poky/meta-mender-qemu \
      /home/a10053/yocto/poky/meta-mender \
      /home/a10053/yocto/poky/oe-meta-go \
      "
```


3. Image building
=================

Once all the configuration steps are done, you should be able to build the image as such:

```
    $ bitbake core-image-full-cmdline
```

This will build core-image-full-cmdline image type. It is possible to build other image types, but for simplicity of this document we will provide instructions assuming that core-image-full-cmdline is selected type.

At the end of a successful build you should have an image you can test using quemu emulator.
The images and build artifacts should be placed in ```tmp/deploy/images/vexpress-qemu/``` directory. Among the others you should see ```core-image-full-cmdline-vexpress-qemu.sdimg``` (we are assuming that you have built ```core-image-full-cmdline``` image type) which is a partitioned image containing bootloader partition and two partitions containing kernel and rootfs each.
This image will be used later to test Mender with Qemu emulator (more on that in the section 'Booting the images with Qemu' below).

For more information about getting started with Yocto it is recommended to read the [Yocto Project Quick Start guide](http://www.yoctoproject.org/docs/2.0/yocto-project-qs/yocto-project-qs.html).


4. Booting the images with Qemu
===============================

This layer contains bootable Yocto images, which can be used to boot Mender directly using qemu. In order to simplify the boot process there are qemu boot scripts provided in ```meta-mender-qemu/scripts``` directory. To boot Mender follow the instructions below:

```
    $ cd ../meta-mender-qemu/scripts
    $ ./mender-qemu
```

Above should start qemu and boot Linux kernel and rootfs from active partition.
There should be also an inactive partition available where the update will be stored.

If you want access to u-boot boot loader, you can run the qemu launching script with ```nographic``` option. This will give you access to the boot loader and booting process:

```
    $ ./mender-qemu -nographic
```


5. Testing OTA image update
===========================

In the standard partitioning, there isn't enough space to put the image in a file before flashing it. For the test purposes this can be solved the following way:

Inside qemu create a FIFO:

```
    $ mkfifo image
```

Then on the build host copy the image you want to update to using following command:

```
    $ ssh -p8822 -l root localhost cat \> image < ../../build/tmp/deploy/images/vexpress-qemu/core-image-full-cmdline-vexpress-qemu.ext3
```

We are assuming that above command is run from meta-mender-qemu/scripts directory and the image points to the Yocto build deploy directory where Mender images were built in the previous steps. Please also note that the terminal will hang as ssh will wait for qemu to accept the transferred image.
While the pipe is open on the server side, run Mender inside qemu to start remote update process:

```
    $ mender -rootfs image
```

Note that this command might need several seconds to execute.

Having that done reboot the system:

```
    $ reboot
```

Now the system should boot kernel and corresponding rootfs from the previously inactive partition where the update was copied (after first update it should be 'mmcblk0p3'). Please note that the previously active partition was *mmcblk0p2*.

If the update was successful and verification of new image is done, run:

```
    $ mender -commit
```

to make sure that the current kernel and rootfs pair will become the active one. If change won't be committed after the next reboot, kernel and rootfs will be booted from *previously active
partition* (mmcblk0p2).

This is a mechanism of verifying the update and rolling-back to a previous working version if the new image is broken.


6. Mender overview
==================

For more information of what Mender is and how it works, please see the documentation in the [mender Github repository](https://github.com/mendersoftware/mender) or visit [official Mender website](https://mender.io).



7. Project roadmap
==================

As mentioned, the update process mostly consists of manual steps at the moment. There is ongoing work to make it fully automated so that the image will be delivered to device automatically and the whole update and roll-back process will be automatic.
There is also ongoing work on the server side of the update framework, where you will be able to schedule image updates and get the reports for the update status for each and every device connected to the server.

