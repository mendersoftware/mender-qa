# How to add a platform

This guide describes how to add a new platform to Jenkins, such as for example
"mender_qemux86_64_bios_grub".


## jenkins-yoctobuild-build.sh script

First the platform needs to be added to the build script as a new build
configuration. This is done in the `jenkins-yoctobuild-build.sh` script which is
in the `scripts` folder in this repository. The section looks more or less like
this:

```
# Arguments: Machine name, board name and image name.
add_to_build_list      qemux86-64                qemux86-64-uefi-grub           core-image-full-cmdline
add_to_build_list      vexpress-qemu             vexpress-qemu                  core-image-full-cmdline
add_to_build_list      vexpress-qemu-flash       vexpress-qemu-flash            core-image-minimal
add_to_build_list      $beaglebone_machine_name  beagleboneblack                core-image-base
add_to_build_list      raspberrypi3              raspberrypi3                   core-image-full-cmdline
```

Board name is the most important one as it is the name of the new configuration,
which can be anything, but should reflect what the configuration is, and be
unique.


## Build configuration

Each board needs a build configuration in the `meta-mender` layer, which
includes the Yocto configuration files for that type of build. Here is an
example of such a directory:

```
$ ls meta-mender/tests/build-conf/qemux86-64-bios-grub/
bblayers.conf  local.conf  templateconf.cfg
```

To add a new one, clone the contents of an existing directory into a new
directory with the same name as the board name in the previously mentioned
script, and make the necessary modifications to the Yocto files.


## CI configuration

The GitLab pipeline is defined in the `.gitlab-ci.yml` file. There are several
parts of this file that need modifications when adding a platform.

### Variables

First you need to add the build parameters for the new platform, which allows
the building and testing of the platform to be turned on and off. This consists
of the two prefixes `BUILD_` and `TEST_`, followed by an uppercase version of
the board name that was added in the `jenkins-yoctobuild-build.sh` script.

For example:
```
variables:
  (...)
  BUILD_QEMUX86_64_UEFI_GRUB: "true"
  TEST_QEMUX86_64_UEFI_GRUB: "true"
```
### Pipeline job: Build and test

Next add a new build and test job for this platform. These jobs all
extend `build_and_test_acceptance`. Take one of them as a base, for
example `test:acceptance:qemux86_64:uefi_grub`, and modify it for the new
platform (namely: search and replace on `qemux86_64:uefi_grub`).

### Pipeline job: Publish acceptance tests coverage reports

Similarly, add a job that extends `.template_publish_acceptance_coverage` to
publish acceptance tests coverage. Use `publish_accep_qemux86_64_uefi_grub`
as an example.

### Pipeline job: Publish release artifacts

Modify `release_board_artifacts` job adding the new platform in the `dependencies`
and in the main loop for the `script` part.

## integration-test-runner

integration-test-runner is the program we currently use to automatically trigger
Jenkins jobs when Github pull requests are created or updated.

1. Change the script in a similar fashion as done in [this
commit](https://github.com/mendersoftware/integration-test-runner/commit/8e01cb8595bb0e56fbdb1b4416c603134f554402)

2. Compile the program locally

3. Log in to our VM using SSH

4. Run `systemctl stop integration-test-runner`

5. Upload the compiled binary to the root home folder

6. Run `systemctl start integration-test-runner`

7. (Check that it works)

## Mender codecov configuration

Update `after_n_builds` in the [codecov settings](https://github.com/mendersoftware/mender/blob/master/codecov.yml)
for mender client repo to expect the updated number of reports (one report per
tested platform)

# The end!
