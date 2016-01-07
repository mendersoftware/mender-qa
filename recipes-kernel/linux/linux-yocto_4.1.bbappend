# Use custom defconfig in order to enable use of the vexpress model.
FILESEXTRAPATHS_prepend := "${THISDIR}/${PN}:"
SRC_URI += "file://defconfig"
