import Foundation

public enum SettingsPreferences {
    public static let excludedExtensionsChanged = Notification.Name("com.oiloil.find.excludedExtensionsChanged")
    public static func setExcludedExtensions(_ text: String, in defaults: UserDefaults = .standard) -> String {
        let values = IndexConfig.normalizeExtensions(text)
        let previous = defaults.stringArray(forKey: "excludedExtensions") ?? []
        defaults.set(values, forKey: "excludedExtensions")
        if Set(previous) != Set(values) {
            NotificationCenter.default.post(name: excludedExtensionsChanged, object: defaults, userInfo: ["extensions": Set(values)])
        }
        return values.joined(separator: " ")
    }
    public static func register(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            "hotKeyCode": Int(Shortcut.defaultKeyCode), "hotKeyModifiers": Int(Shortcut.defaultModifiers),
            "previewWithSpace": true, "excludedExtensions": [String](), "pinyinEnabled": true, "userExcludedPaths": [String](), "skippedFullDiskAccess": false, "didFinishOnboarding": false,
            "indexDependencyDirs": false, "indexPackageContents": false, "indexUserLibrary": false, "indexSystemDirs": false,
            "sortKey": "relevance", "sortAscending": false
        ])
    }
    /// The one-time legacy authorization sweep stamps this key when it has run. The sweep itself
    /// lives in the app layer, but the key is owned here so `clearAll` can protect it without a
    /// second literal.
    public static let legacyAuthorizationCleanupCompletedKey = "legacyAuthorizationCleanupCompleted"
    /// Keys that `clearAll` leaves alone. The three `proEvaluation*` anchors belong to the private
    /// `Pro/` module, which `OilFindCore` must not depend on, so they stay as literals here — a
    /// rename there has to be caught in review rather than by the compiler.
    private static let protectedKeys: Set<String> = [
        "proEvaluationStartedAt", "proEvaluationLastSeenAt", "proEvaluationEndedAt",
        legacyAuthorizationCleanupCompletedKey,
    ]
    /// Restores every setting to its default. The protected keys survive: wiping the Pro anchors
    /// would hand out a fresh trial, and wiping the cleanup stamp would re-run a one-time
    /// migration. Callers must relaunch afterwards — the app holds config snapshots in
    /// `SettingsModel`, `IndexManager` and the registered hot key, and re-reading all three in
    /// place is more ways to go wrong than restarting once.
    public static func clearAll(in defaults: UserDefaults = .standard) {
        // dictionaryRepresentation() is a union of the application, global and registration
        // domains; removeObject is a no-op for the global and registration entries, so iterating
        // the merged dictionary is deliberate — the application domain name is not derivable from
        // an arbitrary injected UserDefaults. Unlike setExcludedExtensions this posts no
        // excludedExtensionsChanged notification, which the relaunch contract makes moot.
        for key in defaults.dictionaryRepresentation().keys where !protectedKeys.contains(key) {
            defaults.removeObject(forKey: key)
        }
    }
    public static func searchOptions(in defaults: UserDefaults = .standard) -> SearchOptions {
        let key: SortKey
        switch defaults.string(forKey: "sortKey") {
        case "name": key = .name
        case "modified": key = .modified
        case "size": key = .size
        default: key = .relevance
        }
        return SearchOptions(sort: key, ascending: defaults.bool(forKey: "sortAscending"), pinyin: defaults.bool(forKey: "pinyinEnabled"))
    }
    public static func indexConfig(limited: Bool, in defaults: UserDefaults = .standard) -> IndexConfig {
        var config = IndexConfig.standard(limited: limited)
        config.indexDependencyDirs = defaults.bool(forKey: "indexDependencyDirs")
        config.indexPackageContents = defaults.bool(forKey: "indexPackageContents")
        config.indexUserLibrary = defaults.bool(forKey: "indexUserLibrary")
        config.indexSystemDirs = defaults.bool(forKey: "indexSystemDirs")
        config.excludedExtensions = Set(defaults.stringArray(forKey: "excludedExtensions") ?? [])
        config.userExcludedPaths = ExcludedFolders.adding(defaults.stringArray(forKey: "userExcludedPaths") ?? [], to: [])
        return config
    }
}

public enum ExcludedFolders {
    // Lexical normalization preserves the spelling used by the scanner and FSEvents.
    public static func normalized(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        return IndexConfig(rootPath: path).rootPath.precomposedStringWithCanonicalMapping
    }
    public static func contains(_ parent: String, path: String) -> Bool {
        guard let parent = normalized(parent), let path = normalized(path) else { return false }
        return parent == "/" || path == parent || path.hasPrefix(parent + "/")
    }
    public static func adding(_ paths: [String], to existing: [String]) -> [String] {
        var result: [String] = []
        for value in existing + paths {
            guard let path = normalized(value), !result.contains(where: { contains($0, path: path) }) else { continue }
            // A newly selected ancestor replaces its redundant descendants.
            result.removeAll { contains(path, path: $0) }
            result.append(path)
        }
        return result
    }
}
