// 动态增删输入法测试
// 用真实的系统 API 启用/禁用输入法，验证列表变化时不会崩溃、不会切错。
// 只操作键盘布局，避免 IME 启用/禁用的异步副作用。结束后恢复原状。

import Foundation
import Carbon.HIToolbox

setbuf(stdout, nil)

var failures: [String] = []
func check(_ ok: Bool, _ name: String, _ detail: String = "") {
    print("\(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
    if !ok { failures.append(name) }
}

// MARK: - 系统输入源读写

struct RawSource {
    let id: String
    let name: String
    let enabled: Bool
}

func readSources(includeDisabled: Bool) -> [RawSource] {
    let f: [String: Any] = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String]
    guard let raw = TISCreateInputSourceList(f as CFDictionary, includeDisabled) else { return [] }
    let arr = raw.takeRetainedValue()
    var out: [RawSource] = []
    for i in 0..<CFArrayGetCount(arr) {
        let s = unsafeBitCast(CFArrayGetValueAtIndex(arr, i), to: TISInputSource.self)
        guard let id = TIS.string(s, kTISPropertyInputSourceID) else { continue }
        out.append(RawSource(id: id,
                             name: TIS.string(s, kTISPropertyLocalizedName) ?? id,
                             enabled: TIS.flag(s, kTISPropertyInputSourceIsEnabled)))
    }
    return out
}

func enabledIDs() -> [String] { readSources(includeDisabled: false).map(\.id) }

@discardableResult
func setEnabled(_ id: String, _ on: Bool) -> OSStatus {
    guard let raw = TISCreateInputSourceList([kTISPropertyInputSourceID as String: id] as CFDictionary, true) else {
        return OSStatus(paramErr)
    }
    let arr = raw.takeRetainedValue()
    guard CFArrayGetCount(arr) > 0 else { return OSStatus(paramErr) }
    let src = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: TISInputSource.self)
    return withExtendedLifetime(arr) { on ? TISEnableInputSource(src) : TISDisableInputSource(src) }
}

/// 系统的启用/禁用是异步的，轮询等待条件成立
@discardableResult
func waitUntil(_ timeout: Double = 3.0, _ cond: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cond() { return true }
        usleep(120_000)
    }
    return cond()
}

// MARK: - 1. 纯逻辑：轮换下标

print("== Cycler 纯逻辑 ==")
let abc = ["a", "b", "c"]
check(Cycler.nextIndex(current: nil, anchor: nil, ids: [], direction: 1) == nil, "空列表返回 nil")
check(Cycler.nextIndex(current: "a", anchor: nil, ids: ["a"], direction: 1) == 0, "只有一个输入法时停在原地")
check(Cycler.nextIndex(current: "a", anchor: nil, ids: abc, direction: 1) == 1, "已知 current 顺序 +1")
check(Cycler.nextIndex(current: "c", anchor: nil, ids: abc, direction: 1) == 0, "末尾回绕到第一个")
check(Cycler.nextIndex(current: "a", anchor: nil, ids: abc, direction: -1) == 2, "开头逆序回绕到末尾")
check(Cycler.nextIndex(current: "zzz", anchor: "b", ids: abc, direction: 1) == 2,
      "current 不在列表时用 anchor 兜底（父级 IME 场景）")
check(Cycler.nextIndex(current: "zzz", anchor: "c", ids: abc, direction: 1) == 0, "anchor 兜底也能回绕")
check(Cycler.nextIndex(current: "zzz", anchor: "gone", ids: abc, direction: 1) == 0, "current/anchor 都失效时从头开始")
check(Cycler.nextIndex(current: "zzz", anchor: "gone", ids: abc, direction: -1) == 2, "都失效时逆序从末尾开始")

// MARK: - 2. 纯逻辑：标签去重

print("\n== 标签 ==")
let dup1 = makeLabels([("x1", "简体拼音"), ("x2", "双拼")])
check(Set(dup1).count == 2, "「简体拼音」「双拼」可区分", dup1.joined(separator: "/"))

let dup2 = makeLabels([("h1", "Hebrew"), ("h2", "Hebrew – QWERTY")])
check(Set(dup2).count == 2, "Hebrew 两个变体可区分", dup2.joined(separator: "/"))

let dup3 = makeLabels([("p1", "Pinyin – Simplified"), ("p2", "Pinyin – Traditional")])
check(Set(dup3).count == 2, "Pinyin 简繁可区分", dup3.joined(separator: "/"))

let same = makeLabels([("s1", "Stroke"), ("s2", "Stroke")])
check(Set(same).count == 2, "完全同名也能区分", same.joined(separator: "/"))

let cjk = makeLabels([("g", "希腊语"), ("h", "希伯来语")])
check(cjk == ["希腊", "希伯"], "中文重名前缀保留可读性", cjk.joined(separator: "/"))

let uniq = makeLabels([("u1", "U.S."), ("u2", "微信输入法"), ("u3", "Greek")])
check(Set(uniq).count == 3, "不冲突时保持原标签", uniq.joined(separator: "/"))
check(uniq[1] == "微", "中文输入法短标签正确", uniq[1])

// MARK: - 3. 回归：反复读当前输入法（此前这里过度释放导致 SIGTRAP）

print("\n== 回归：连续读取 ==")
var seen = Set<String>()
var readOK = true
for _ in 0..<200 {
    guard let cur = TIS.current() else { readOK = false; break }
    seen.insert(cur.id)
}
check(readOK, "连续 200 次 TIS.current() 不崩溃")
check(seen.count == 1, "期间当前输入法保持不变", seen.joined(separator: "/"))

// MARK: - 4. 真实增删键盘布局

print("\n== 动态增删 ==")
let baseline = enabledIDs()
let originalCurrent = TIS.current()?.id
print("   基线：\(baseline.joined(separator: ", "))")

let sample = "com.apple.keylayout.Hebrew"
let alreadyOn = baseline.contains(sample)
if alreadyOn {
    setEnabled(sample, false)
    waitUntil { !enabledIDs().contains(sample) }
    print("   （样本原本是启用的，先关掉再测）")
}

// --- 添加 ---
print("\n   -- 添加希伯来文 --")
let st = setEnabled(sample, true)
check(st == noErr, "启用成功", "status=\(st)")
check(waitUntil { enabledIDs().contains(sample) }, "新输入法出现在列表里",
      "共 \(TIS.enabledSources().count) 项")

let after = TIS.enabledSources()
check(after.contains(where: { $0.id == sample }), "列表接口能读到它")
check(Set(after.map(\.label)).count == after.count, "标签互不相同", after.map(\.label).joined(separator: "/"))

// 切过去
_ = TIS.select(id: sample)
check(waitUntil { TIS.current()?.id == sample }, "能切换过去")

// 从它继续轮换
if let idx = Cycler.nextIndex(current: TIS.current()?.id, anchor: nil, ids: after.map(\.id), direction: 1) {
    let nextID = after[idx].id
    _ = TIS.select(id: nextID)
    check(waitUntil { TIS.current()?.id == nextID }, "从新输入法继续轮换", nextID)
} else {
    check(false, "从新输入法继续轮换", "拿不到下标")
}

// 切到不存在的 id：必须安全失败，不能崩
let bogus = TIS.select(id: "com.example.nonexistent.inputsource")
check(bogus != noErr, "切换到不存在的输入法安全失败", "status=\(bogus)")

// --- 删除 ---
print("\n   -- 删除希伯来文 --")
setEnabled(sample, false)
check(waitUntil { !enabledIDs().contains(sample) }, "删除后从列表消失")

let removed = TIS.enabledSources()
check(!removed.isEmpty, "删除后列表非空", "共 \(removed.count) 项")
check(TIS.current() != nil, "删除后当前输入法依然可读", TIS.current()?.id ?? "nil")
check(Set(removed.map(\.label)).count == removed.count, "删除后标签仍互不相同",
      removed.map(\.label).joined(separator: "/"))

if let cur = TIS.current()?.id,
   let idx = Cycler.nextIndex(current: cur, anchor: nil, ids: removed.map(\.id), direction: 1) {
    let nextID = removed[idx].id
    _ = TIS.select(id: nextID)
    check(waitUntil { TIS.current()?.id == nextID }, "删除后仍能正常轮换", nextID)
} else {
    check(false, "删除后仍能正常轮换", "拿不到下标")
}

// MARK: - 5. 恢复现场

print("\n== 恢复 ==")
if alreadyOn { setEnabled(sample, true) }
if let originalCurrent = originalCurrent {
    _ = TIS.select(id: originalCurrent)
    _ = waitUntil { TIS.current()?.id == originalCurrent }
    check(TIS.current()?.id == originalCurrent, "恢复原输入法", originalCurrent)
}
let final = Set(enabledIDs())
check(final == Set(baseline), "输入法集合恢复原状",
      final == Set(baseline) ? "" : "差异：\(final.symmetricDifference(Set(baseline)))")

print("\n\(failures.isEmpty ? "ALL PASSED" : "FAILED: \(failures)")")
exit(failures.isEmpty ? 0 : 1)
