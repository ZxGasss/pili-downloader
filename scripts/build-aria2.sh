#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p work/deps work/licenses
tar -xf ThirdParty/aria2-1.37.0.tar.xz -C work
cd work/aria2-1.37.0
./configure --prefix="$PWD/../aria-install" --with-appletls --without-openssl --without-gnutls --without-libssh2 --without-libcares --without-sqlite3 --without-libxml2 --without-libexpat --disable-bittorrent --disable-metalink --disable-websocket --disable-nls --disable-dependency-tracking
make -j8
cp src/aria2c ../deps/aria2c
cp COPYING ../licenses/aria2-COPYING.txt
