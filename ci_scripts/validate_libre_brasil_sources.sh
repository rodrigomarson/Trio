#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=${1:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}
LIBRE_ROOT="$REPOSITORY_ROOT/LibreTransmitter"
METADATA="$LIBRE_ROOT/Bluetooth/LibreTransmitterMetadata.swift"
PAIRING="$LIBRE_ROOT/LibreSensor/SensorPairing/SensorPairing.swift"
SERVICE="$LIBRE_ROOT/LibreSensor/SensorPairing/SensorPairingService.swift"
PROJECT="$LIBRE_ROOT/LibreTransmitter.xcodeproj/project.pbxproj"
SCHEME="$LIBRE_ROOT/LibreTransmitter.xcodeproj/xcshareddata/xcschemes/Shared.xcscheme"
TESTS="$LIBRE_ROOT/LibreTransmitterTests/LibreTransmitterTests.swift"

fail() {
    echo "Libre Brazil source validation failed: $1" >&2
    exit 1
}

require_text() {
    file=$1
    text=$2
    grep -F "$text" "$file" >/dev/null 2>&1 || fail "missing expected source marker: $text"
}

reject_text() {
    file=$1
    text=$2
    if [ -d "$file" ]; then
        found=$(grep -R -i -F "$text" "$file" 2>/dev/null || true)
    else
        found=$(grep -i -F "$text" "$file" 2>/dev/null || true)
    fi
    if [ -n "$found" ]; then
        fail "forbidden source marker found: $text"
    fi
}

require_text "$METADATA" "case 0x2B where patchInfo.count >= 3 && patchInfo[2] == 0x3A"
require_text "$METADATA" "case brazilLibre2Plus"
require_text "$PAIRING" "public final class UnavailableLibre2VendorBridge"
require_text "$PAIRING" "public final class AuthorizedLibre2ProviderAdapter"
require_text "$PAIRING" "case .unavailable, .unknown:"
require_text "$PAIRING" "return .unavailable"
require_text "$SERVICE" "let probes: [LibreBrazilGen2ReadOnlyProbe] = [.sessionCounter, .challenge]"
require_text "$SERVICE" "self.vendorBridge = UnavailableLibre2VendorBridge()"
require_text "$SERVICE" "case .success, .alreadyActive:"
require_text "$PROJECT" "432B0E911CDFC3C50045347B /* LibreTransmitterTests */ = {"
require_text "$PROJECT" "productType = \"com.apple.product-type.bundle.unit-test\";"
require_text "$PROJECT" "432B0E981CDFC3C50045347B /* LibreTransmitterTests.swift in Sources */"
require_text "$SCHEME" "BlueprintIdentifier = \"432B0E911CDFC3C50045347B\""
require_text "$TESTS" "func testBrazilLibre2PlusUsesDedicatedNonStreamingProtocol()"
require_text "$TESTS" "func testPairingDiagnosticSerializesNoRawSensorBytes()"

reject_text "$SERVICE" "responseHex"
reject_text "$SERVICE" "counterResponse.hexEncodedString"
reject_text "$SERVICE" "challengeResponse.hexEncodedString"
reject_text "$LIBRE_ROOT" "307e5154760da611000000000000dfea72671eee644e3f46a4"
reject_text "$LIBRE_ROOT" "03010100a617"

echo "Libre Brazil source validation passed."
