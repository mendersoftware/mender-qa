export CC_FOR_TARGET="${TARGET_SYS}-gcc --sysroot=${STAGING_DIR_TARGET} ${TARGET_CC_ARCH}"
export CXX_FOR_TARGET="${TARGET_SYS}-g++ --sysroot=${STAGING_DIR_TARGET} ${TARGET_CC_ARCH}"
export GOROOT_FINAL="${SYSROOT}${libdir}/go"
export GOHOSTOS="linux"
export GOOS="linux"
export GOARCH="${TARGET_ARCH}"
export CGO_ENABLED="1"
export CC="${BUILD_CC}"
export GO_CCFLAGS="${HOST_CFLAGS}"
export GO_LDFLAGS="${HOST_LDFLAGS}"

do_compile() {

  export CC_FOR_TARGET="${CC_FOR_TARGET}"
  export CXX_FOR_TARGET="${CXX_FOR_TARGET}"
  export GOROOT_FINAL="${GOROOT_FINAL}"
  export GOHOSTOS="${GOHOST}"
  export GOOS="${GOOS}"
  export GOARCH="${GOARCH}"
  export CGO_ENABLED="${CGO_ENABLED}"
  export CC="${CC}"
  export GO_CCFLAGS="${GO_CCFLAGS}"
  export GO_LDFLAGS="${GO_LDFLAGS}"


  if [ "${TARGET_ARCH}" = "x86_64" ]; then
    export GOARCH="amd64"
  fi
  if [ "${TARGET_ARCH}" = "arm" ]
  then
    if [ `echo ${TUNE_PKGARCH} | cut -c 1-7` = "cortexa" ]
    then
      echo GOARM 7
      export GOARM="7"
    fi
  fi

  cd src && sh -x ./make.bash
}
