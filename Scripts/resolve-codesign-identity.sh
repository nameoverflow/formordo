#!/bin/sh
set -eu

MODE="${1:-auto}"
LOCAL_CERT_NAME="${2:-Talus Local Code Signing}"

if [ "$MODE" != "auto" ] && [ "$MODE" != "dist" ]; then
    printf '%s\n' "$MODE"
    exit 0
fi

IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"

pick_first() {
    pattern="$1"
    printf '%s\n' "$IDENTITIES" | grep -F "$pattern" | head -n 1 | awk '{print $2}' || true
}

dev_id="$(pick_first '"Developer ID Application:')"
if [ -n "$dev_id" ]; then
    printf '%s\n' "$dev_id"
    exit 0
fi

if [ "$MODE" = "dist" ]; then
    printf '%s\n' "-"
    exit 0
fi

apple_dev="$(pick_first '"Apple Development:')"
if [ -n "$apple_dev" ]; then
    printf '%s\n' "$apple_dev"
    exit 0
fi

local_id="$(pick_first "\"$LOCAL_CERT_NAME\"")"
if [ -n "$local_id" ]; then
    printf '%s\n' "$local_id"
    exit 0
fi

printf '%s\n' "-"
