#!/bin/sh
# Reproducible isolated OpenOCD build with optional-autoexec fallback.
# SPDX-License-Identifier: BSD-3-Clause
set -eu
cd "$(dirname "$0")/.."
rev=cb0c224e936091156ecf3025ba05657408ed64c8
openocd_source=${OPENOCD_SRC:-"$HOME/rv/src/openocd"}
out=${1:-_build/dbg/openocd}
patch_file=$(pwd)/dbg/openocd-no-autoexec.patch
patch_hash=$(sha256sum "$patch_file" | cut -d ' ' -f1)
mkdir -p "$out"
out=$(cd "$out" && pwd)
exec 9>"$out/.build.lock"
flock 9
stamp="$rev $patch_hash"
if [ -f "$out/source.stamp" ] && [ "$(cat "$out/source.stamp")" != "$stamp" ] &&
   [ "$(cut -d ' ' -f1 "$out/source.stamp")" = "$rev" ] && [ -f "$out/applied.patch" ]; then
    (cd "$out/source" && patch -R -p1 < "$out/applied.patch" && patch -p1 < "$patch_file")
    cp "$patch_file" "$out/applied.patch"
    printf '%s\n' "$stamp" > "$out/source.stamp"
elif [ ! -f "$out/source.stamp" ] || [ "$(cat "$out/source.stamp")" != "$stamp" ]; then
    # These paths contain only this script's generated source/build outputs.
    rm -rf "$out/source" "$out/build" "$out/install"
    mkdir -p "$out/source" "$out/build"
    git -C "$openocd_source" archive "$rev" | tar -xf - -C "$out/source"
    (cd "$out/source" && patch -p1 < "$patch_file")
    cp "$patch_file" "$out/applied.patch"
    # Treat the exported tree as a release archive: upstream guess-rev.sh
    # refreshes a Git index. It must never discover the enclosing Karu repo.
    rm "$out/source/guess-rev.sh"
    sed -i 's/\[0.12.0+dev\]/[0.12.0+dev-karudbg-fallback]/' "$out/source/configure.ac"
    printf '%s\n' "$stamp" > "$out/source.stamp"
fi
export GIT_CEILING_DIRECTORIES="$out"
if [ ! -x "$out/source/configure" ]; then
    (cd "$out/source" && ./bootstrap nosubmodule) > "$out/bootstrap.log" 2>&1
fi
if [ ! -f "$out/build/Makefile" ]; then
    (cd "$out/build" && ../source/configure --prefix="$out/install" \
        --enable-remote-bitbang --enable-jtag_vpi --enable-jtag_dpi \
        --disable-internal-jimtcl) > "$out/configure.log" 2>&1
fi
make -C "$out/build" -j "${DBG_JOBS:-8}" > "$out/build.log" 2>&1
make -C "$out/build" install > "$out/install.log" 2>&1
{
    printf 'OpenOCD source: %s\nPatch SHA256: %s\n' "$rev" "$patch_hash"
    "$out/install/bin/openocd" --version 2>&1
    sha256sum "$out/install/bin/openocd"
} > "$out/manifest.txt"
cat "$out/manifest.txt"
