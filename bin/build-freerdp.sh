#!/bin/bash
# Builds vendor/FreeRDP.xcframework: FreeRDP and OpenSSL from pinned source tarballs, static,
# universal (arm64 + x86_64), macOS 14+, with FreeRDP's and OpenSSL's licences in vendor/licenses/.
# Everything it downloads and builds stays under vendor/build/ (git-ignored).
#
#   bin/build-freerdp.sh           build (or: make freerdp)
#   bin/build-freerdp.sh --print   print the pinned versions, URLs and SHA-256s, download nothing
#
# Bumping a pin: edit the version, URL and SHA-256 below (take the SHA-256 from the project's release
# page, never from the downloaded file), then run `make freerdp`; the Makefile rebuilds whenever this
# script changes. A checksum mismatch aborts the build.
#
# A full build takes about 5 minutes (measured 5m 10s and 5m 6s on an M3 Ultra:
# OpenSSL 15 s per architecture, FreeRDP about 140 s per architecture).
set -euo pipefail

FREERDP_VERSION=3.33.0
FREERDP_URL=https://pub.freerdp.com/releases/freerdp-3.33.0.tar.xz
FREERDP_SHA256=9cea38e972e3775e1ce83b30e9ae0cbf8d00af1c708c640e6244fc81bdb1e08b
OPENSSL_VERSION=3.5.9
OPENSSL_URL=https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a

if [ "${1:-}" = --print ]; then
    echo "FreeRDP $FREERDP_VERSION $FREERDP_URL $FREERDP_SHA256"
    echo "OpenSSL $OPENSSL_VERSION $OPENSSL_URL $OPENSSL_SHA256"
    exit 0
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"
WORK="$VENDOR/build"
SRC="$WORK/src"
JOBS="$(sysctl -n hw.ncpu)"
ARCHS="arm64 x86_64"
START=$SECONDS
# Run from make, the parent's jobserver flags would leak into OpenSSL's and CMake's makes.
unset MAKEFLAGS MFLAGS MAKELEVEL
# A deterministic configure: nothing from the build machine's environment reaches the compilers or
# CMake's and pkg-config's searches, which is also how Nix packages would reach it (Homebrew's and
# MacPorts' prefixes are ignored below).
unset CMAKE_PREFIX_PATH CMAKE_INCLUDE_PATH CMAKE_LIBRARY_PATH CMAKE_FRAMEWORK_PATH \
    CFLAGS CXXFLAGS OBJCFLAGS CPPFLAGS LDFLAGS CPATH C_INCLUDE_PATH OBJC_INCLUDE_PATH LIBRARY_PATH \
    PKG_CONFIG_PATH
export PKG_CONFIG_LIBDIR=/var/empty

mkdir -p "$WORK"
cd "$WORK"

# Downloads once, verifies every time; a bad file is deleted so the next run fetches it again.
fetch() { # url sha256 file
    [ -f "$3" ] || { curl -fL --retry 3 -o "$3.part" "$1" && mv "$3.part" "$3"; }
    echo "$2  $3" | shasum -a 256 -c - || { rm -f "$3"; echo "Checksum mismatch for $3: aborting."; exit 1; }
}
fetch "$OPENSSL_URL" "$OPENSSL_SHA256" "openssl-$OPENSSL_VERSION.tar.gz"
fetch "$FREERDP_URL" "$FREERDP_SHA256" "freerdp-$FREERDP_VERSION.tar.xz"

rm -rf "$SRC"
mkdir -p "$SRC"
tar -xzf "openssl-$OPENSSL_VERSION.tar.gz" -C "$SRC"
tar -xJf "freerdp-$FREERDP_VERSION.tar.xz" -C "$SRC"
OPENSSL_SRC="$SRC/openssl-$OPENSSL_VERSION"
FREERDP_SRC="$SRC/freerdp-$FREERDP_VERSION"

for arch in $ARCHS; do
    step=$SECONDS
    rm -rf "openssl-build-$arch" "openssl-$arch"
    mkdir "openssl-build-$arch"
    # no-module builds the legacy provider (MD4 and RC4, which NTLM needs) into libcrypto: as a
    # module it would be a legacy.dylib loaded from this build directory's path at run time.
    # The certificate store is the system's /etc/ssl, whose openssl.cnf (LibreSSL's) isn't loaded.
    (cd "openssl-build-$arch" &&
        "$OPENSSL_SRC/Configure" "darwin64-$arch-cc" no-shared no-tests no-apps no-module \
            no-autoload-config --openssldir=/etc/ssl \
            --prefix="$WORK/openssl-$arch" -mmacosx-version-min=14.0 &&
        make -j"$JOBS" &&
        make install_sw)
    echo "OpenSSL $arch: $((SECONDS - step)) s"
done

for arch in $ARCHS; do
    step=$SECONDS
    rm -rf "freerdp-build-$arch" "freerdp-$arch"
    # Build-machine prefixes are ignored: FreeRDP would otherwise pick up single-architecture
    # dynamic libraries from them (Homebrew's json-c, krb5, libusb, ffmpeg, SDL, OpenSSL).
    # LTO is off: it leaves LLVM bitcode in the archives, which xcodebuild -create-xcframework
    # rejects ("Unknown header: 0xb17c0de").
    # Every library-detected feature is pinned rather than left to what this machine has. JSON
    # above all: with it, FreeRDP reads certificates.json from the sysconfdir, and an entry there
    # can skip certificate verification. The sysconfdir is a root-owned path that doesn't exist,
    # so it's inert even if JSON were ever on.
    cmake -S "$FREERDP_SRC" -B "freerdp-build-$arch" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
        -DCMAKE_INSTALL_PREFIX="$WORK/freerdp-$arch" \
        -DCMAKE_INSTALL_SYSCONFDIR=/etc/xpnd-freerdp \
        -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/opt/local" \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
        -DUSE_VERSION_FROM_GIT_TAG=OFF \
        -DOPENSSL_ROOT_DIR="$WORK/openssl-$arch" \
        -DWITH_CLIENT_MAC=ON -DWITH_CLIENT_SDL=OFF -DWITH_SERVER=OFF -DWITH_SAMPLE=OFF \
        -DWITH_MANPAGES=OFF -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_OPENH264=OFF -DWITH_X11=OFF \
        -DWITH_PCSC=OFF -DWITH_PKCS11=OFF -DWITH_KRB5=OFF -DWITH_FUSE=OFF -DWITH_WINPR_TOOLS=OFF -DBUILD_TESTING=OFF \
        -DCHANNEL_URBDRC=OFF -DCHANNEL_AUDIN=OFF \
        -DWITH_JSON_DISABLED=ON -DWITH_AAD=OFF -DWITH_URIPARSER=OFF -DWITH_SYSTEMD=OFF \
        -DWITH_OPUS=OFF -DWITH_SOXR=OFF -DWITH_CAIRO=OFF -DWITH_LAME=OFF -DWITH_FAAD2=OFF \
        -DWITH_FAAC=OFF -DWITH_FDK_AAC=OFF -DWITH_GSM=OFF -DWITH_DAV1D=OFF -DWITH_AOM=OFF \
        -DWITH_YUV=OFF -DWITH_JPEG=OFF -DWITH_LODEPNG=OFF -DWITH_TIMEZONE_ICU=OFF -DWITH_CCACHE=OFF \
        -DWITH_CUPS=ON -DWITH_MACAUDIO=ON -DWITH_APPLE_VIDEOTOOLBOX=ON
    # Refuses to build what it wasn't asked for. The version too: the tarball sits inside xpnd's
    # repository, and asked for a git tag FreeRDP takes xpnd's (0.2.1) and installs include/freerdp0.
    for want in FREERDP_DEFAULT_PROJECT_VERSION:STRING=$FREERDP_VERSION WITH_WINPR_JSON:INTERNAL=OFF WITH_AAD:BOOL=OFF WITH_URIPARSER:BOOL=OFF \
        WITH_OPUS:BOOL=OFF WITH_SOXR:BOOL=OFF WITH_CAIRO:BOOL=OFF WITH_SYSTEMD:BOOL=OFF \
        WITH_KRB5:BOOL=OFF WITH_PCSC:BOOL=OFF WITH_PKCS11:BOOL=OFF WITH_MACAUDIO:BOOL=ON WITH_CUPS:BOOL=ON; do
        grep -qx "$want" "freerdp-build-$arch/CMakeCache.txt" ||
            { echo "FreeRDP $arch configured without $want: aborting."; exit 1; }
    done
    cmake --build "freerdp-build-$arch" --target install --parallel "$JOBS"
    echo "FreeRDP $arch: $((SECONDS - step)) s"
done

for arch in $ARCHS; do
    libs=()
    while IFS= read -r lib; do libs+=("$lib"); done < <(find "freerdp-$arch/lib" "openssl-$arch/lib" -name '*.a' | sort)
    libtool -static -o "libFreeRDP-$arch.a" "${libs[@]}"
done
rm -f libFreeRDP.a
lipo -create libFreeRDP-arm64.a libFreeRDP-x86_64.a -output libFreeRDP.a

# FreeRDP 3 versions its include directories (include/freerdp3/freerdp); flattened here so
# <freerdp/freerdp.h> and <winpr/winpr.h> resolve. The Mac client's headers aren't installed.
rm -rf Headers
mkdir -p Headers/freerdp/client/Mac
cp -R freerdp-arm64/include/freerdp3/. freerdp-arm64/include/winpr3/. Headers/
for header in MRDPView.h mfreerdp.h mf_client.h Keyboard.h Clipboard.h MRDPCursor.h; do
    cp "$FREERDP_SRC/client/Mac/$header" Headers/freerdp/client/Mac/
done

# Assembled here and moved into place last, so a failed build never leaves a partial xcframework.
rm -rf FreeRDP.xcframework
xcodebuild -create-xcframework -library libFreeRDP.a -headers Headers -output FreeRDP.xcframework
rm -rf "$VENDOR/FreeRDP.xcframework"
mv FreeRDP.xcframework "$VENDOR/"

mkdir -p "$VENDOR/licenses"
cp "$FREERDP_SRC/LICENSE" "$VENDOR/licenses/FreeRDP License.txt"
cp "$OPENSSL_SRC/LICENSE.txt" "$VENDOR/licenses/OpenSSL License.txt"

elapsed=$((SECONDS - START))
echo "Built $VENDOR/FreeRDP.xcframework (FreeRDP $FREERDP_VERSION, OpenSSL $OPENSSL_VERSION) in $((elapsed / 60))m $((elapsed % 60))s."
