#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
xcrun clang -fobjc-arc -framework Cocoa -I . \
  SCStatusItemState.m SCStatusItemController.m tests/status-item.m -o build/status-item-tests
build/status-item-tests
