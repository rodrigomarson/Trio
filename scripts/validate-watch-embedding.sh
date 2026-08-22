#!/bin/bash

set -euo pipefail

iphone_app="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
watch_app="${iphone_app}/Watch/Trio Watch App.app"
watch_plist="${watch_app}/Info.plist"
plist_buddy="/usr/libexec/PlistBuddy"

if [[ ! -d "${watch_app}" ]]; then
    echo "error: Trio Watch App is missing from ${iphone_app}/Watch."
    exit 1
fi

if [[ ! -f "${watch_plist}" ]]; then
    echo "error: Unable to validate the embedded Apple Watch Info.plist file."
    exit 1
fi

iphone_bundle_id="${PRODUCT_BUNDLE_IDENTIFIER}"
iphone_version="${MARKETING_VERSION}"
iphone_build="${CURRENT_PROJECT_VERSION}"

watch_bundle_id="$("${plist_buddy}" -c "Print :CFBundleIdentifier" "${watch_plist}")"
watch_companion_id="$("${plist_buddy}" -c "Print :WKCompanionAppBundleIdentifier" "${watch_plist}")"
watch_version="$("${plist_buddy}" -c "Print :CFBundleShortVersionString" "${watch_plist}")"
watch_build="$("${plist_buddy}" -c "Print :CFBundleVersion" "${watch_plist}")"

if [[ "${watch_companion_id}" != "${iphone_bundle_id}" ]]; then
    echo "error: Apple Watch companion ID ${watch_companion_id} does not match ${iphone_bundle_id}."
    exit 1
fi

if [[ "${watch_bundle_id}" != "${iphone_bundle_id}.watchkitapp" ]]; then
    echo "error: Apple Watch bundle ID ${watch_bundle_id} does not match ${iphone_bundle_id}.watchkitapp."
    exit 1
fi

if [[ "${watch_version}" != "${iphone_version}" || "${watch_build}" != "${iphone_build}" ]]; then
    echo "error: Apple Watch version/build ${watch_version} (${watch_build}) does not match iPhone ${iphone_version} (${iphone_build})."
    exit 1
fi

if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "YES" && "${PLATFORM_NAME:-}" != *simulator* ]]; then
    /usr/bin/codesign --verify --deep --strict "${watch_app}"
fi

echo "Apple Watch companion validated: ${watch_bundle_id} ${watch_version} (${watch_build})."
