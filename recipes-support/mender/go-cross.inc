DESCRIPTION = "This is a recipe that cross-compiles a Go program."
HOMEPAGE = "https://golang.org/"

#Taken from oe-meta-go (https://github.com/errordeveloper/oe-meta-go)
DEPENDS = "go-cross"

S = "${WORKDIR}/git"
