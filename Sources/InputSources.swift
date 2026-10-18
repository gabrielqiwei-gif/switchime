// 输入源查询 / 切换 / 标签生成 —— 不依赖 AppKit，可被测试单独编译

import Foundation
import Carbon.HIToolbox

struct InputSourceInfo: Equatable {
    let id: String
    let name: String
    var label: String
}

enum TIS {

    // MARK: 属性读取

    static func string(_ src: TISInputSource, _ key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    static func flag(_ src: TISInputSource, _ key: CFString) -> Bool {
        guard let ptr = TISGetInputSourceProperty(src, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue())
    }

    // MARK: 列表

    /// 已启用、可切换的键盘输入源，顺序与系统输入法菜单一致。
    /// 只返回值类型快照，绝不把 TISInputSource 裸指针带出作用域，
    /// 因此用户随时增删输入法都不会产生悬垂引用。
    static func enabledSources() -> [InputSourceInfo] {
        let filter: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String
        ]
        guard let raw = TISCreateInputSourceList(filter as CFDictionary, false) else { return [] }
        let array = raw.takeRetainedValue()

        var items: [(id: String, name: String)] = []
        var seen = Set<String>()
        for i in 0..<CFArrayGetCount(array) {
            let src = unsafeBitCast(CFArrayGetValueAtIndex(array, i), to: TISInputSource.self)
            guard flag(src, kTISPropertyInputSourceIsSelectCapable),
                  flag(src, kTISPropertyInputSourceIsEnabled),
                  let id = string(src, kTISPropertyInputSourceID),
                  !seen.contains(id) else { continue }
            seen.insert(id)
            items.append((id, string(src, kTISPropertyLocalizedName) ?? id))
        }

        let labels = makeLabels(items)
        return zip(items, labels).map { pair, label in
            InputSourceInfo(id: pair.id, name: pair.name, label: label)
        }
    }

    /// 当前输入源。中文/日文等输入法返回的是具体「输入模式」；
    /// 少数输入法可能返回不可切换的父级，此时 id 不会出现在 enabledSources() 里，
    /// 调用方需要能容忍这种情况（见 Cycler）。
    static func current() -> InputSourceInfo? {
        guard let raw = TISCopyCurrentKeyboardInputSource() else { return nil }
        let src = raw.takeRetainedValue()   // ARC 接管所有权，无需手动 release

        guard let id = string(src, kTISPropertyInputSourceID) else { return nil }
        let name = string(src, kTISPropertyLocalizedName) ?? id
        return InputSourceInfo(id: id, name: name, label: baseLabel(id: id, name: name))
    }

    /// 按 id 现场解析输入源并切换。解析和切换在同一个作用域内完成，
    /// 即使这个输入法刚刚被删除，也只会拿到错误码，不会访问野指针。
    static func select(id: String) -> OSStatus {
        let filter: [String: Any] = [kTISPropertyInputSourceID as String: id]
        guard let raw = TISCreateInputSourceList(filter as CFDictionary, false) else {
            return OSStatus(paramErr)
        }
        let array = raw.takeRetainedValue()

        return withExtendedLifetime(array) { () -> OSStatus in
            guard CFArrayGetCount(array) > 0 else { return OSStatus(paramErr) }
            let src = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: TISInputSource.self)
            guard flag(src, kTISPropertyInputSourceIsEnabled) else { return OSStatus(paramErr) }

            var status = TISSelectInputSource(src)
            if status != noErr {
                usleep(30_000)                    // 少数输入法需要稍后重试一次
                status = TISSelectInputSource(src)
            }
            return status
        }
    }
}

// MARK: - 轮换逻辑（纯函数，便于穷举测试）

enum Cycler {
    /// 返回下一个要切换到的下标。
    /// - current: 系统报告的当前输入法 id，可能不在列表里（父级 IME 等情况）
    /// - anchor:  上一次成功切换到的 id，作为 current 不可用时的兜底
    static func nextIndex(current: String?, anchor: String?, ids: [String], direction: Int) -> Int? {
        guard !ids.isEmpty else { return nil }
        let base = current.flatMap { ids.firstIndex(of: $0) }
            ?? anchor.flatMap { ids.firstIndex(of: $0) }

        if let base = base {
            let n = ids.count
            return ((base + direction) % n + n) % n
        }
        return direction >= 0 ? 0 : ids.count - 1
    }
}

// MARK: - 状态栏短标签

extension Character {
    var isCJK: Bool {
        unicodeScalars.contains { s in
            (0x4E00...0x9FFF).contains(s.value)      // CJK 统一表意文字
                || (0x3040...0x30FF).contains(s.value) // 日文假名
                || (0xAC00...0xD7AF).contains(s.value) // 韩文
        }
    }
}

/// 单个输入法的短标签（1~3 个字符）
func baseLabel(id: String, name: String) -> String {
    let lowered = id.lowercased()

    let named: [(String, String)] = [
        ("拼音", "拼"), ("双拼", "拼"), ("五笔", "五"), ("笔画", "笔"),
        ("注音", "注"), ("仓颉", "仓"), ("速成", "速"), ("手写", "写"),
        ("微信", "微"), ("搜狗", "搜"), ("百度", "百"), ("讯飞", "讯"),
        ("韩", "한"),
    ]
    for (needle, label) in named where name.contains(needle) { return label }

    if lowered.contains("japanese") || name.contains("日语") || name.contains("ひらがな") || name.contains("Hiragana") {
        return "あ"
    }

    let isLatinOnly = name.allSatisfy { !$0.isCJK }
    if isLatinOnly {
        let letters = name.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if !letters.isEmpty {
            let upper = String(letters).uppercased()
            return upper.count <= 3 ? upper : String(upper.prefix(1))
        }
    }
    return name.isEmpty ? "?" : String(name.prefix(1))
}

/// 整份列表的标签。基础标签撞车时（例如同时启用「简体拼音」和「双拼」，
/// 基础标签都是「拼」），改用更长的、有区分度的名字片段，保证菜单栏能分辨。
func makeLabels(_ items: [(id: String, name: String)]) -> [String] {
    var labels = items.map { baseLabel(id: $0.id, name: $0.name) }

    // 第一级：撞车时先统一加长到 2 个字符（「希腊语」「希伯来语」-> 「希腊」「希伯」）
    var groups = Dictionary(grouping: labels.indices) { labels[$0] }
    for (_, indices) in groups where indices.count > 1 {
        for index in indices { labels[index] = String(items[index].name.prefix(2)) }
    }

    // 第二级：还是撞车，就去掉公共前缀取有区分度的一段
    // （「Hebrew」「Hebrew – QWERTY」-> 「He」「QW」）
    groups = Dictionary(grouping: labels.indices) { labels[$0] }
    for (_, indices) in groups where indices.count > 1 {
        let names = indices.map { items[$0].name }
        let extended = distinguishingLabels(names, cap: 3)
        for (k, index) in indices.enumerated() { labels[index] = extended[k] }
    }

    // 名字完全一样（例如同一输入法的重复条目）时，加序号兜底，保证标签唯一
    let stillDup = Dictionary(grouping: labels.indices) { labels[$0] }
    for (_, indices) in stillDup where indices.count > 1 {
        for (n, index) in indices.enumerated() {
            labels[index] = "\(labels[index])\(n + 1)"
        }
    }
    return labels
}

/// 去掉这组名字的公共前缀后，各取有区分度的一段。
/// 例如 ["Hebrew", "Hebrew – QWERTY"] -> ["HE", "QW"]
func distinguishingLabels(_ names: [String], cap: Int) -> [String] {
    let chars = names.map { Array($0) }
    let shortest = chars.map(\.count).min() ?? 0

    // 完整的公共前缀（可以吃掉整个名字）
    var prefix = 0
    while prefix < shortest {
        let c = chars[0][prefix]
        if chars.allSatisfy({ $0[prefix] == c }) { prefix += 1 } else { break }
    }

    let separators = CharacterSet.whitespaces
        .union(CharacterSet(charactersIn: "–—-·,，、()（）/"))

    return (0..<names.count).map { i in
        let rest = String(chars[i].dropFirst(prefix))
        let trimmed = rest.trimmingCharacters(in: separators)
        if trimmed.isEmpty {
            return String(names[i].prefix(cap))
        }
        return String(trimmed.prefix(cap))
    }
}
