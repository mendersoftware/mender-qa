DESCRIPTION = "This is a recipe that cross-compiles a Go program."
HOMEPAGE = "https://golang.org/"

#Taken from oe-meta-go (https://github.com/errordeveloper/oe-meta-go)
DEPENDS = "go-cross"

export GOARCH="${TARGET_ARCH}"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

S = "${WORKDIR}/git"
