#!/bin/bash
# Builds dist/Shutlid.app (release, arm64) and signs it.
#
#   scripts/build.sh [--dmg] [--notarize]
#
# Environment:
#   SIGN_IDENTITY     codesign identity; default "-" (ad hoc, local use only)
#   NOTARY_PROFILE    notarytool keychain profile for --notarize; default "shutlid"
#   SWIFT_BUILD_ARGS  extra arguments for `swift build` (e.g. --scratch-path)
set -euo pipefail

cd "$(dirname "$0")/.."

make_dmg=false
notarize=false
for arg in "$@"; do
    case "$arg" in
        --dmg) make_dmg=true ;;
        --notarize) notarize=true ;;
        *) echo "usage: scripts/build.sh [--dmg] [--notarize]" >&2; exit 1 ;;
    esac
done

version=$(sed -n 's/^ *public static let version = "\([^"]*\)".*/\1/p' Sources/ShutlidCore/Shutlid.swift)
if [ -z "$version" ]; then
    echo "error: could not read Shutlid.version from Sources/ShutlidCore/Shutlid.swift" >&2
    exit 1
fi

# SWIFT_BUILD_ARGS is intentionally unquoted so it can hold several arguments.
# shellcheck disable=SC2086
swift build -c release --arch arm64 ${SWIFT_BUILD_ARGS:-}
# shellcheck disable=SC2086
bin=$(swift build -c release --arch arm64 ${SWIFT_BUILD_ARGS:-} --show-bin-path)

app=dist/Shutlid.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# The app binary is ShutlidApp, not Shutlid: the CLI must be Contents/MacOS/shutlid
# and the two names collide on a case-insensitive volume.
cp "$bin/ShutlidApp" "$app/Contents/MacOS/ShutlidApp"
cp "$bin/shutlid" "$app/Contents/MacOS/shutlid"
sed "s/__VERSION__/$version/g" Resources/Info.plist > "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

identity=${SIGN_IDENTITY:--}
sign_flags=(--force)
if [ "$identity" != "-" ]; then
    sign_flags+=(--options runtime --timestamp)
fi
codesign --sign "$identity" "${sign_flags[@]}" "$app/Contents/MacOS/shutlid"
codesign --sign "$identity" "${sign_flags[@]}" "$app/Contents/MacOS/ShutlidApp"
codesign --sign "$identity" "${sign_flags[@]}" "$app"
codesign --verify --deep --strict "$app"
echo "built $app (version $version, signed with '$identity')"

if $make_dmg; then
    dmg="dist/Shutlid-$version.dmg"
    hdiutil create -volname Shutlid -srcfolder "$app" -ov -format UDZO "$dmg"
    if [ "$identity" != "-" ]; then
        codesign --sign "$identity" --force --timestamp "$dmg"
    fi
    echo "built $dmg"
fi

if $notarize; then
    if [ "$identity" = "-" ]; then
        echo "error: --notarize needs a Developer ID in SIGN_IDENTITY" >&2
        exit 1
    fi
    # notarytool accepts a dmg or a zip, not a bare .app; the ticket is stapled to the app itself.
    target=$app
    upload=dist/Shutlid-notarize.zip
    if $make_dmg; then
        target=$dmg
        upload=$dmg
    else
        ditto -c -k --keepParent "$app" "$upload"
    fi
    xcrun notarytool submit "$upload" --wait --keychain-profile "${NOTARY_PROFILE:-shutlid}"
    xcrun stapler staple "$target"
    rm -f dist/Shutlid-notarize.zip
    echo "notarized and stapled $target"
fi
