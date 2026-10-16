#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
task_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/espanso-tests.XXXXXX")"
trap 'rm -rf "$task_test_dir"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$task_test_dir/cache" Source/Core.swift Source/LZ4Frame.swift Source/ATextImport.swift Source/ATextMacros.swift Tests/CoreTests.swift -o "$task_test_dir/CoreTests"
"$task_test_dir/CoreTests"
xcrun swiftc -swift-version 5 -module-cache-path "$task_test_dir/cache" Source/Core.swift Source/LZ4Frame.swift Source/ATextImport.swift Source/ATextMacros.swift Tests/TemplateTests.swift -o "$task_test_dir/TemplateTests"
"$task_test_dir/TemplateTests"
xcrun swiftc -swift-version 5 -D ENGINE_SELF_TEST -module-cache-path "$task_test_dir/cache" Source/Core.swift Source/LZ4Frame.swift Source/ATextImport.swift Source/ATextMacros.swift Source/ExpansionEngine.swift -o "$task_test_dir/EngineTests"
"$task_test_dir/EngineTests"
xcrun swiftc -swift-version 5 -module-cache-path "$task_test_dir/cache" Source/Core.swift Source/LZ4Frame.swift Source/ATextImport.swift Source/ATextMacros.swift Source/ExpansionEngine.swift Tests/AutomationStub.swift Source/Automation.swift Tests/AutomationChecks.swift -o "$task_test_dir/AutomationTests"
"$task_test_dir/AutomationTests"
xcrun swiftc -swift-version 5 -module-cache-path "$task_test_dir/cache" Source/Core.swift Source/LZ4Frame.swift Source/ATextImport.swift Source/ATextMacros.swift Source/FolderSync.swift Tests/FolderSyncTests.swift -o "$task_test_dir/FolderSyncTests"
"$task_test_dir/FolderSyncTests"
xcrun swiftc -swift-version 5 -module-cache-path "$task_test_dir/cache" Source/LZ4Frame.swift Tests/LZ4FrameTests.swift -o "$task_test_dir/LZ4Tests"
"$task_test_dir/LZ4Tests"
xcrun swiftc -swift-version 5 -module-cache-path "$task_test_dir/cache" Source/Core.swift Source/LZ4Frame.swift Source/ATextImport.swift Source/ATextMacros.swift Tests/ATextImportTests.swift -o "$task_test_dir/ATextImportTests"
"$task_test_dir/ATextImportTests"
xcrun swiftc -swift-version 5 -module-cache-path "$task_test_dir/cache" Source/Core.swift Source/LZ4Frame.swift Source/ATextImport.swift Source/ATextMacros.swift Tests/ATextMacroTests.swift -o "$task_test_dir/ATextMacroTests"
"$task_test_dir/ATextMacroTests"
xmllint --noout --valid Resources/SuperSnippetto.sdef
