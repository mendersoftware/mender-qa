# Mender QA test suites overview

This document gives an overview of all the different tests suites that we have
in Mender

## Introduction: test levels

At Mender we have different test suites that follow the Development Lifecycle,
verifying our software at different levels through the different phases of the
Development Lifecycle.

Due to our microservices architecture, we name our test suites in a different
way than standards defined by ISTQB (International Software Testing
Qualifications Board) or other online references. See [ISTQB Foundation Level
Syllabus](https://www.istqb.org/downloads/syllabi/foundation-level-syllabus.html).

Nevertheless, we follow QA best practices and principles in verifying our
software product and its individual components at different levels.

## Introduction: programming languages

Except for the GUI and some client addons in C, the core components of Mender
are written in Go.

The unit-level tests are written in the same programming language as the code
itself (usually Go), while for every other test suite we use the Python
programming language and [Pytest](https://docs.pytest.org) framework.

The GUI is tested using [Jest](https://jestjs.io/) for unit tests and
[Cypress](https://www.cypress.io) for E2E tests.

## Unit tests

Test suite       | unit tests
---------------- | ----------
ISTQB equivalent | Component testing
Test object      | The code inside a single repository
Source code      | Repository specific, all `*_test.go` files
How to run       | `go test ./...`
Dependencies     | Some repositories (namely, backend services) require MongoDB server

This is the lowest test level, where the code is closely inspected to exercise
it in as many circumstances as possible. We collect coverage statistics that are
published on each repository's GitHub page.

## Backend acceptance tests

Test suite       | backend acceptance tests
---------------- | ----------
ISTQB equivalent | Component integration testing
Test object      | Interfaces of a single repository
Source code      | Repository specific, `tests/` directory
How to run       | See [mendertesting template](https://github.com/mendersoftware/mendertesting/blob/master/.gitlab-ci-check-docker-acceptance.yml) and [integration wrapper](https://github.com/mendersoftware/integration/blob/master/extra/travis-testing/run-test-environment) (example below)
Dependencies     | Docker, docker-compose

These test suites focus on the interactions between integrated components or, in
our microservices architecture, services, and their interfaces.

### Running locally

Acceptance tests are run in a separate container within the same network as the
service under test and other services when required. Each repository has a
Docker compose file (usually named `docker-compose-acceptance.yml`) describing
other services, networks, and aliases that are required to run the tests.

This separate container for the tests is built independently for all
repositories in
[mender-test-containers](https://github.com/mendersoftware/mender-test-containers/tree/master/backend-acceptance-testing)
and published to Docker Hub as
`mendersoftware/mender-test-containers:acceptance-testing`.

To run the tests, we use the [run-test-environment wrapper from the integration
repository](https://github.com/mendersoftware/integration/blob/master/extra/travis-testing/run-test-environment).

An example of running backend acceptance tests for `deviceauth` service follows

```
# Build the tester
docker build -f Dockerfile.acceptance-testing -t mendersoftware/deviceauth:prtest .
# Get wrapper
git clone --depth=1 https://github.com/mendersoftware/integration.git mender-integration
cp mender-integration/extra/travis-testing/* tests/
# Copy swagger specs
cp docs/* tests/
# Build and copy the binary
go build
cp deviceauth tests/
# Get and copy mender-artifact
wget https://downloads.mender.io/mender-artifact/master/linux/mender-artifact
chmod +x mender-artifact
cp mender-artifact tests/
# Run the tests!
TESTS_DIR=$(pwd)/tests $(pwd)/tests/run-test-environment acceptance $(pwd)/mender-integration $(pwd)/tests/docker-compose-acceptance.yml
```

## client acceptance tests

Test suite       | client acceptance tests
---------------- | ----------
ISTQB equivalent | Component integration testing for meta-mender
Test object      | meta-mender Yocto layer(s) build options
Source code      | [meta-mender](https://github.com/mendersoftware/meta-mender/tree/master/tests/acceptance) and [mender-image-tests](https://github.com/mendersoftware/mender-image-tests/tree/master/tests) repositories
How to run       | `python3 -m pytest` (see below)
Dependencies     | Yocto environment (sourced) with `meta-mender-ci` layer, Python 3, several [Python packages](https://github.com/mendersoftware/meta-mender/blob/master/tests/acceptance/requirements_py3.txt)

This test suite verifies different configuration options, image features and
build scenarios for Mender's meta-mender Yocto layer(s). The available tests are
repeated for a variety of configurations (see below) and the tests include both
static and runtime checks.

The list of tested platforms can be found in [meta-mender
repository](https://github.com/mendersoftware/meta-mender/tree/master/tests/build-conf).
A "platform", in this context is a combination of CPU architecture (x86, ARM),
bootloader integration (UEFI Grub, U-Boot, BIOS) and a file system (ext4,
ubifs). Following is a list of the current platforms under test:

* qemux86-64-uefi-grub
* vexpress-qemu
* vexpress-qemu-flash
* raspberrypi3
* raspberrypi4
* beagleboneblack
* qemux86-64-bios-grub-gpt
* qemux86-64-bios-grub
* vexpress-qemu-uboot-uefi-grub

### Running locally

A full Yocto environment (and at least one previously build image) is required
to execute the tests. A complete recipe of how we build and test this on CI can
be found at [mender-qa
repository](https://github.com/mendersoftware/mender-qa/blob/master/scripts/yocto-build-and-test.sh).

The following recipe gives an example of how to build and test the
`qemux86-64-uefi-grub` platform.

Clone repositories and create the build directory:
```
git clone -b scarthgap https://github.com/mendersoftware/meta-mender.git
git clone -b scarthgap https://git.yoctoproject.org/poky
git clone -b scarthgap https://git.openembedded.org/meta-openembedded
mkdir -p build/conf
```
Replace `scarthgap` with the Yocto series you want to use. As of now, Meta-mender
supports `scarthgap` as the latest LTS version.

Copy `.conf` files to the build directory:
```
cp meta-mender/tests/build-conf/qemux86-64-uefi-grub/* build/conf/
```

Adjust file paths in the `bblayers.conf` (assumes you are at your project's root 
directory, eg `yocto-project/`):
```
CURRENT_DIR=$(pwd)
sed -i "s|@WORKSPACE@|$CURRENT_DIR|g" build/conf/bblayers.conf
sed -i "s#\(^.*${CURRENT_DIR}\/\)\(meta\|meta-poky\|meta-yocto-bsp\)\(\s\|$\)#\1poky/\2\3#g" build/conf/bblayers.conf
```

#### Configure Yocto caches (recommended)

- `DL_DIR` (Download Directory): Stores source code tarballs, git repositories, 
and other previously downloaded files.
- `SSTATE_DIR` (Shared State Directory): Stores pre-built components and 
intermediate build artifacts.

Create the cache directories:
```
mkdir -p build/downloads build/sstate-cache
```

Add cache configuration to `local.conf`:
```
cat >> build/conf/local.conf <<EOF
# Cache
DL_DIR ?= "\${TOPDIR}/downloads"
SSTATE_DIR ?= "\${TOPDIR}/sstate-cache"
EOF
```

Note that the cache can grow quite large (several GB).

Set artifact name:
```
cat >> build/conf/local.conf <<EOF
MENDER_ARTIFACT_NAME = "mender-image-local"
EOF
```

Initialize a new Yocto build environment:
```
source poky/oe-init-build-env build
```

Check you have all layers:
```
bitbake-layers show-layers
```

You should see something like this:
```
NOTE: Starting bitbake server...
layer                 path                                                                    priority
========================================================================================================
core                  /home/ubuntu/yocto-project/poky/meta                                      5
yocto                 /home/ubuntu/yocto-project/poky/meta-poky                                 5
yoctobsp              /home/ubuntu/yocto-project/poky/meta-yocto-bsp                            5
mender                /home/ubuntu/yocto-project/meta-mender/meta-mender-core                   6
mender-demo           /home/ubuntu/yocto-project/meta-mender/meta-mender-demo                   10
openembedded-layer    /home/ubuntu/yocto-project/meta-openembedded/meta-oe                      5
meta-python           /home/ubuntu/yocto-project/meta-openembedded/meta-python                  5
mender-qemu           /home/ubuntu/yocto-project/meta-mender/meta-mender-qemu                   6
```

Build the image:
```
bitbake core-image-full-cmdline
```

This may run for a while, especially if you are doing this for the first time.

You will find the build artifacts under `build/tmp/deploy/images`

Run the tests! (Note that you might need to adjust the file paths to match
your local setup)

```
cd meta-mender/tests/acceptance/
python3 -m pytest -p no:xdist --bitbake-image core-image-full-cmdline --board-type=qemux86-64
```

Or run the image in QEMU manually:
```
qemu-system-x86_64 \
  -drive if=pflash,format=qcow2,readonly=on,file=ovmf.code.qcow2 \
  -drive if=pflash,format=qcow2,file=ovmf.vars.qcow2 \
  -drive file=core-image-full-cmdline-qemux86-64.uefiimg,format=raw \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  -m 2048 \
  -enable-kvm \
  -nographic
```

## Backend tests

Test suite       | backend integration tests
---------------- | ----------
ISTQB equivalent | System integration testing and server-only Acceptance testing
Test object      | The Mender backend server, as a whole
Source code      | [integration/backend-tests](https://github.com/mendersoftware/integration/tree/master/backend-tests)
How to run       | [`./run`](https://github.com/mendersoftware/integration/blob/master/backend-tests/run)
Dependencies     | Docker, docker-compose, [mender-artifact](https://github.com/mendersoftware/mender-artifact)

This test suite verifies the interfaces and behavior of a stand-alone Mender
server installation as a whole. A real client is not used, and instead API calls
to the different endpoints simulates Mender clients connecting to the Mender
server.

Refer to the
[README](https://github.com/mendersoftware/integration/tree/master/backend-tests)
for more details of this test suite.

## Integration tests

Test suite       | integration tests
---------------- | ----------
ISTQB equivalent | System testing and Acceptance testing
Test object      | The Mender product, as a whole, excluding GUI
Source code      | [integration/tests](https://github.com/mendersoftware/integration/tree/master/tests)
How to run       | [`./run.sh`](https://github.com/mendersoftware/integration/blob/master/tests/run.sh)
Dependencies     | Docker, docker-compose, Python 3, [Python packages](https://github.com/mendersoftware/integration/blob/master/tests/requirements-python/python-requirements.txt)

The integration test suite verifies Mender as a product, including both the
server and the client, but excluding the GUI. Different scenarios and
configurations are taken into consideration covering both functional and
non-functional testing.

Refer to the
[README](https://github.com/mendersoftware/integration/tree/master/tests) for
more details of this test suite.

## E2E tests

Test suite       | e2e tests
---------------- | ----------
ISTQB equivalent | System testing and Acceptance testing
Test object      | The Mender product, as a whole, excluding the client
Source code      | [gui/tests/e2e_tests](https://github.com/mendersoftware/gui/tree/master/tests/e2e_tests)
How to run       | [see e2e-test stage](https://github.com/mendersoftware/gui/blob/master/.gitlab-ci.yml)
Dependencies     | Docker, docker-compose, [mender-demo-artifact](https://github.com/mendersoftware/mender-demo-artifact), [mender-stress-test-client](https://github.com/mendersoftware/mender-stress-test-client)

The End to End tests (E2E) verify also Mender as a product, including the GUI.
The client interactions are simulated using the
[mender-stress-test-client](https://github.com/mendersoftware/mender-stress-test-client),
while the backend interactions are carried on through the GUI, the same way a
human would do it when using the product.

### Running locally

The e2e tests are run in a separate container within the same network as the
service under test and other services when required. The GUI repository has a
Docker compose file (usually named `docker-compose-acceptance.yml`) describing
other services, networks, and aliases that are required to run the tests.

An example of running the OS tests from the `GUI` follows:

´´´
docker build -t mendersoftware/gui:pr .
wget -qP tests/e2e_tests/cypress/fixtures "https://dgsbl4vditpls.cloudfront.net/mender-demo-artifact.mender"
git clone --single-branch https://github.com/mendersoftware/integration.git
GUI_REPOSITORY=$(pwd) INTEGRATION_PATH=$(pwd)/integration ./tests/e2e_tests/run
´´´

## mender-convert acceptance tests

Test suite       | mender-convert acceptance tests
---------------- | ----------
ISTQB equivalent | Acceptance testing
Test object      | mender-convert tool, independently
Source code      | [mender-image-tests](https://github.com/mendersoftware/mender-image-tests/tree/master/tests) repository and [run-tests.sh](https://github.com/mendersoftware/mender-convert/blob/master/scripts/test/run-tests.sh) wrapper.
How to run       | [`./scripts/test/run-tests.sh`](https://github.com/mendersoftware/mender-convert/blob/master/scripts/test/run-tests.sh)
Dependencies     | OS image converted with `mender-convert`

We consider `mender-convert` tool independent of the Mender core product. This
test suite runs a set of tests to verify the contents and correctness of the
device images produced by the tool.

### Running locally

TODO

## Other minor acceptance test suites

### mender-docs

Yes, we also test our docs! On selected docs pages, we verify that the user
instructions can run as a script and their output and behavior are congruent.
See the [test
runner](https://github.com/mendersoftware/mender-docs/blob/master/test_docs.py)
and [an
example](https://raw.githubusercontent.com/mendersoftware/mender-docs/master/07.Server-installation/03.Production-installation/docs.md)
of a doc page with tests.

### mender-dist-packages

Set of acceptance tests for the different Mender Debian packages.

See tests at [mender-dist-packages
repo](https://github.com/mendersoftware/mender-dist-packages/tree/master/tests).

### mender-demo-artifact

Set of acceptance tests for the
[mender-demo-artifact](https://github.com/mendersoftware/mender-demo-artifact/)
use for onboarding new users.

See tests at
[mender-demo-artifact](https://github.com/mendersoftware/mender-demo-artifact/tree/master/tests)
repo.
