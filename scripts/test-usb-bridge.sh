#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_binary=$(mktemp -t xiaoai-usb-lifecycle)
trap 'rm -f "$test_binary"' EXIT
xcrun clang -Wall -Wextra -Werror $(pkg-config --cflags libusb-1.0) \
    -I Sources/USBBridge/include Sources/USBBridge/USBBridge.c \
    Tests/USBBridgeLifecycle/bridge_lifecycle.c -framework IOKit -framework CoreFoundation \
    -o "$test_binary"
"$test_binary"
