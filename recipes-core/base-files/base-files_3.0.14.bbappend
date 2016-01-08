FILESEXTRAPATHS_prepend := "${THISDIR}/${PN}:"

do_install_append () {
    install -d ${D}/u-boot
}
