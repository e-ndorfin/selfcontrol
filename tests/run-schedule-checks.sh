#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
xcrun clang -fobjc-arc -framework Foundation -I Common \
  Common/SCWeeklySchedule.m tests/weekly-schedule-model.m -o build/weekly-schedule-model-tests
build/weekly-schedule-model-tests
xcrun clang -fobjc-arc -framework Foundation -I Common -I Daemon \
  -framework Security -include tests/schedule-service-stubs.h Common/SCWeeklySchedule.m \
  Common/SCFriendProtection.m Daemon/SCScheduleService.m tests/schedule-service.m -o build/schedule-service-tests
build/schedule-service-tests

xcrun clang -fobjc-arc -framework Foundation -framework Security -I Common \
  Common/SCWeeklySchedule.m Common/SCFriendProtection.m tests/friend-protection.m -o build/friend-protection-tests
build/friend-protection-tests

# Exercise the production daemon request/checkup code with test-owned settings and
# mocked firewall/hosts operations; this never changes the machine's network rules.
xcrun clang -fobjc-arc -Wno-incomplete-implementation -Wno-objc-property-implementation -Wno-protocol \
  -framework Cocoa -framework Security -I Common -I Common/Utility -I Daemon -I . \
  -I 'Block Management' -include tests/website-break-prefix.h \
  Daemon/SCDaemonBlockMethods.m tests/website-break.m -o build/website-break-tests
build/website-break-tests
