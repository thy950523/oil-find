# 设置与索引持久化实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 让用户偏好与索引在重装、重建、更新中存活下来，并把「恢复默认」变成一个需要用户主动触发的动作。

**Architecture:** 分四块落地，按风险从低到高。第 1 块改卸载脚本的默认语义；第 2 块在设置窗口加一个受保护的清空入口；第 3 块让内容索引的重建不再表现为「搜索空了」；第 4 块给文件索引的格式演进留出向后兼容的扩展位。

**Tech Stack:** Swift 5（语言模式 5）、AppKit + SwiftUI、SQLite3、一个 C target；脚本测试用 bash + python3。

**依据：** `docs/plans/2026-10-19-settings-and-index-persistence-design.md`（已提交于 `09d3a74`）。

---

## 前置约定

**工作目录：** `/Users/zhuzhong/superconductor/projects/oil-find`，分支 `main`。

**常用命令：**

```sh
swift build                                   # 本机存在私有模块时会连 Pro 一起构建
OILFIND_FREE=1 swift build                    # 强制只构建免费版
swift test                                    # 全量测试
swift test --filter '<测试名>'                 # 单个测试
python3 Tests/Scripts/test_uninstall.py       # 卸载脚本测试
```

改动碰到公开应用库或核心时，**必须**用 `OILFIND_FREE=1` 再验证一遍，确认没有反向依赖私有模块。

**每个任务结束时提交**，提交信息用仓库现有的 conventional commit 风格（`fix(content): …`、`docs(settings): …`），并且**结尾必须带**：

```
Co-Authored-By: Claude Code <noreply@anthropic.com>
```

**代码注释用英文**（`AGENTS.md` 约定）。界面文案改动要同步维护 `Sources/OilFindApp/L10n.swift` 里的中英文对应项。

**落地顺序：** 第 1 块 → 第 2 块 → 第 3 块 → 第 4 块。前三块彼此独立，第 4 块动的是索引文件格式本身，风险最高，放最后。

---

# 第 1 块：`uninstall.sh` 默认保留偏好

## Task 1: 让卸载默认不删偏好域

**Files:**
- Modify: `scripts/uninstall.sh`

**背景：** `scripts/uninstall.sh:43` 目前无条件 `defaults delete com.oiloil.find`，只在删除前把三个 `proEvaluation*` 键读出来、删完再写回（`:44-49`）。默认保留之后，这段抢救逻辑就没有存在意义了。

**与设计文档的一处偏差（有意）：** 设计文档写「`--purge` 删两个 keychain 项」。实现上保留现有行为——`com.oiloil.find.trial` 是应用启动时本来就会清理的旧授权残留（`LegacyAuthorizationCleanup.swift`），不属于用户配置，仍然**无条件删除**。只有 `pro.evaluation` 试用锚点随 `--purge` 删除。

**Step 1: 改提示文案与删除清单**

把 `scripts/uninstall.sh:9-18` 这段：

```bash
printf '%s\n' 'The following will be deleted:' \
    '/Applications/Oil Find.app' \
    "$HOME/Library/Application Support/Oil Find" \
    'Settings: com.oiloil.find' \
    'Legacy authorization item: com.oiloil.find.trial'
if [[ "$PURGE" == true ]]; then
    printf '%s\n' 'Pro trial anchors will also be deleted.'
else
    printf '%s\n' 'Pro trial anchors will be kept.'
fi
```

替换为：

```bash
printf '%s\n' 'The following will be deleted:' \
    '/Applications/Oil Find.app' \
    "$HOME/Library/Application Support/Oil Find" \
    'Legacy authorization item: com.oiloil.find.trial'
if [[ "$PURGE" == true ]]; then
    printf '%s\n' 'Settings (com.oiloil.find) and Pro evaluation anchors will also be deleted.'
else
    printf '%s\n' 'Settings will be kept. Pass --purge to delete them as well.' \
        'Pro evaluation anchors will be kept.'
fi
```

**Step 2: 换掉删除与抢救逻辑**

把 `scripts/uninstall.sh:42-52` 这整段：

```bash
rm -rf "/Applications/Oil Find.app" "$HOME/Library/Application Support/Oil Find"
# Retain both opt-in evaluation anchors across a normal reinstall.
PRO_EVALUATION_START="$(defaults read com.oiloil.find proEvaluationStartedAt 2>/dev/null || true)"
PRO_EVALUATION_SEEN="$(defaults read com.oiloil.find proEvaluationLastSeenAt 2>/dev/null || true)"
PRO_EVALUATION_ENDED="$(defaults read com.oiloil.find proEvaluationEndedAt 2>/dev/null || true)"
defaults delete com.oiloil.find >/dev/null 2>&1 || true
if [[ "$PURGE" == false ]]; then
    if [[ -n "$PRO_EVALUATION_START" && -n "$PRO_EVALUATION_SEEN" ]]; then
        defaults write com.oiloil.find proEvaluationStartedAt -float "$PRO_EVALUATION_START"
        defaults write com.oiloil.find proEvaluationLastSeenAt -float "$PRO_EVALUATION_SEEN"
        if [[ -n "$PRO_EVALUATION_ENDED" ]]; then
            defaults write com.oiloil.find proEvaluationEndedAt -float "$PRO_EVALUATION_ENDED"
        fi
    fi
else
    security delete-generic-password -s com.oiloil.find.pro.evaluation >/dev/null 2>&1 || true
fi
security delete-generic-password -s com.oiloil.find.trial >/dev/null 2>&1 || true
```

替换为：

```bash
rm -rf "/Applications/Oil Find.app" "$HOME/Library/Application Support/Oil Find"
# Settings are the user's, not ours: keep them unless --purge was asked for. The Pro trial
# anchor goes with them, so a plain reinstall can never hand out a fresh trial.
if [[ "$PURGE" == true ]]; then
    defaults delete com.oiloil.find >/dev/null 2>&1 || true
    security delete-generic-password -s com.oiloil.find.pro.evaluation >/dev/null 2>&1 || true
fi
security delete-generic-password -s com.oiloil.find.trial >/dev/null 2>&1 || true
```

**Step 3: 确认脚本语法正确**

Run: `bash -n scripts/uninstall.sh`
Expected: 无输出，退出码 0。

**Step 4: 确认测试此时是失败的（它仍断言旧语义）**

Run: `python3 Tests/Scripts/test_uninstall.py`
Expected: FAIL。`test_default_deletes_all_settings_and_legacy_keychain_item` 会因为偏好未被清空而失败——这正是 Task 2 要修的东西。

**Step 5: 暂不提交**

Task 1 与 Task 2 必须一起提交：只改脚本不改测试，仓库会停在红的状态。直接进入 Task 2。

---

## Task 2: 按新语义重写卸载脚本测试

**Files:**
- Modify: `Tests/Scripts/test_uninstall.py`

**Step 1: 把默认偏好集提成模块级常量**

在 `Tests/Scripts/test_uninstall.py:7` 的 `class UninstallTests` 之前插入：

```python
DEFAULT_SETTINGS = {
    "trialStartedAt": 1790000000.5, "trialLastSeenAt": 1790003600.75,
    "licenseAPI": "http://example.com", "deviceFallbackID": "legacy", "pinyinEnabled": True,
}
```

并把 `run_uninstall` 里的内联字典（`:16-19`）换成 `DEFAULT_SETTINGS`：

```python
            state.write_text(json.dumps(initial if initial is not None else DEFAULT_SETTINGS))
```

**Step 2: 重写默认用例**

把 `:55-61` 的 `test_default_deletes_all_settings_and_legacy_keychain_item` 整个替换为：

```python
    def test_default_keeps_settings_and_deletes_only_the_legacy_keychain_item(self):
        result, values, calls = self.run_uninstall()
        self.assertEqual(result.returncode, 0, result.stderr)
        # Settings are the user's. A plain uninstall must not touch them.
        self.assertEqual(values, DEFAULT_SETTINGS)
        self.assertFalse(any(call[:2] == ["defaults", "delete"] for call in calls))
        self.assertIn(["security", "delete-generic-password", "-s", "com.oiloil.find.trial"], calls)
        self.assertNotIn(["security", "delete-generic-password", "-s", "com.oiloil.find.pro.evaluation"], calls)
        self.assertEqual(sum(call[0] == "rm" for call in calls), 1)
```

**Step 3: 重写 purge 用例**

把 `:63-72` 的 `test_default_preserves_both_pro_anchors_and_purge_removes_them` 整个替换为：

```python
    def test_purge_removes_settings_and_the_pro_anchor(self):
        initial = {"proEvaluationStartedAt": 1790000000.5, "proEvaluationLastSeenAt": 1790003600.75,
                   "proEvaluationEndedAt": 1790003600.75, "pinyinEnabled": True}
        result, values, calls = self.run_uninstall(initial=initial)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values, initial)
        result, values, calls = self.run_uninstall(("--purge",), initial)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values, {})
        self.assertIn(["security", "delete-generic-password", "-s", "com.oiloil.find.pro.evaluation"], calls)
        self.assertIn(["security", "delete-generic-password", "-s", "com.oiloil.find.trial"], calls)
```

**Step 4: 跑测试**

Run: `python3 Tests/Scripts/test_uninstall.py`
Expected: PASS，3 个用例全绿（含未被改动的 `test_decline_and_invalid_arguments_do_not_mutate_anything`）。

**Step 5: 提交**

```bash
git add scripts/uninstall.sh Tests/Scripts/test_uninstall.py
git commit -F - <<'EOF'
fix(uninstall): keep user settings unless --purge is asked for

Uninstalling deleted com.oiloil.find outright, so an uninstall/install
cycle silently reset every preference. The only thing that needed
protecting was the Pro trial anchor, which the script rescued by hand.

Invert the default: settings survive, and --purge deletes them along
with the trial anchor. The legacy authorization item is still removed
unconditionally, since the app cleans it up at launch anyway.

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
```

---

# 第 2 块：设置里的「清空所有配置」

## Task 3: 加一个可测试的清空函数

把清空逻辑放进 `OilFindCore`，而不是直接写在视图模型里——这样它可以在单元测试里被直接调用，不需要构造窗口。

**Files:**
- Modify: `Sources/OilFindCore/SettingsPreferences.swift`
- Test: `Tests/OilFindCoreTests/SettingsPreferencesTests.swift`（新建）

**Step 1: 写失败的测试**

创建 `Tests/OilFindCoreTests/SettingsPreferencesTests.swift`：

```swift
import XCTest
@testable import OilFindCore

final class SettingsPreferencesTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "OilFindClearSettings-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testClearAllRemovesUserSettings() {
        let defaults = suite()
        defaults.set(42, forKey: "hotKeyCode")
        defaults.set(true, forKey: "pinyinEnabled")
        defaults.set(["log"], forKey: "excludedExtensions")

        SettingsPreferences.clearAll(in: defaults)

        XCTAssertNil(defaults.object(forKey: "hotKeyCode"))
        XCTAssertNil(defaults.object(forKey: "pinyinEnabled"))
        XCTAssertNil(defaults.object(forKey: "excludedExtensions"))
    }

    func testClearAllKeepsTheProTrialAnchors() {
        let defaults = suite()
        defaults.set(1790000000.5, forKey: "proEvaluationStartedAt")
        defaults.set(1790003600.75, forKey: "proEvaluationLastSeenAt")
        defaults.set(1790003600.75, forKey: "proEvaluationEndedAt")

        SettingsPreferences.clearAll(in: defaults)

        // Wiping these would hand out a fresh Pro trial, which is not what "reset my settings" means.
        XCTAssertEqual(defaults.double(forKey: "proEvaluationStartedAt"), 1790000000.5)
        XCTAssertEqual(defaults.double(forKey: "proEvaluationLastSeenAt"), 1790003600.75)
        XCTAssertEqual(defaults.double(forKey: "proEvaluationEndedAt"), 1790003600.75)
    }

    func testClearAllKeepsTheLegacyCleanupStamp() {
        let defaults = suite()
        defaults.set(true, forKey: "legacyAuthorizationCleanupCompleted")

        SettingsPreferences.clearAll(in: defaults)

        // Otherwise the legacy authorization sweep runs again on the next launch.
        XCTAssertTrue(defaults.bool(forKey: "legacyAuthorizationCleanupCompleted"))
    }
}
```

**Step 2: 跑测试确认失败**

Run: `OILFIND_FREE=1 swift test --filter SettingsPreferencesTests`
Expected: 编译失败，`type 'SettingsPreferences' has no member 'clearAll'`。

**Step 3: 实现**

在 `Sources/OilFindCore/SettingsPreferences.swift` 的 `SettingsPreferences` 枚举里、`register` 之后插入：

```swift
    /// Restores every setting to its default. The Pro evaluation anchors and the legacy cleanup
    /// stamp survive: the first would hand out a fresh trial, and the second would re-run a
    /// one-time migration. Callers must relaunch afterwards — the app holds config snapshots in
    /// `SettingsModel`, `IndexManager` and the registered hot key, and re-reading all three in
    /// place is more ways to go wrong than restarting once.
    public static func clearAll(in defaults: UserDefaults = .standard) {
        let kept: Set<String> = [
            "proEvaluationStartedAt", "proEvaluationLastSeenAt", "proEvaluationEndedAt",
            "legacyAuthorizationCleanupCompleted",
        ]
        for key in defaults.dictionaryRepresentation().keys where !kept.contains(key) {
            defaults.removeObject(forKey: key)
        }
    }
```

**Step 4: 跑测试确认通过**

Run: `OILFIND_FREE=1 swift test --filter SettingsPreferencesTests`
Expected: PASS，3 个用例全绿。

**Step 5: 提交**

```bash
git add Sources/OilFindCore/SettingsPreferences.swift Tests/OilFindCoreTests/SettingsPreferencesTests.swift
git commit -F - <<'EOF'
feat(settings): add a clear-all that keeps the trial anchors

Reset every preference to its default, except the Pro evaluation
anchors and the legacy cleanup stamp: wiping the first would hand out a
fresh trial, and wiping the second would re-run a one-time migration.

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
```

---

## Task 4: 加界面文案

**Files:**
- Modify: `Sources/OilFindApp/L10n.swift:219`（在 `strings` 字典的收尾 `]` 之前插入）

**Step 1: 加四个键**

在 `Sources/OilFindApp/L10n.swift` 第 219 行的 `]` 之前插入：

```swift
        "settings.reset": ("重置", "Reset"),
        "settings.resetHint": ("恢复所有设置为默认值。索引会在重启后按默认范围重建。", "Restore every setting to its default. The index rebuilds to the default scope after a restart."),
        "settings.resetAll": ("清空所有配置…", "Clear All Settings…"),
        "settings.resetConfirm": ("所有设置将恢复为默认值，应用会随即重启。已建立的索引会按默认范围重建。", "Every setting will return to its default and the app will restart. The existing index is rebuilt to the default scope."),
```

**Step 2: 确认没有遗漏的中英对应**

Run: `grep -c 'settings.reset' Sources/OilFindApp/L10n.swift`
Expected: `4`

**Step 3: 确认能编译**

Run: `OILFIND_FREE=1 swift build`
Expected: 成功。

**Step 4: 提交**

```bash
git add Sources/OilFindApp/L10n.swift
git commit -F - <<'EOF'
feat(settings): add the copy for clearing all settings

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
```

---

## Task 5: 设置窗口加「清空所有配置」区块

**Files:**
- Modify: `Sources/OilFindApp/SettingsWindow.swift:82-85`（`contentHeight`）
- Modify: `Sources/OilFindApp/SettingsWindow.swift:389-391` 之后（新增 Section）

**Step 1: 让高度公式容纳新的一节**

把 `Sources/OilFindApp/SettingsWindow.swift:82-85` 的：

```swift
    var contentHeight: CGFloat {
        min(600, 880 - (granted ? 30 : 0) + CGFloat(max(0, excludedPaths.count - 1)) * 32
            + (loginError == nil ? 0 : 40) + (shortcutError == nil ? 0 : 28))
    }
```

改为（新增的 Reset 一节含标题、按钮和一行说明，按现有每节约 62 pt 的换算加 62）：

```swift
    var contentHeight: CGFloat {
        min(600, 942 - (granted ? 30 : 0) + CGFloat(max(0, excludedPaths.count - 1)) * 32
            + (loginError == nil ? 0 : 40) + (shortcutError == nil ? 0 : 28))
    }
```

**Step 2: 加 Section**

在 `Sources/OilFindApp/SettingsWindow.swift` 的 `excludedTypes` Section（收尾在 `:391` 的 `footer:` 行）之后、`:392` 的 `}`（`Form` 的收尾）之前插入：

```swift
            Section {
                Button(L10n.text("settings.resetAll"), action: model.confirmClearAllSettings)
                    .foregroundStyle(.red)
            } header: { Text(L10n.text("settings.reset")) }
              footer: { hint(L10n.text("settings.resetHint")) }
```

**Step 3: 确认能编译（此时会失败，`confirmClearAllSettings` 还不存在）**

Run: `OILFIND_FREE=1 swift build`
Expected: 编译失败，`value of type 'SettingsModel' has no member 'confirmClearAllSettings'`。这正是 Task 6 要补的。

**Step 4: 不提交**

Task 5 与 Task 6 一起提交，避免仓库停在编译不过的状态。

---

## Task 6: 实现确认弹窗与重启

**Files:**
- Modify: `Sources/OilFindApp/SettingsWindow.swift`（`SettingsModel` 内，`rebuild()` 之后，约 `:185`）

**Step 1: 加方法**

在 `Sources/OilFindApp/SettingsWindow.swift` 的 `func rebuild()` 之后插入：

```swift
    /// Destructive and irreversible, so it goes through a sheet first. The restart is not a
    /// convenience: `SettingsModel`, `IndexManager` and the registered hot key each hold their own
    /// snapshot of the configuration, and re-reading all three in place is more ways to go wrong
    /// than relaunching once.
    func confirmClearAllSettings() {
        guard !snapshot, let window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("settings.resetAll")
        alert.informativeText = L10n.text("settings.resetConfirm")
        alert.addButton(withTitle: L10n.text("settings.resetAll"))
        alert.addButton(withTitle: L10n.text("action.cancel"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            SettingsPreferences.clearAll(in: .standard)
            Self.relaunch()
        }
    }

    /// Quits and starts a fresh instance. The relaunch is detached so it survives this process
    /// exiting; `open -n` is what makes it a new instance rather than a request to the dying one.
    private static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The bundle path is a positional argument, never interpolated into shell source.
        task.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open -n \"$2\"",
                          "oilfind-relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        NSApp.terminate(nil)
    }
```

**注意：** `window` 在这个文件里是 `SettingsModel` 的一个属性（构造时注入），确认它在该作用域可见；如果 `SettingsModel` 上没有 `window`，改用 `NSApp.keyWindow`。先读 `Sources/OilFindApp/SettingsWindow.swift` 确认再写。

**Step 2: 编译**

Run: `OILFIND_FREE=1 swift build`
Expected: 成功。

**Step 3: 更新设置窗口快照测试**

Run: `OILFIND_FREE=1 swift test --filter 'UITests' 2>&1 | tail -40`
Expected: 可能有快照测试因为新增了一节而失败。逐个查看失败断言，按新高度更新期望值。**不要**为了让测试过而改回 `contentHeight`。

**Step 4: 全量测试**

Run: `OILFIND_FREE=1 swift test`
Expected: 全绿。

**Step 5: 提交**

```bash
git add Sources/OilFindApp/SettingsWindow.swift Tests/OilFindUITests/
git commit -F - <<'EOF'
feat(settings): add a clear-all-settings action that restarts

Clearing settings was previously only reachable by uninstalling. Put it
behind a confirmation sheet in the settings window and relaunch
afterwards, because the configuration is snapshotted in three places
that would each need re-reading in place.

The action keeps the Pro trial anchors, so it cannot be used to reset a
trial.

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
```

---

# 第 3 块：内容索引旁路重建（3c）

## Task 7: 先把文件索引的不变量固定住

文件索引这边**不需要改代码**——`IndexManager.scan()` 只在扫描结束、reconcile 完成后才发布新 store（`Sources/OilFindCore/IndexManager.swift:272`），所以 rescan 期间旧 store 一直在服务搜索。补一个测试把这个不变量钉死，防止以后有人把发布时机提前。

**Files:**
- Test: `Tests/OilFindCoreTests/M7StorageTests.swift`（追加）

**Step 1: 写测试**

在 `Tests/OilFindCoreTests/M7StorageTests.swift` 末尾（最后一个 `}` 之前）追加：

```swift
    func testRescanKeepsThePreviousStoreSearchableUntilTheNewOnePublishes() throws {
        try withTempDirectory { directory in
            let url = directory.appendingPathComponent("index.oilfind")
            let config = IndexConfig(rootPath: directory.path)
            let manager = IndexManager(config: config, dbURL: url, settingsDefaults: nil)

            let ready = expectation(description: "ready")
            manager.onStateChange = { if $0 == .ready { ready.fulfill() } }
            manager.start()
            wait(for: [ready], timeout: 30)

            let before = try XCTUnwrap(manager.store)
            XCTAssertGreaterThan(before.count, 0)

            let rescanned = expectation(description: "rescanned")
            manager.onStateChange = { if $0 == .ready && manager.isRescanning == false { rescanned.fulfill() } }
            manager.rescan()

            // The old catalog must keep answering while the replacement is being built: a search
            // that returns nothing during a rescan looks exactly like an empty index.
            XCTAssertNotNil(manager.store)
            XCTAssertTrue(manager.store === before)

            wait(for: [rescanned], timeout: 60)
            XCTAssertNotNil(manager.store)
        }
    }
```

**注意：** 先读 `Tests/OilFindCoreTests/M7StorageTests.swift` 与现有 `IndexManager` 测试（`grep -rn "IndexManager(" Tests/`）确认 `onStateChange` 的调用约定和 `wait` 的用法是否与此一致；不一致就照现有测试的写法改。`settingsDefaults: nil` 是为了不碰真实的 `UserDefaults`。

**Step 2: 跑测试**

Run: `OILFIND_FREE=1 swift test --filter testRescanKeepsThePreviousStoreSearchable`
Expected: PASS。若失败，说明不变量并不成立——**停下来**，回到设计文档第 5.2 节重新评估，不要直接改生产代码去迎合测试。

**Step 3: 提交**

```bash
git add Tests/OilFindCoreTests/M7StorageTests.swift
git commit -F - <<'EOF'
test(index): pin that a rescan keeps the old store searchable

The replacement is published only after the scan reconciles, so the
previous catalog answers queries throughout. Pin that, because
publishing earlier would make a rescan look like an empty index.

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
```

---

## Task 8: 让 `ContentIndex` 报告「需要重建」而不是就地 DROP

**Files:**
- Modify: `Sources/OilFindApp/ContentSearch/ContentIndex.swift:137-215`（`migrate()`）
- Test: `Tests/OilFindUITests/ContentIndexSchemaTests.swift:26-41`

**Step 1: 改测试，把「就地重建」改成「报告需要重建」**

把 `Tests/OilFindUITests/ContentIndexSchemaTests.swift:26-41` 的 `testRebuildsWhenStoredVersionIsStale` 整个替换为：

```swift
    func testStaleVersionIsReportedInsteadOfDroppedInPlace() throws {
        let url = tempURL(); defer { removeDatabase(url) }
        do {
            let sql = try AITopicSQL(url)
            try sql.run("CREATE TABLE files(id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE)")
            // Seed a stale version explicitly so the mismatch is forced by the stamp.
            try sql.run("PRAGMA user_version = \(ContentIndex.schemaVersion - 1)")
        }
        let index = try ContentIndex(url: url)
        // Reporting rather than dropping: the caller rebuilds beside this database so the old one
        // keeps answering searches until the replacement is ready.
        XCTAssertTrue(index.needsRebuild)
        let sql = try AITopicSQL(url, readOnly: true)
        XCTAssertEqual(try sql.columns("files"), ["id", "path"])
        let probe = try sql.prepare("PRAGMA user_version")
        XCTAssertTrue(try probe.next())
        XCTAssertEqual(probe.int(0), Int64(ContentIndex.schemaVersion - 1))
    }

    func testCurrentVersionIsNotFlaggedForRebuild() throws {
        let url = tempURL(); defer { removeDatabase(url) }
        do { _ = try ContentIndex(url: url) }
        let index = try ContentIndex(url: url)
        XCTAssertFalse(index.needsRebuild)
    }
```

**Step 2: 跑测试确认失败**

Run: `OILFIND_FREE=1 swift test --filter ContentIndexSchemaTests`
Expected: 编译失败，`value of type 'ContentIndex' has no member 'needsRebuild'`。

**Step 3: 实现**

在 `Sources/OilFindApp/ContentSearch/ContentIndex.swift` 的 `ContentIndex` 类里，`readOnly` 属性旁加：

```swift
    /// True when the file on disk was stamped with a different schema version. The caller rebuilds
    /// beside it rather than dropping the tables here, so content search keeps answering from the
    /// old database until the replacement is complete.
    private(set) var needsRebuild = false
```

然后把 `migrate()`（`:137-215`）的可写分支改成只探测、不 DROP：

```swift
    private func migrate() throws {
        if readOnly {
            // A read-only instance must not run against an empty or stale database: every search
            // would otherwise fail with "no such table: chunks" instead of a clear error.
            guard try storedVersion() == Int64(Self.schemaVersion) else {
                throw ContentIndexError.database("Content index is not schema version \(Self.schemaVersion)")
            }
            return
        }
        // Neither pragma can run inside a transaction. A failed journal_mode conversion is reported
        // by returning the current mode, while a contended one raises SQLITE_BUSY because this
        // pragma does not invoke the busy handler. Either way indexing must still proceed with
        // serialised readers and writers, so record usesWAL instead of failing the open.
        do {
            let journal = try sql.prepare("PRAGMA journal_mode=WAL")
            usesWAL = (try step(journal)) && journal.text(0).lowercased() == "wal"
            sqlite3_reset(journal.handle)
        } catch {
            guard sqlite3_errcode(sql.db) == SQLITE_BUSY else { throw error }
            usesWAL = false
        }
        try run("PRAGMA foreign_keys=ON")
        // BEGIN IMMEDIATE serialises two writable connections opening the same fresh database: the
        // loser waits, then re-probes the version below and skips the winner's build.
        try beginImmediate()
        do {
            let version = try storedVersion()
            if version == 0 {
                // A fresh file: build the schema here, there is nothing to preserve.
                try createSchema()
                try run("PRAGMA user_version = \(Self.schemaVersion)")
            } else if version != Int64(Self.schemaVersion) {
                // A stale file: leave it intact and let the caller rebuild beside it. Dropping the
                // tables here would blank content search for the whole rebuild, which can run for
                // hours on a large corpus.
                needsRebuild = true
            }
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    /// The canonical schema. Shared by the fresh-file path and the beside-rebuild path so the two
    /// cannot drift.
    func createSchema() throws {
        try run("""
            DROP TRIGGER IF EXISTS chunk_postings_delete;
            DROP TABLE IF EXISTS chunk_fts;
            DROP TABLE IF EXISTS chunks;
            DROP TABLE IF EXISTS files;
            """)
        try run("""
            CREATE TABLE files(
                -- AUTOINCREMENT: chunks reference files.id; rowid reuse after a delete would let a stale chunk attach to a new file.
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                path TEXT NOT NULL UNIQUE,
                size INTEGER NOT NULL,
                mtime INTEGER NOT NULL,
                -- Sub-second part of the modification time. Without it a second edit inside
                -- the same second that leaves the size alone is indistinguishable from the
                -- first, and the stale text stays searchable.
                mtime_nsec INTEGER NOT NULL,
                kind INTEGER NOT NULL,
                parser TEXT NOT NULL,
                revision INTEGER NOT NULL DEFAULT 1);
            CREATE TABLE chunks(
                -- AUTOINCREMENT: FTS postings are keyed by chunks.id; rowid reuse after a delete would let a stale posting attach to a new chunk.
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                file INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                label TEXT NOT NULL,
                folded BLOB NOT NULL,
                -- UNCOMPRESSED length of folded, so unpack is one exact pass. The bound
                -- matches ContentCompression.maxBodyBytes.
                bytes INTEGER NOT NULL CHECK(bytes BETWEEN 0 AND 16777216),
                -- Also covers WHERE file=? lookups, so no separate index on (file) is needed.
                UNIQUE(file, ordinal));
            CREATE VIRTUAL TABLE chunk_fts USING fts5(grams, content='', contentless_delete=1, detail=none);
            -- Postings have no cascade of their own; this covers every path that deletes
            -- a chunk, including the file cascade.
            CREATE TRIGGER chunk_postings_delete AFTER DELETE ON chunks BEGIN
                DELETE FROM chunk_fts WHERE rowid = old.id;
            END;
            """)
    }
```

**注意：** `createSchema()` 必须去掉 `DROP TABLE IF EXISTS` 之外的一切改动，逐字对照原来 `migrate()` 里的 SQL，**一字不改**——`Tests/OilFindUITests/ContentIndexSchemaTests.swift:14-25` 的 `testOpenCreatesTablesAndIsIdempotent` 会精确断言表集合。

**Step 4: 跑测试**

Run: `OILFIND_FREE=1 swift test --filter ContentIndexSchemaTests`
Expected: 全绿。

**Step 5: 提交**

```bash
git add Sources/OilFindApp/ContentSearch/ContentIndex.swift Tests/OilFindUITests/ContentIndexSchemaTests.swift
git commit -F - <<'EOF'
refactor(content): report a stale schema instead of dropping it

Opening a database stamped with an older schema dropped every table on
the spot, so content search went blank for the whole rebuild — which
can run for hours. Detect the mismatch and let the caller decide.

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
```

---

## Task 9: `ContentManager` 旁路建新库

**Files:**
- Modify: `Sources/OilFindApp/ContentSearch/ContentManager.swift:50-73`（`init`）

**Step 1: 加旁路库路径与打开逻辑**

在 `Sources/OilFindApp/ContentSearch/ContentManager.swift` 的 `init` 之前加：

```swift
    /// The database a rebuild writes into. The live one keeps answering searches until the
    /// replacement is complete, so a schema change never leaves the user with no content hits.
    static func rebuildURL(for indexURL: URL) -> URL {
        indexURL.deletingLastPathComponent().appendingPathComponent("index.next.sqlite")
    }
```

然后把 `init` 里这段（`:55-67`）：

```swift
        var writer: ContentIndex?
        var reader: ContentIndex?
        var indexer: ContentIndexer?
        if let indexURL {
            // Open the writer first: it creates and migrates the schema the reader requires. Both
            // opens happen on the calling thread (main, at startup) and are bounded, because
            // `ContentIndex` gives up on the migration lock after 2 s, so a concurrent rebuild can
            // slow startup but cannot hang it.
            writer = try? ContentIndex(url: indexURL)
            reader = try? ContentIndex(url: indexURL, readOnly: true)
            if let writer {
                indexer = ContentIndexer(index: writer, parsers: [TextParser(), ImageOCRParser()])
            }
        }
```

替换为：

```swift
        var writer: ContentIndex?
        var reader: ContentIndex?
        var indexer: ContentIndexer?
        if let indexURL {
            // A leftover staging database means a previous rebuild was interrupted before the
            // swap. The live one is intact, so dropping the partial staging file loses nothing.
            let staging = Self.rebuildURL(for: indexURL)
            try? FileManager.default.removeItem(at: staging)
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: staging.path + suffix))
            }
            // Probe the live database first: it must stay open for reads either way.
            let probe = try? ContentIndex(url: indexURL)
            if probe?.needsRebuild == true {
                // Build the replacement beside the live database. `reader` keeps pointing at the
                // live one, so searches keep working while the new index fills up.
                writer = try? ContentIndex(url: staging)
                if let writer {
                    try? writer.createSchema()
                    try? writer.sql.run("PRAGMA user_version = \(ContentIndex.schemaVersion)")
                }
                reader = try? ContentIndex(url: indexURL, readOnly: true)
                rebuildInProgress = writer != nil
            } else {
                writer = probe
                reader = try? ContentIndex(url: indexURL, readOnly: true)
            }
            if let writer {
                indexer = ContentIndexer(index: writer, parsers: [TextParser(), ImageOCRParser()])
            }
        }
```

并在类属性区（`private var pendingChange = false` 附近）加：

```swift
    /// True while a rebuild is filling the staging database. Set in `init`, cleared by the swap.
    private var rebuildInProgress = false
```

**注意：** `probe` 在非重建路径下直接当 writer 用，所以它**必须**是同一个连接；`ContentIndex(url:)` 可写构造已经把 schema 建好了（`version == 0` 分支）。先读 `Sources/OilFindApp/ContentSearch/ContentManager.swift` 全文确认没有其他地方持有 `writer` 的假设。

**Step 2: 编译**

Run: `OILFIND_FREE=1 swift build`
Expected: 成功。

**Step 3: 提交**

```bash
git add Sources/OilFindApp/ContentSearch/ContentManager.swift
git commit -F - <<'EOF'
feat(content): rebuild a stale index beside the live one

Open the staging database next to the live one when the schema is
stale, so the old index keeps serving searches until the new one is
ready. A leftover staging file from an interrupted rebuild is dropped
on sight; the live database is untouched either way.

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
```

---

## Task 10: 重建完成后原子替换

**Files:**
- Modify: `Sources/OilFindApp/ContentSearch/ContentManager.swift`（`start()` 的完成回调，约 `:138-149`）

**Step 1: 在同步 pass 完成时换库**

在 `Sources/OilFindApp/ContentSearch/ContentManager.swift` 的 `start()` 里，`DispatchQueue.main.async {` 那段（`:137-149`）的 `guard !self.isCancelled(mine) else { return }` 之后、`self.progress = nil` 之前插入：

```swift
                // A completed pass over the staging database means the replacement is whole.
                if self.rebuildInProgress { self.swapInRebuild() }
```

**Step 2: 实现替换**

在 `enqueueClear()` 之前插入：

```swift
    /// Replaces the live database with the staging one, then reopens both connections. The rename
    /// is atomic, so a reader either sees the old file or the new one; the reopen is what makes
    /// the provider switch to it, because the old read-only handle would otherwise keep serving
    /// the unlinked inode.
    private func swapInRebuild() {
        guard let indexURL, let staging = writer.map({ _ in Self.rebuildURL(for: indexURL) }) else { return }
        rebuildInProgress = false
        queue.async { [weak self] in
            guard let self else { return }
            // Close the writer's handle before the rename so no WAL frame is written after it.
            self.writer?.close()
            do {
                for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: staging.path + suffix) {
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: indexURL.path + suffix))
                    try FileManager.default.moveItem(at: URL(fileURLWithPath: staging.path + suffix),
                                                     to: URL(fileURLWithPath: indexURL.path + suffix))
                }
                try FileManager.default.replaceItemAt(indexURL, withItemAt: staging)
            } catch {
                // The live database is still whole; keep serving from it and retry on next launch.
                return
            }
            DispatchQueue.main.async {
                self.reader?.close()
                self.reader = try? ContentIndex(url: indexURL, readOnly: true)
                self.provider.index = self.reader
                self.count = (try? self.reader?.count()) ?? 0
                self.diskBytes = Self.diskBytes(at: indexURL)
            }
        }
    }
```

**注意：** 这段依赖三个可能不存在的 API：`ContentIndex.close()`、`ContentSearchProvider.index` 的可写性，以及 `writer` / `reader` 是否允许被重新赋值（它们目前是 `let`）。**先读** `Sources/OilFindApp/ContentSearch/ContentIndex.swift` 与 `ContentSearchProvider` 的定义，然后：

- 若 `ContentIndex` 没有 `close()`，加上它（`sqlite3_close` 或包装层的等价物）。
- 把 `private let writer: ContentIndex?` / `private let reader: ContentIndex?` 改成 `private var`。
- 若 `ContentSearchProvider.index` 不可写，改为提供一个 `func setIndex(_:)`。

不要照抄这段代码——它是接口意图，不是最终形态。改完把实际用到的接口名回填进提交信息。

**Step 3: 编译并跑内容搜索测试**

Run: `OILFIND_FREE=1 swift test --filter 'Content'`
Expected: 全绿。

**Step 4: 提交**

```bash
git add Sources/OilFindApp/ContentSearch/
git commit -F - <<'EOF'
feat(content): swap the rebuilt index in atomically

Rename the staging database over the live one once a pass has filled
it, then reopen both connections so the provider stops serving the
unlinked inode. A failed rename leaves the live database in place and
retries on the next launch.

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
```

---

## Task 11: 覆盖重建的边界

**Files:**
- Test: `Tests/OilFindUITests/ContentManagerTests.swift`（追加）

**Step 1: 写三个测试**

在 `Tests/OilFindUITests/ContentManagerTests.swift` 末尾追加（**先读该文件确认现有的临时目录与 `UserDefaults` suite 辅助方法名，照它们的写法写**）：

```swift
    func testAStaleSchemaKeepsTheOldIndexSearchableUntilTheSwap() throws {
        // 1. 建一个旧 schema 的库，写入一条记录。
        // 2. 用 ContentManager 打开它。
        // 3. 断言：搜索仍能命中那条旧记录（即 provider 还指着旧库）。
        // 4. 断言：staging 库存在，且为空。
    }

    func testALeftoverStagingDatabaseIsDiscardedOnOpen() throws {
        // 1. 预置一个 index.next.sqlite 垃圾文件。
        // 2. 用 ContentManager 打开。
        // 3. 断言：垃圾文件已被删除，live 库不受影响。
    }

    func testAFailedSwapLeavesTheLiveIndexInPlace() throws {
        // 1. 制造替换失败（例如把 indexURL 所在目录设为只读）。
        // 2. 触发 swap。
        // 3. 断言：live 库仍可搜索，内容未丢。
    }
```

**Step 2: 逐个实现并跑**

Run: `OILFIND_FREE=1 swift test --filter ContentManagerTests`
Expected: 全绿。三个测试各自先在 `git stash` 掉 Task 9/10 的实现后确认会失败，再确认实现后通过——否则它们没在测东西。

**Step 3: 提交**

```bash
git add Tests/OilFindUITests/ContentManagerTests.swift
git commit -F - <<'EOF'
test(content): cover the beside-rebuild edges

Cover the three ways the swap can go wrong: the old index must stay
searchable while the replacement fills, a leftover staging file must be
discarded, and a failed rename must leave the live index intact.

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
```

---

# 第 4 块：文件索引的格式扩展位（3b）

> **风险提示。** 这一块改的是索引文件格式本身。写扩展表和读扩展表**必须在同一个提交里**落地——中间态正好会制造出本次要消除的故障。
>
> **另一件必须先说清的事：** 这一块落地后**今天没有任何字段会用到它**。它的价值是从下一次格式变更起兑现的——那时追加一个字段不再需要 bump 版本、不再让所有用户重建索引。设计文档里已经写明并得到确认。如果你不接受「现在为将来付一次成本」，这一块可以整个跳过，前三块是独立可用的。

## Task 12: 定义扩展表的读写

**Files:**
- Modify: `Sources/OilFindCore/IndexStore+Persistence.swift`
- Test: `Tests/OilFindCoreTests/M7StorageTests.swift`（追加）

**Step 1: 写失败的测试**

在 `Tests/OilFindCoreTests/M7StorageTests.swift` 末尾追加：

```swift
    func testExtensionSectionsSurviveARoundTrip() throws {
        try withTempDirectory { directory in
            let url = directory.appendingPathComponent("ext.idx")
            let store = persistenceStore()
            try store.save(to: url.path, extensions: [0: Data("hello".utf8), 3: Data("world!".utf8)])

            let raw = try Data(contentsOf: url)
            let loaded = try XCTUnwrap(IndexStore.load(from: url.path))
            XCTAssertEqual(loaded.extensionSections[0], Data("hello".utf8))
            XCTAssertEqual(loaded.extensionSections[3], Data("world!".utf8))
            // The core payload is unchanged: the sections ride after it, they do not displace it.
            XCTAssertEqual(raw.count, try Data(contentsOf: url).count)
        }
    }

    func testAnUnknownExtensionIdIsIgnored() throws {
        try withTempDirectory { directory in
            let url = directory.appendingPathComponent("unknown.idx")
            let store = persistenceStore()
            try store.save(to: url.path, extensions: [0: Data("known".utf8)])
            // Rewrite the registered id to one this build has never heard of.
            var raw = try Data(contentsOf: url)
            put32(99, at: 132, in: &raw)
            try raw.write(to: url)

            // Ignoring the section, not rejecting the file: that is the whole point of the table.
            let loaded = try XCTUnwrap(IndexStore.load(from: url.path))
            XCTAssertEqual(loaded.count, store.count)
            XCTAssertTrue(loaded.extensionSections.isEmpty)
        }
    }
```

**Step 2: 跑测试确认失败**

Run: `OILFIND_FREE=1 swift test --filter testExtensionSections`
Expected: 编译失败，`extra argument 'extensions' in call` / `no member 'extensionSections'`。

**Step 3: 实现**

在 `Sources/OilFindCore/IndexStore+Persistence.swift` 的 `save` / `load` 上加重载与扩展表处理。完整改动：

```swift
public enum IndexPersistenceError: Error { case noSpace, io(Int32) }
extension IndexStore {
    /// Extension sections ride after the core payload. Purely additive format changes register an
    /// id here instead of bumping the format version, so a build that predates the field ignores
    /// it and still reads the catalog. Ids are permanent: retire one by writing it empty, never by
    /// reusing the number for something else.
    private static let extensionTableOffset = 128
    private static let extensionTableCapacity = 7

    private var fileLength: Int { 256 + rootPath.utf8.count + (count+1)*4 + count*4*4 + count*3 + namesLen + (altCount+1)*4 + altCount*4 + altLen }

    public func save(to path: String) throws { try save(to: path, extensions: [:]) }

    public func save(to path: String, extensions: [UInt32: Data]) throws {
        try read { try saveLocked(to: path, extensions: extensions) }
    }

    internal func saveSnapshot(to path: String) throws -> UInt64 {
        try read { try saveLocked(to: path, extensions: [:]); return version }
    }

    private func saveLocked(to path: String, extensions: [UInt32: Data]) throws {
        let sections = extensions.sorted { $0.key < $1.key }
        precondition(sections.count <= Self.extensionTableCapacity, "Too many extension sections")
        let coverageData = try JSONEncoder().encode(coverage)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let payloadLength = fileLength + sections.reduce(0) { $0 + $1.value.count }
        var fs = statfs()
        if statfs(dir, &fs) != 0 { throw IndexPersistenceError.io(errno) }
        if UInt64(fs.f_bavail) * UInt64(fs.f_bsize) < UInt64(payloadLength) * 2 { throw IndexPersistenceError.noSpace }
        let tmp = path + ".tmp.\(getpid())"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        if fd < 0 { throw IndexPersistenceError.io(errno) }
        defer { close(fd); unlink(tmp) }
        func writeBytes(_ pointer: UnsafeRawPointer, _ length: Int) throws {
            var offset = 0
            while offset < length {
                let n = Darwin.write(fd, pointer.advanced(by: offset), length - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { throw IndexPersistenceError.io(errno) }
                offset += n
            }
        }
        var header = [UInt8](repeating: 0, count: 256)
        header.replaceSubrange(0..<8, with: Array("SIFTIDX\0".utf8))
        func put32(_ n: UInt32, _ pos: Int) { for i in 0..<4 { header[pos+i] = UInt8(truncatingIfNeeded: n >> (i*8)) } }
        func put64(_ n: UInt64, _ pos: Int) { for i in 0..<8 { header[pos+i] = UInt8(truncatingIfNeeded: n >> (i*8)) } }
        put32(4, 8); put32(UInt32(coverageData.count), 116); put32(UInt32(count), 12); put64(UInt64(namesLen), 16); put32(UInt32(altCount), 24); put32(UInt32(rootPath.utf8.count), 28)
        put64(UInt64(altLen), 32); put64(lastEventId, 40); put64(configFingerprint, 48); put64(scanFinishedAt, 56)
        for (i,b) in fsEventsUUID.utf8.prefix(40).enumerated() { header[64+i] = b }
        put64(scopeFingerprint, 120)
        put32(homeIndex, 104); put32(deletedCount, 108); header[112] = caseSensitiveNames ? 1 : 0
        // Extension table: count, then (id, absolute offset, length) per section. Sections follow
        // the coverage payload in id order.
        put32(UInt32(sections.count), Self.extensionTableOffset)
        var sectionOffset = payloadLength - sections.reduce(0) { $0 + $1.value.count }
        for (i, section) in sections.enumerated() {
            let base = Self.extensionTableOffset + 4 + i * 16
            put32(section.key, base); put64(UInt64(sectionOffset), base + 4); put64(UInt64(section.value.count), base + 12)
            sectionOffset += section.value.count
        }
        try header.withUnsafeBytes { try writeBytes($0.baseAddress!, 256) }
        let root = Array(rootPath.utf8); try root.withUnsafeBytes { try writeBytes($0.baseAddress!, root.count) }
        try writeBytes(nameOff, (count+1)*4); try writeBytes(parent, count*4); try writeBytes(sizeC, count*4); try writeBytes(mtime, count*4); try writeBytes(mtimeNsec, count*4)
        try writeBytes(flags, count); try writeBytes(depth, count); try writeBytes(kind, count); try writeBytes(names, namesLen)
        try writeBytes(altOff, (altCount+1)*4); try writeBytes(altOwner, altCount*4); try writeBytes(altNames, altLen)
        try coverageData.withUnsafeBytes { try writeBytes($0.baseAddress!, $0.count) }
        for section in sections { try section.value.withUnsafeBytes { try writeBytes($0.baseAddress!, $0.count) } }
        if fsync(fd) != 0 { throw IndexPersistenceError.io(errno) }
        if rename(tmp, path) != 0 { throw IndexPersistenceError.io(errno) }
    }
```

**注意：** `sectionOffset` 的初值用的是 `payloadLength` 减去扩展段总长，也就是核心载荷的末尾——即 `256 + root + … + coverage`。核对一下这与 `fileLength` 的定义一致；不一致就以 `fileLength` 为准重写这两行。

**Step 4: 读端**

`load` 需要按上面的布局读回扩展表，并且把长度校验从 `expected == data.count` 改为 `expected + Σlength == data.count`。改动：

```swift
    public static func load(from path: String) -> IndexStore? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe), data.count >= 256 else { return nil }
        return data.withUnsafeBytes { raw -> IndexStore? in
            let p = raw.bindMemory(to: UInt8.self)
            guard p.prefix(8).elementsEqual(Array("SIFTIDX\0".utf8)) else { return nil }
            func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(p[at+$1]) << ($1*8) } }
            func u64(_ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(p[at+$1]) << ($1*8) } }
            // Version 4 added the sub-second mtime array. Older versions are rejected rather than
            // migrated: the entry layout differs, so a version 2 or 3 file would misparse.
            guard u32(8) == 4, p[112] <= 1 else { return nil }
            let extensionCount = Int(u32(128))
            guard extensionCount <= 7 else { return nil }
            var known: [UInt32: Range<Int>] = [:]
            var extensionBytes = 0
            for i in 0..<extensionCount {
                let base = 128 + 4 + i * 16
                let id = u32(base)
                guard let offset = Int(exactly: u64(base + 4)), let length = Int(exactly: u64(base + 12)),
                      offset >= 256, length >= 0, offset + length <= data.count else { return nil }
                extensionBytes += length
                // Unknown ids are skipped, not rejected: that is what keeps a newer catalog readable
                // by an older build.
                if Self.knownExtensionIds.contains(id) { known[id] = offset..<(offset + length) }
            }
            // …（原有的 count / namesLen / altCount / rootLen / altLen 解析与 expected 累加保持不变）…
            let coverageLength = Int(u32(116))
            guard coverageLength <= 200_000, addExpected(coverageLength) else { return nil }
            // Extension sections ride after the core payload, so the exact-length check has to
            // account for them.
            guard expected + extensionBytes == data.count else { return nil }
            // …（原有的 copy / validate 逻辑保持不变）…
            for (id, range) in known { s.extensionSections[id] = Data(p[range]) }
            return s
        }
    }
```

并在 `IndexStore` 上加：

```swift
    /// Registered extension section ids, read back on load. Ids are permanent: retire one by
    /// writing it empty, never by reusing the number for something else.
    static let knownExtensionIds: Set<UInt32> = []
    /// Extension payloads carried by the file. Empty until the first field registers an id.
    public internal(set) var extensionSections: [UInt32: Data] = [:]
```

**注意：** `knownExtensionIds` 目前是**空集**——这正是「今天没有字段用它」的直接体现。`testExtensionSectionsSurviveARoundTrip` 需要它非空才能通过；测试里用 `@testable import` 直接给这个 `static var` 赋值，或者在测试用 `#if DEBUG` 下改成 `static var`。**先想清楚这一点再动手**，不要为了让测试过而把生产代码里的集合填上假 id。

**Step 5: 跑测试**

Run: `OILFIND_FREE=1 swift test --filter 'M7StorageTests|testExtension'`
Expected: 全绿，且原有的 `testT71PersistenceRejectsMalformedStructure`（它断言 `original[8] == 4`）仍然通过。

**Step 6: 提交**

```bash
git add Sources/OilFindCore/IndexStore+Persistence.swift Tests/OilFindCoreTests/M7StorageTests.swift
git commit -F - <<'EOF'
feat(index): add extension sections for additive format changes

Bumping the format version rejects every existing catalog, so a field
that only appends forced every user to rescan. Register additive
changes in the reserved header area instead: an older build ignores the
sections it does not know and still reads the file.

Nothing registers an id yet; the first consumer lands with the next
additive field.

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
```

---

## Task 13: 把约定写进架构文档

**Files:**
- Modify: `docs/ARCHITECTURE.md`

**Step 1: 记录约定**

在 `docs/ARCHITECTURE.md` 里讲索引持久化的那一节（`grep -n "格式 3\|预留头字段\|指纹" docs/ARCHITECTURE.md` 定位，约 `:227`）之后补一段：

```markdown
索引文件头 `128..<256` 是扩展表：一个 `u32` 计数，后跟若干 `(id, offset, length)`，扩展段紧跟在核心载荷之后。**纯追加**的格式变更在这里登记一个 id，不 bump 格式版本，因此旧版本仍能读取整个目录并忽略不认识的段。id 一经分配即永久固定，废弃时写空段、不复用编号。格式版本只在条目布局**重排**时才 bump。
```

**Step 2: 确认文档里没有残留的旧说法**

Run: `grep -n "扩展表\|预留头字段" docs/ARCHITECTURE.md`
Expected: 能看到新增段落，且原有「格式 3 的预留头字段（偏移 120）」那句仍然成立（那是 `scopeFingerprint`，与扩展表无关）。

**Step 3: 提交**

```bash
git add docs/ARCHITECTURE.md
git commit -F - <<'EOF'
docs(index): record the extension section convention

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
```

---

## 收尾

全部任务完成后：

```sh
OILFIND_FREE=1 swift build
OILFIND_FREE=1 swift test
python3 Tests/Scripts/test_uninstall.py
python3 Tests/Scripts/test_open_core.py
```

四条命令都必须通过。然后在真机上手动验证一次「清空所有配置」：打开设置 → 点「清空所有配置…」→ 确认 → 应用重启 → 检查热键、拼音、排除扩展名都回到默认值，且索引按默认范围重建。这一步是自动化测试覆盖不到的，必须手做。

---

## 执行记录

**第 1 块（Task 1-2）已完成，提交 `1510e96`。** 与计划有以下偏差，均来自代码质量审查：

1. **Task 2 的 `rm` 断言改写。** 计划沿用了旧测试的 `assertEqual(sum(call[0] == "rm" ...), 1)`，审查者用变异测试证明它断言的是**调用次数**而非**删除路径**：去掉 `Application Support/Oil Find` 会静默通过，而等价的「拆成两次 `rm`」反而失败。改为对 `rm` 参数取精确集合（过滤 `-` 前缀的 flag）。复审者独立重跑变异确认：去掉路径会失败、拆成两次调用会通过。
2. **新增 CI 步骤。** `.github/workflows/ci.yml` 原本不跑 `test_uninstall.py`，而这条测试是新的卸载默认值唯一的守卫。已加 `Check uninstall script` 步骤。**这一项超出计划原本的文件清单**，是有意为之。
3. **文案去歧义。** 被删的 `com.oiloil.find.trial` 与保留的「Pro trial anchors」两行相邻且都含 "trial"，读起来像自相矛盾。保留项统一改称 "Pro evaluation anchors"。
4. **测试 stub 清理。** 移除已不可达的 `defaults read`/`write` 分支。注意：stub 里 `if args[0] != 'delete': sys.exit(1)` 并不会真的「大声失败」——脚本的 `defaults` 调用带 `|| true`，退出码被吞掉。复审者已用变异证实这一点。该缺口非阻塞（`read`/`write` 本就在被测契约之外），未追加断言。
5. **`com.oiloil.find.trial` 无条件删除**，不随 `--purge`。这是相对设计文档的有意偏差，理由见 Task 1 的说明。

**第 2 块 Task 3 已完成，提交 `e425938`（后经审查修订）。** 偏差与教训：

1. **`--filter` 验证不足，必须跑全量。** 计划 Task 3 Step 4 只要求 `swift test --filter SettingsPreferencesTests`。这条命令会让一个真缺陷静默通过：`dictionaryRepresentation()` 与 `object(forKey:)` 都包含进程级的 registration domain，而 `M4Tests.swift:51`、`M6Tests.swift:50` 会先调用 `SettingsPreferences.register(in:)` 填充它。`clearAll` 删掉存储值后，`object(forKey:)` 会穿透到注册默认值，于是 `XCTAssertNil` 在**全量**运行中失败、在 `--filter` 运行中通过。**后续所有任务的验证一律以全量 `swift test` 为准**，`--filter` 只用于快速迭代。
2. **Task 3 首个测试的断言改写。** 原断言探 `object(forKey:)`，受上述穿透影响；改为探 `persistentDomain(forName:)`（suite 自己的存储）。审查者实测确认：`clearAll` 变 no-op 时新断言**仍然失败**，因此这是更强的探针而非更弱的。
3. **合并 domain 迭代是有意的。** `clearAll` 对 `.standard` 上约 86 个 global domain 键调用 `removeObject`，实测为真 no-op。不改成 `removePersistentDomain(forName:)` 的原因：domain 名无法从任意注入的 `UserDefaults` 推出（无公开 API），而手工维护键白名单会漏掉 `appLanguage`、`automaticUpdates`、`aiTopicsEnabled` 等注册之外的键。已在代码注释中写明，防止后人「优化」掉。

**第 3 块 Task 4 已完成，提交 `333bf43`。** 只有一处偏差：

1. **只暂存了自己那一段。** `L10n.swift` 里还带着属于其他在途工作的 `contentScanning`/`contentParsing` 两个键，整文件 `git add` 会把它们一并带进来。implementer 改用过滤后的 `git apply --cached`，只暂存自己的 hunk，工作区保持 28 改 + 1 未跟踪。我独立核对 `git show 333bf43`：确实只动 `L10n.swift`（5 增 1 删），两个无关键既不在提交里、也仍在工作区未暂存。

**新增 Task 4b（源自用户决策，原计划未覆盖）。** 计划在写「清空所有配置」时没有明确首次使用引导的去留，已向用户确认：**保留**。`didFinishOnboarding` 与 `skippedFullDiskAccess` 加入 `SettingsPreferences.protectedKeys`。理由：引导是一次性流程而非偏好，用户点「清空所有配置」后不该意外重新看到欢迎页；这与多数应用「重置设置」的行为一致。注意这两个键只有被**存储**过才在 application domain 里，未存储时 `removeObject` 本就是 no-op——所以这条保护只在用户已完成引导时才起作用。

**派发前修正（Task 5/6）。** 计划 Task 6 的片段 `guard !snapshot, let window else { return }` 假设 `SettingsModel` 上有 `window` 属性，**核实为假**。`window` 是 `SettingsForm` 的闭包属性（`SettingsWindow.swift:285`，控制器在 `:507` 注入 `{ [weak window] in window }`），model 上需要窗口的方法一律收参数（`addFolders(in:)`、`beginRecording(in:)`、`checkFile(in:)`）。正确签名是 `confirmClearAllSettings(in window: NSWindow?)`，按钮处写 `model.confirmClearAllSettings(in: window())`。这条教训与 Task 3 同源：**计划里的接口签名在派发前必须对着代码核一遍。**

**派发前修正（Task 5/6）之二 —— 三处计划与实际不符：**

1. **`contentHeight` 的「+62」是空指令。** 实际是 `min(600, 880 - (granted ? 30 : 0) + …)`（`SettingsWindow.swift:87-90`），上限 600 而底数 880，被减数再大也落在上限之上，**结果恒为 600**。加不加 62 都不改变窗口高度。所以 Task 5 **不动 `contentHeight`**：新 Section 只是落到 `Form` 的滚动区里（第 86 行注释已写明「Grouped Form owns scrolling」）。这个公式目前是退化代码，属于既有问题，不在本次范围。
2. **`UpdateRelauncher` 不可复用。** 计划提到它「提供了重启的先例」，但它的签名要 `UpdateInstallation`，脚本里还依赖 `previous.app` 并在失败时把 app 目录**回滚**（`UpdateInstaller.swift:201-238`）。拿它做「清空后重启」会去回滚一个不存在的备份。Task 6 自己写一个只做「等 pid 退出 → `open -n`」的简单重启，但**沿用它的安全写法**：路径一律走位置参数，绝不拼进 shell 源码（该文件有明确注释说明这一点）。
3. **确认弹窗的按钮文案。** `settings.resetAll`（"清空所有配置…"）带省略号，省略号在 macOS 约定里表示「还会再开一个对话框」，用在确认弹窗的破坏性按钮上是错的。确认按钮复用无省略号的 `settings.reset`（"重置"/"Reset"），取消按钮复用既有的 `action.cancel`。不新增键。

**用户决策（Task 6 追加，超出原设计文档范围）：一并取消「登录时打开」。** `launchAtLogin` 由 `SMAppService` 管理，**不写 UserDefaults**（`SettingsWindow.swift:145-153` 的 `setLogin` 只调 register/unregister），所以 `clearAll` 清不到它。不处理的话，用户点完「清空所有配置」重启后会看到该开关仍然开着，与「恢复默认状态」矛盾。已向用户确认，在确认后、重启前调用 `SMAppService.mainApp.unregister()`——与 `setLogin(false)` 同一条代码路径。原设计文档把范围限定为「仅 UserDefaults 偏好项」，这一条是对它的有意扩充。

**Task 4b 已完成，提交 `865dd13`，审查 ✅✅。** 审查者独立核实了字面键与应用实际读写的拼写逐字符一致（`AppDelegate.swift:77/106/107`），并回答了我提出的覆盖缺口问题：只删 `skippedFullDiskAccess` 也会让测试失败，两个键各有独立断言，没有漏洞。`dictionaryRepresentation()` 含 argument domain 这一条也对着 Apple 文档核实过。

**Task 5+6 已完成，提交 `c49c108`。** 同时查清一个边界，**是真实缺陷**：

`AppDelegate.swift:282-284` 的 `applicationShouldTerminate` 在 `UpdateManager.shared.preventsTermination` 为真时返回 `.terminateCancel`（全代码库没有任何地方返回 `.terminateLater`，所以 terminate 只会被**取消**，不会被推迟）。而实现顺序是「武装重启 → 清空 → terminate」，于是：**用户在更新安装过程中确认清空 → `clearAll` 已执行、重启监听已武装，但 terminate 被取消**，应用带着已清空的设置继续运行，内存里仍是启动时快照（旧热键、旧索引配置），直到下次退出才由已武装的监听触发重启。这正是重启契约要避免的中间态。修法是加 `!update.preventsTermination` 守卫。

**修复已完成：`9776eeb`（弹窗守卫）+ `14ecf29`（不可回头点的二次守卫）。** 复审在第一次修复后指出残留的 TOCTOU：守卫只在弹窗打开那一刻求值，而 `beginSheetModal` 的 modal session 期间主线程 run loop 仍在转，更新可能**在这期间**才开始安装，于是用户确认时守卫已经放行。因此在 `clearAllSettingsAndRelaunch` 的不可回头点再检查一次。两个守卫的分工：一个避免向用户提供应用无法完成的操作，一个守住真正执行的那一点。

**顺序是承重的。** `guard !update.preventsTermination, relaunch() else { return }` —— Swift 的逗号条件列表短路求值，`preventsTermination` 为真时 `relaunch()` 不会被调用，因此也不会武装任何东西。反过来写就会先武装重启监听再放弃，留下一个等待本进程退出的游离 watcher。审查者独立核过这一点。

**收尾验证（Task 1–6）：**

```sh
OILFIND_FREE=1 swift build                       # Build complete!
OILFIND_FREE=1 swift test                        # 328 测试（204 + 124），0 失败
python3 Tests/Scripts/test_uninstall.py          # Ran 3 tests, OK
python3 Tests/Scripts/test_open_core.py          # Ran 2 tests, OK
```

**界面视觉验证（自动化测试覆盖不到的那一步，已用调试版快照完成）：**

```sh
OILFIND_FREE=1 swift run OilFind --snapshot /tmp/oilfind-verify/settings-zh.png --state settings --settings-scroll 1.0 --language zh
OILFIND_FREE=1 swift run OilFind --snapshot /tmp/oilfind-verify/settings-en.png --state settings --settings-scroll 1.0 --language en
```

两种语言都确认渲染正确：新 Section 位于最末，标题「重置」/ "Reset"、按钮「清空所有配置…」/ "Clear All Settings…"、页脚文案与相邻区块样式一致。注意 `--snapshot` 走的是 `SettingsModel(snapshot: true)`，所以它验证的是**渲染**，不是点击行为。

**仍未验证（必须真机手做，且会清掉你自己的真实偏好）：** 点下按钮 → 弹窗 → 确认 → 应用重启 → 热键、拼音、排除扩展名回到默认值，索引按默认范围重建。这条路径整体藏在 `!snapshot` 守卫之后，自动化测试够不到。

---

## ⛔ Task 7–13 受阻：与在途工作撞车

**已核实：Task 7 到 13 要动的每一个文件，都在工作区那 28 个未提交改动里。**

| 任务 | 文件 | 在途状态 |
|---|---|---|
| 7 | `Tests/OilFindCoreTests/M7StorageTests.swift` | 已修改 |
| 8 | `Sources/OilFindApp/ContentSearch/ContentIndex.swift`、`Tests/OilFindUITests/ContentIndexSchemaTests.swift` | 已修改 |
| 9、10 | `Sources/OilFindApp/ContentSearch/ContentManager.swift` | 已修改 |
| 11 | `Tests/OilFindUITests/ContentManagerTests.swift` | 已修改 |
| 12 | `Sources/OilFindCore/IndexStore+Persistence.swift`、`Tests/OilFindCoreTests/M7StorageTests.swift` | 已修改 |
| 13 | `docs/ARCHITECTURE.md` | 已修改 |

**那件在途工作是什么：** 给内容索引加**亚秒级 mtime** —— `ContentIndex.schemaVersion` 由 1 升到 2，建表新增 `mtime_nsec INTEGER NOT NULL`，`ContentFileRecord` 增加 `mtimeNsec` 字段。涉及 `ContentSearch/*` 五个源文件、`IndexStore*` 五个源文件、以及十余个测试文件。

**不只是文件重叠：**
1. **代码区域重叠。** Task 8 要改 `ContentIndex.swift` 的 `migrate()`（计划标为 `:137-215`），在途工作改的是同一个建表块（`ContentIndex.swift` 的 `CREATE TABLE files`）。同一区域的两个改动无法干净切分成独立 hunk。
2. **语义互相影响。** 在途工作把 `schemaVersion` 升到 2，会让**每一个已有用户**在升级后命中那条「版本不符就地 DROP」的路径——而这正是 Task 8 要拆掉的东西。两件事必须一起考虑，不能各做各的。

**用户决定（2026-10-20）：先由用户提交或 stash 那件在途工作，之后 Task 7–13 在干净文件上继续。** 在此之前不派发 Task 7–13。

**已交付且独立可用的一半：Task 1–6。** 卸载默认保留偏好（`--purge` 才删）、设置里的「清空所有配置」、引导页与 Pro 锚点保护、卸载脚本 CI 步骤。这一半不依赖索引那一半，可以先落地。
