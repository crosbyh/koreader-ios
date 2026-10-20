#!/bin/bash
# Post-build hook for the Xcode project.
#
# Xcode has just built the .app shell (a folder with KOReader, Info.plist,
# and signing metadata). We populate it with the Lua frontend, the koreader
# data tree, and the prebuilt dylibs from base/build/ (wrapped as
# frameworks), then sign them with the same identity Xcode used for the app
# so the bundle verifies as a unit at install time.

set -euo pipefail

: "${SRCROOT:?Xcode env var SRCROOT not set; this script must run from a build phase}"
: "${TARGET_BUILD_DIR:?Xcode env var TARGET_BUILD_DIR not set}"
: "${WRAPPER_NAME:?Xcode env var WRAPPER_NAME not set}"

# Override per-config / per-arch if needed; defaults match make/ios.mk.
IOS_ARCH="${IOS_ARCH:-arm64}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-${IPHONEOS_DEPLOYMENT_TARGET:-15.0}}"

APP_DIR="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
STAGING="${SRCROOT}/koreader-ios-${IOS_ARCH}-apple-ios${IOS_DEPLOYMENT_TARGET}"
STAGING_KOREADER="${STAGING}/koreader"
LIBS_SRC="${SRCROOT}/base/build/${IOS_ARCH}-apple-ios${IOS_DEPLOYMENT_TARGET}/libs"

if [ ! -d "${STAGING_KOREADER}" ]; then
    echo "error: staging tree not found at ${STAGING_KOREADER}" >&2
    echo "       run \`make TARGET=ios all\` first (or check the pre-build phase)." >&2
    exit 1
fi

if [ ! -d "${LIBS_SRC}" ]; then
    echo "error: prebuilt libs not found at ${LIBS_SRC}" >&2
    exit 1
fi

echo "[*] Embedding payload into ${APP_DIR}"

# --- 1) Copy the asset tree.
# Using `app/` rather than `koreader/` because APFS is case-insensitive by
# default and CFBundleExecutable=KOReader would collide with `koreader/`.
mkdir -p "${APP_DIR}/app"
rsync -aL --delete \
    --exclude '.git' \
    --exclude 'cache' \
    --exclude 'history' \
    --exclude 'screenshots' \
    --exclude 'spec' \
    --exclude 'tools' \
    --exclude '*.dSYM' \
    --exclude 'plugins/SSH.koplugin' \
    --exclude 'plugins/autofrontlight.koplugin' \
    --exclude 'plugins/hello.koplugin' \
    --exclude 'plugins/timesync.koplugin' \
    "${STAGING_KOREADER}/" "${APP_DIR}/app/"

# --- 1.5) Precompile every .lua to LuaJIT bytecode in place. Skips if
# we don't have a host luajit available; only a perf optimisation.
"${SRCROOT}/platform/ios/precompile-lua.sh" "${APP_DIR}/app" || true

# --- 2) Pick the signing identity Xcode resolved for the app, falling back
# to ad-hoc when signing is disabled or no real identity is wired up.
SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"

# CODE_SIGNING_ALLOWED=NO (e.g. CI builds) → ad-hoc.
# Bare "iPhone Developer" / "Apple Development" / etc. without a resolved
# identity also means no real cert is available.
if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ] \
    || [ -z "${SIGN_IDENTITY}" ] \
    || [ "${SIGN_IDENTITY}" = "iPhone Developer" ] \
    || [ "${SIGN_IDENTITY}" = "Apple Development" ] \
    || [ "${SIGN_IDENTITY}" = "-" ]; then
    SIGN_IDENTITY="-"
    KEYCHAIN_FLAG=""
else
    KEYCHAIN_FLAG="${OTHER_CODE_SIGN_FLAGS:-}"
fi

# --- 3) Move every Mach-O out of app/.
# App Store Connect (TestFlight included) rejects standalone executables and
# dylibs anywhere in the bundle (ITMS-90171). Each library becomes a minimal
# Frameworks/<name>.framework; executables (sdcv, luajit, the desktop
# launcher) are dropped since iOS can't spawn them anyway. ios-frameworks.lua
# maps the original library file names to framework names for setupkoenv.lua,
# which redirects KOReader's library loads accordingly.
FRAMEWORKS_DIR="${APP_DIR}/Frameworks"
FRAMEWORK_MAP="${APP_DIR}/app/ios-frameworks.lua"
rm -rf "${FRAMEWORKS_DIR}"
mkdir -p "${FRAMEWORKS_DIR}"
echo "return {" >"${FRAMEWORK_MAP}"
change_args=()
framework_bins=()
while IFS= read -r -d '' bin; do
    case "$(file -b "${bin}")" in
        Mach-O*"shared library"* | Mach-O*bundle*) ;;
        Mach-O*executable*)
            echo "[*] Dropping standalone executable ${bin#"${APP_DIR}/"}"
            rm -f "${bin}"
            continue
            ;;
        *) continue ;;
    esac
    lib="$(basename "${bin}")"
    # libkoreader-monolibtic.dylib → koreadermonolibtic, libSDL3.0.dylib → SDL3
    name="${lib#lib}"
    name="${name%%.*}"
    name="${name//[^A-Za-z0-9]/}"
    fw="${FRAMEWORKS_DIR}/${name}.framework"
    if [ -e "${fw}" ]; then
        echo "error: more than one library maps to ${name}.framework" >&2
        exit 1
    fi
    mkdir -p "${fw}"
    mv "${bin}" "${fw}/${name}"
    old_id="$(otool -D "${fw}/${name}" | sed -n 2p)"
    if [ -n "${old_id}" ]; then
        install_name_tool -id "@rpath/${name}.framework/${name}" "${fw}/${name}" 2>/dev/null
        change_args+=(-change "${old_id}" "@rpath/${name}.framework/${name}")
    fi
    cat >"${fw}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${name}</string>
    <key>CFBundleIdentifier</key>
    <string>${PRODUCT_BUNDLE_IDENTIFIER}.${name}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${name}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>${MARKETING_VERSION:-1.0}</string>
    <key>CFBundleVersion</key>
    <string>${CURRENT_PROJECT_VERSION:-1}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>iPhoneOS</string>
    </array>
    <key>MinimumOSVersion</key>
    <string>${IPHONEOS_DEPLOYMENT_TARGET:-${IOS_DEPLOYMENT_TARGET}}</string>
</dict>
</plist>
PLIST
    printf '    ["%s"] = "%s",\n' "${lib}" "${name}" >>"${FRAMEWORK_MAP}"
    framework_bins+=("${fw}/${name}")
    echo "[*] ${bin#"${APP_DIR}/"} → Frameworks/${name}.framework"
done < <(find "${APP_DIR}/app" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0)
echo "}" >>"${FRAMEWORK_MAP}"

# Point the launcher and the libraries at each other's new install names.
# Libraries dlopen'd from Lua resolve their own @rpath deps via @loader_path.
if [ ${#change_args[@]} -gt 0 ]; then
    install_name_tool "${change_args[@]}" "${APP_DIR}/${EXECUTABLE_NAME}" 2>/dev/null
fi
for bin in ${framework_bins[@]+"${framework_bins[@]}"}; do
    if [ ${#change_args[@]} -gt 0 ]; then
        install_name_tool "${change_args[@]}" "${bin}" 2>/dev/null
    fi
    if ! otool -l "${bin}" | grep -q "path @loader_path/.. "; then
        install_name_tool -add_rpath "@loader_path/.." "${bin}" 2>/dev/null
    fi
done

# --- 4) Sign every framework with the same identity as the app. Xcode signs
# the app itself (including the patched launcher) after this phase.
echo "[*] Signing frameworks with identity: ${SIGN_IDENTITY}"
for fw in "${FRAMEWORKS_DIR}"/*.framework; do
    [ -d "${fw}" ] || continue
    /usr/bin/codesign \
        --force \
        --sign "${SIGN_IDENTITY}" \
        --timestamp=none \
        ${KEYCHAIN_FLAG} \
        "${fw}" >/dev/null
done

echo "[*] Payload embedded."
