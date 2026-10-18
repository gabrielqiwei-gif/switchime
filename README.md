<p align="center">
  <img src="Resources/icon-1024.png" width="140" alt="SwitchIME icon">
</p>

<h1 align="center">SwitchIME</h1>

<p align="center">
  A tiny, permission-free macOS menu bar utility that cycles through your input sources in order.
</p>

<p align="center">
  <a href="README.zh-CN.md">中文说明</a> · MIT · macOS 12+ · universal binary · no network
</p>

---

## Why

On recent macOS versions the 🌐/Fn key that is supposed to switch input sources is unreliable —
it silently stops working, especially after a third-party IME has been installed. The built-in
`⌃Space` / `⌃⌥Space` shortcuts go through the same code path, so they break together.

SwitchIME calls the Text Input Sources API (`TISSelectInputSource`) directly. It does not take
part in the system's input-source event handling at all, so whatever breaks the Fn key does not
affect it.

It is deliberately small: ~700 lines of Swift, no dependencies, no helper daemon, no network,
no Accessibility or Input Monitoring permission. You can read all of it in one sitting.

> Want per-app or per-website automatic switching, on-screen indicators, and modifier-tap
> shortcuts? [InputSourcePro](https://github.com/runjuu/InputSourcePro) does that well.
> SwitchIME only does one thing: cycle.

## Features

- **Menu bar label** showing the current input source (`拼` `微` `美` `あ` `US` …)
- **⌃\` (Control + backtick)** cycles to the next input source in the same order as the system
  input menu and wraps around. Three alternative hotkeys in the menu.
- **Click the icon** to jump straight to any input source
- **Previous input source** menu item, for when you overshoot
- **Login item** toggle — it writes the LaunchAgent itself, no helper app
- **Follows your input source list live**: add or remove a language in System Settings and it is
  picked up on the next key press, no restart
- **Label disambiguation**: enable both 简体拼音 and 双拼 and the icon shows `简体` / `双拼`
  instead of `拼` / `拼`

## Install

Download `SwitchIME-*-universal.zip` from [Releases](../../releases), unzip it, drag
`SwitchIME.app` into `/Applications`, and launch it.

The app is ad-hoc signed (there is no paid Apple Developer certificate behind this project), so
macOS warns on first launch. Use any of:

- right-click the app → **Open** → **Open**
- System Settings → Privacy & Security → scroll down → **Open Anyway**
- `xattr -dr com.apple.quarantine /Applications/SwitchIME.app`

## Usage

| Action | Result |
| --- | --- |
| Click the menu bar icon | Pick any input source (the current one is checked) |
| **⌃\`** | Next input source, in system menu order |
| Menu → 上一个输入法 | Previous input source |
| Menu → 快捷键 | Switch to `⌃⇧\`` / `⌃⇧Space` / `⌃Space` / `⌃1` |
| Menu → 登录时自动启动 | Add / remove the LaunchAgent |
| Menu → 退出 | Quit |

The menu is currently Chinese-only (`zh_CN` is the development region). The hotkey, the cycling
and the login item work regardless of language.

## Notes on the Text Input Sources API

Things that each cost a day to figure out, written down so nobody has to rediscover them:

**1. Enabling / disabling input sources is asynchronous.**
`TISDisableInputSource()` returns `noErr` while the source is still enabled; the change lands a
few hundred milliseconds later — sometimes seconds for IMEs. Polling is the only reliable way to
observe it, and a fixed `sleep()` will bite you.

**2. Not every enabled source is selectable.**
CJK input methods expose a parent entry (`com.apple.inputmethod.Kotoeri.RomajiTyping`) next to
their modes. The parent has `kTISPropertyInputSourceIsSelectCapable == false` and must be
filtered out — yet `TISCopyCurrentKeyboardInputSource()` may still report it. So "the current
input source is not in my list" is a normal state, not an error, and the obvious
`if let i = list.firstIndex(of: current)` gets stuck. SwitchIME keeps an *anchor*: the last id it
successfully switched to, used whenever the current id is unknown.

**3. `TISInputSource` is an ARC-managed CF object.**
`takeRetainedValue()` hands ownership to ARC. Adding
`Unmanaged.passUnretained(_:).release()` on top is an over-release that crashes with `SIGTRAP`
somewhere else entirely, several calls later. Don't.

**4. Status bar labels collide.**
Mapping names down to one glyph (`拼`, `あ`, `希`) works until someone enables two variants of
the same language. SwitchIME widens labels in stages — 1 char → 2 chars → the distinguishing
segment after the common prefix → numeric suffix — and stops as soon as every label is unique.

**5. Secure input blocks everything.**
When a password field (or 1Password, or some terminals) enables secure event input, macOS
silently refuses every input source change, Fn key included. There is no workaround; the app
detects `IsSecureEventInputEnabled()` and says so instead of failing silently.

## Build

Requires Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh          # builds SwitchIME.app for arm64 + x86_64, ad-hoc signed
```

Layout:

- `Sources/InputSources.swift` — TIS wrappers, cycling math, labels (no AppKit, unit-testable)
- `Sources/main.swift` — status item, global hotkey (Carbon), LaunchAgent, menu

## Test

Pure logic — safe in CI, does not touch your input sources:

```bash
swiftc -swift-version 5 Sources/InputSources.swift Tests/logic/main.swift \
       -o /tmp/logic -framework Carbon && /tmp/logic
```

Built-in self-test — switches your input source and switches back:

```bash
./SwitchIME.app/Contents/MacOS/SwitchIME --self-test --log ./self-test.log
```

Dynamic add/remove test — temporarily enables and disables a keyboard layout, then restores it:

```bash
swiftc -swift-version 5 Sources/InputSources.swift Tests/dynamic/main.swift \
       -o /tmp/dynamic -framework Cocoa -framework Carbon && /tmp/dynamic
```

## Limitations

- Sequential cycling only; no per-app memory (use InputSourcePro for that)
- The hotkey is global, so whichever app used `⌃\`` before stops receiving it
- Ad-hoc signed and not notarized, so Gatekeeper warns on first launch
- Not sandboxed (it has to run as a background login item), but it requests no permissions and
  makes no network calls

## License

[MIT](LICENSE)
