// 纯逻辑测试：不触碰系统输入法，可在 CI 里安全运行
// swiftc -swift-version 5 Sources/InputSources.swift Tests/logic/main.swift -o /tmp/logic

import Foundation

var failures: [String] = []
func check(_ ok: Bool, _ name: String, _ detail: String = "") {
    print("\(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
    if !ok { failures.append(name) }
}

print("== Cycler ==")
let abc = ["a", "b", "c"]
check(Cycler.nextIndex(current: nil, anchor: nil, ids: [], direction: 1) == nil, "empty list -> nil")
check(Cycler.nextIndex(current: "a", anchor: nil, ids: ["a"], direction: 1) == 0, "single item stays")
check(Cycler.nextIndex(current: "a", anchor: nil, ids: abc, direction: 1) == 1, "forward")
check(Cycler.nextIndex(current: "c", anchor: nil, ids: abc, direction: 1) == 0, "forward wrap")
check(Cycler.nextIndex(current: "a", anchor: nil, ids: abc, direction: -1) == 2, "backward wrap")
check(Cycler.nextIndex(current: "zzz", anchor: "b", ids: abc, direction: 1) == 2, "anchor fallback")
check(Cycler.nextIndex(current: "zzz", anchor: "c", ids: abc, direction: 1) == 0, "anchor fallback wrap")
check(Cycler.nextIndex(current: "zzz", anchor: "gone", ids: abc, direction: 1) == 0, "no anchor -> first")
check(Cycler.nextIndex(current: "zzz", anchor: "gone", ids: abc, direction: -1) == 2, "no anchor -> last (backward)")

print("\n== Labels ==")
check(Set(makeLabels([("1", "简体拼音"), ("2", "双拼")])).count == 2, "simplified pinyin vs shuangpin")
check(makeLabels([("g", "希腊语"), ("h", "希伯来语")]) == ["希腊", "希伯"], "shared CJK prefix stays readable")
check(Set(makeLabels([("1", "Hebrew"), ("2", "Hebrew – QWERTY")])).count == 2, "Hebrew variants")
check(Set(makeLabels([("1", "Pinyin – Simplified"), ("2", "Pinyin – Traditional")])).count == 2, "Pinyin simplified/traditional")
check(Set(makeLabels([("1", "Stroke"), ("2", "Stroke")])).count == 2, "identical names")
check(makeLabels([("u", "U.S."), ("w", "微信输入法"), ("g", "Greek")]) == ["US", "微", "G"], "no conflict keeps base label")
check(baseLabel(id: "com.apple.keylayout.US", name: "U.S.") == "US", "ascii layout label")
check(baseLabel(id: "com.apple.keylayout.Greek", name: "Greek") == "G", "long ascii name -> initial")

print("\n\(failures.isEmpty ? "ALL PASSED" : "FAILED: \(failures)")")
exit(failures.isEmpty ? 0 : 1)
