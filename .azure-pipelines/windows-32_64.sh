#!/bin/sh

set -eux -o pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

. "$DIR"/lib.sh

install_host_dmd() {
    download "http://downloads.dlang.org/releases/2.x/2.084.1/dmd.2.084.1.windows.7z" dmd2.7z
    7z x dmd2.7z > /dev/null
    export PATH="$PWD/dmd2/windows/bin/:$PATH"
    export HOST_DC="$PWD/dmd2/windows/bin/dmd.exe"
    export DM_MAKE="$PWD/dmd2/windows/bin/make.exe"
    dmd --version
}

# Clone
clone https://github.com/dlang/druntime "$DMD_DIR/../druntime" master
clone https://github.com/ssoulaimane/phobos "$DMD_DIR/../phobos" win64abi_1

# Prepare
export CC="${MSVC_CC}"
export AR="${MSVC_AR}"

install_host_dmd

cp dmd2/windows/bin64/libcurl.dll ../phobos/
ln -s "$DMD_DIR" ../dmd
DMD_BIN_PATH="$DMD_DIR/generated/windows/release/32/dmd"

# BUILD
## DMD
cd "$DMD_DIR/src"
${DM_MAKE} -f win32.mak dmd
## DRuntime
cd "$DMD_DIR"/../druntime
${DM_MAKE} -f win64.mak auto-tester-build DMD="$DMD_BIN_PATH" CC="$MSVC_CC" AR="$MSVC_AR"
## Phobos
cd "$DMD_DIR"/../phobos
${DM_MAKE} -f win64.mak auto-tester-build DMD="$DMD_BIN_PATH" CC="$MSVC_CC" AR="$MSVC_AR"

# Test
## DMD
cd "$DMD_DIR/test"
gmake -j4 MODEL=64
## Druntime
cd "$DMD_DIR/../druntime"
${DM_MAKE} -f win64.mak auto-tester-test DMD="$DMD_BIN_PATH" CC="$MSVC_CC" AR="$MSVC_AR"
## Phobos
cd "$DMD_DIR/../phobos"
${DM_MAKE} -f win64.mak auto-tester-test DMD="$DMD_BIN_PATH" CC="$MSVC_CC" AR="$MSVC_AR"
