#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
xcrun clang -fobjc-arc -framework Foundation -framework Security -I Common -I . \
  -include Security/Security.h Common/SCBrowserMessage.m Common/SCBrowserIntegration.m \
  Common/SCWeeklySchedule.m tests/browser-native-stubs.m -o build/browser-native-tests
python3 tests/browser-native-protocol.py build/browser-native-tests
npm --prefix BrowserExtension run build
python3 tests/browser-installer.py
npm --prefix BrowserExtension test
