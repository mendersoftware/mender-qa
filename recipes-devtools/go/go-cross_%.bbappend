GOLANG_CC_FOR_TARGET="${TARGET_SYS}-gcc --sysroot=${STAGING_DIR_TARGET} ${TARGET_CC_ARCH}"
GOLANG_CXX_FOR_TARGET="${TARGET_SYS}-g++ --sysroot=${STAGING_DIR_TARGET} ${TARGET_CC_ARCH}"
GOLANG_GOROOT_FINAL="${SYSROOT}${libdir}/go"
GOLANG_GOHOSTOS="linux"
GOLANG_GOOS="linux"
GOLANG_GOARCH="${TARGET_ARCH}"
GOLANG_CGO_ENABLED="1"
GOLANG_CC="${BUILD_CC}"
GOLANG_GO_CCFLAGS="${HOST_CFLAGS}"
GOLANG_GO_LDFLAGS="${HOST_LDFLAGS}"

do_compile() {

  export CC_FOR_TARGET="${GOLANG_CC_FOR_TARGET}"
  export CXX_FOR_TARGET="${GOLANG_CXX_FOR_TARGET}"
  export GOROOT_FINAL="${GOLANG_GOROOT_FINAL}"
  export GOHOSTOS="${GOLANG_GOHOST}"
  export GOOS="${GOLANG_GOOS}"
  export GOARCH="${GOLANG_GOARCH}"
  export CGO_ENABLED="${GOLANG_CGO_ENABLED}"
  export CC="${GOLANG_CC}"
  export GO_CCFLAGS="${GOLANG_GO_CCFLAGS}"
  export GO_LDFLAGS="${GOLANG_GO_LDFLAGS}"


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
