#!/usr/bin/env bash
set -x
xcodebuild -version
xcrun --find appintentsmetadataprocessor
ls /Library/Developer/CommandLineTools/usr/bin | grep -i -E "intent|const" || true
ls "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/bin" | grep -i -E "intent|const"
xcrun appintentsmetadataprocessor --help
echo '["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider"]' > /tmp/protos.json
swift build -c release --product CalendarHub -Xswiftc -emit-const-values -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc /tmp/protos.json 2>&1 | tail -30
find .build -name '*.swiftconstvalues' | head
find .build -name '*.swiftconstvalues' -path '*CalendarHub.build*' -exec head -c 3000 {} \;
xcrun --show-sdk-path; xcrun --show-sdk-version
