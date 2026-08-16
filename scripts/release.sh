#!/bin/sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

version="${RZ_VERSION:-1.0.0}"
arch="$(uname -m)"
case "$arch" in
    arm64|aarch64) arch_tag="arm64" ;;
    x86_64)        arch_tag="x64" ;;
    *)             arch_tag="$arch" ;;
esac

build_dir="${root}/build-release"
dist_dir="${root}/dist"
app="${build_dir}/ReZipper.app"
zip_name="ReZipper-${version}-macos-${arch_tag}.zip"

echo "==> Configuring Release (${arch_tag})"
cmake -S . -B "${build_dir}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0

echo "==> Building ReZipper"
cmake --build "${build_dir}" --target ReZipper

if [ ! -d "${app}" ]; then
    echo "error: ${app} was not produced" >&2
    exit 1
fi

echo "==> Stripping"
strip -x "${app}/Contents/MacOS/ReZipper"

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "${app}"

echo "==> Verifying bundle"
test -f "${app}/Contents/MacOS/ReZipper"
test -f "${app}/Contents/Frameworks/7z.so"
test -f "${app}/Contents/Resources/AppIcon.icns"
file "${app}/Contents/MacOS/ReZipper"
file "${app}/Contents/Frameworks/7z.so"
codesign -dv --verbose=2 "${app}" 2>&1 | head -n 20

mkdir -p "${dist_dir}"
rm -f "${dist_dir}/${zip_name}"

echo "==> Packaging ${zip_name}"
ditto -c -k --keepParent --sequesterRsrc "${app}" "${dist_dir}/${zip_name}"

echo
echo "Release archive:"
ls -lh "${dist_dir}/${zip_name}"
echo
echo "Attach that zip to the GitHub release (v${version})."
echo "Other Macs will see Gatekeeper on first open (ad-hoc signature)."
echo "Right-click → Open, or: xattr -dr com.apple.quarantine ReZipper.app"
