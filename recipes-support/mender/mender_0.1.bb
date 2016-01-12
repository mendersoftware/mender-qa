require go-cross.inc

#Please fill USERNAME, PASSWORD and LAST_REVISION below.

SRC_URI = "git://github.com/mendersoftware/mender;branch=master;protocol=https;user=<USERNAME>:<PASSWORD>"
SRCREV = "<LAST_REVISION>"

do_compile() {
  go build -o mender
}

do_install() {
  install -d "${D}/${bindir}"
  install -m 0755 "${S}/mender" "${D}/${bindir}"
}
