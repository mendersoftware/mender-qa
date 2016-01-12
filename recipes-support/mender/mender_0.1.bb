require go-cross.inc

#Please fill USERNAME, PASSWORD below.

SRC_URI = "git://github.com/mendersoftware/mender;branch=master;protocol=https;user=<USERNAME>:<PASSWORD>"
SRCREV = "${AUTOREV}"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

do_compile() {
  go build -o mender
}

do_install() {
  install -d "${D}/${bindir}"
  install -m 0755 "${S}/mender" "${D}/${bindir}"
}
