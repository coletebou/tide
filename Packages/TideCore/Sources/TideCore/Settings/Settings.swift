import Foundation

/// A setting's value, as stored in `settings.json`.
public enum SettingValue: Hashable, Codable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case globs([String: Bool])

    var jsonObject: Any {
        switch self {
        case .bool(let value): value
        case .number(let value): value.rounded() == value && abs(value) < 1e15 ? Int(value) as Any : value as Any
        case .string(let value): value
        case .globs(let value): value
        }
    }

    init?(json: Any, like defaultValue: SettingValue) {
        switch defaultValue {
        case .bool: guard let value = json as? Bool else { return nil }; self = .bool(value)
        case .number:
            if let value = json as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { self = .number(value.doubleValue) } else { return nil }
        case .string: guard let value = json as? String else { return nil }; self = .string(value)
        case .globs: guard let value = json as? [String: Bool] else { return nil }; self = .globs(value)
        }
    }
}

/// One setting: its key (VS Code's name where one exists), default, and how
/// the Settings editor presents it.
public struct SettingDescriptor: Identifiable, Hashable, Sendable {
    public enum Category: String, CaseIterable, Sendable {
        case editor = "Text Editor"
        case workbench = "Workbench"
        case files = "Files"
        case search = "Search"
        case terminal = "Terminal"
        case remote = "Remote"
        case ai = "AI"
    }

    public let key: String
    public let title: String
    public let summary: String
    public let category: Category
    public let defaultValue: SettingValue
    /// Allowed values for string settings shown as a picker.
    public let options: [String]
    public let range: ClosedRange<Double>?

    public var id: String { key }

    init(_ key: String, _ title: String, _ summary: String, _ category: Category, _ defaultValue: SettingValue, options: [String] = [], range: ClosedRange<Double>? = nil) {
        self.key = key
        self.title = title
        self.summary = summary
        self.category = category
        self.defaultValue = defaultValue
        self.options = options
        self.range = range
    }
}

/// Every setting Tide understands. Defaults follow VS Code except where a
/// touch device needs otherwise (word wrap and auto save are on, the font is
/// larger), and those are called out in the summary.
public enum SettingsRegistry {
    public static let descriptors: [SettingDescriptor] = [
        .init("editor.fontSize", "Font Size", "Controls the font size in points.", .editor, .number(14), range: 8...36),
        .init("editor.fontFamily", "Font Family", "Controls the font family. 'SF Mono' is the system monospaced font.", .editor, .string("SF Mono"), options: ["SF Mono", "Menlo", "Courier New"]),
        .init("editor.lineHeight", "Line Height", "Controls the line height as a multiple of the font size. Use 0 to compute it from the font size.", .editor, .number(0), range: 0...3),
        .init("editor.tabSize", "Tab Size", "The number of spaces a tab is equal to. Overridden when Detect Indentation is on.", .editor, .number(4), range: 1...8),
        .init("editor.insertSpaces", "Insert Spaces", "Insert spaces when pressing Tab.", .editor, .bool(true)),
        .init("editor.detectIndentation", "Detect Indentation", "Detect Tab Size and Insert Spaces from the file's contents.", .editor, .bool(true)),
        .init("editor.wordWrap", "Word Wrap", "Controls how lines wrap. Tide defaults to 'on' because iPhone and iPad screens are narrow; VS Code defaults to 'off'.", .editor, .string("on"), options: ["off", "on"]),
        .init("editor.lineNumbers", "Line Numbers", "Controls the display of line numbers.", .editor, .string("on"), options: ["on", "off", "relative"]),
        .init("editor.minimap.enabled", "Minimap", "Controls whether the minimap is shown.", .editor, .bool(true)),
        .init("editor.renderWhitespace", "Render Whitespace", "Controls how the editor renders whitespace characters.", .editor, .string("selection"), options: ["none", "selection", "all"]),
        .init("editor.renderLineHighlight", "Render Line Highlight", "Controls how the current line is highlighted.", .editor, .string("line"), options: ["none", "line"]),
        .init("editor.cursorStyle", "Cursor Style", "Controls the cursor style.", .editor, .string("line"), options: ["line", "block", "underline"]),
        .init("editor.autoClosingBrackets", "Auto Closing Brackets", "Automatically close brackets and quotes after typing the opener.", .editor, .string("languageDefined"), options: ["languageDefined", "never"]),
        .init("editor.bracketPairColorization.enabled", "Bracket Pair Colorization", "Color matching brackets by nesting depth.", .editor, .bool(true)),
        .init("editor.guides.indentation", "Indentation Guides", "Render indentation guides.", .editor, .bool(true)),
        .init("editor.stickyScroll.enabled", "Sticky Scroll", "Show the enclosing scopes at the top of the editor while scrolling.", .editor, .bool(true)),
        .init("editor.matchBrackets", "Match Brackets", "Highlight matching brackets.", .editor, .string("always"), options: ["always", "never"]),
        .init("editor.smoothScrolling", "Smooth Scrolling", "Animate scrolling when jumping to a line.", .editor, .bool(true)),
        .init("workbench.colorTheme", "Color Theme", "Specifies the color theme used in the workbench.", .workbench, .string("Dark 2026")),
        .init("workbench.preferredDarkColorTheme", "Preferred Dark Color Theme", "The theme used in dark mode when Auto Detect Color Scheme is on.", .workbench, .string("Dark 2026")),
        .init("workbench.preferredLightColorTheme", "Preferred Light Color Theme", "The theme used in light mode when Auto Detect Color Scheme is on.", .workbench, .string("Light 2026")),
        .init("window.autoDetectColorScheme", "Auto Detect Color Scheme", "Follow the system appearance by switching between the preferred dark and light themes.", .workbench, .bool(false)),
        .init("workbench.editor.enablePreview", "Enable Preview", "Opened editors show as preview (italic tab) until they are kept open or edited.", .workbench, .bool(true)),
        .init("workbench.sideBar.location", "Side Bar Location", "Controls the location of the primary side bar.", .workbench, .string("left"), options: ["left", "right"]),
        .init("workbench.statusBar.visible", "Status Bar", "Controls the visibility of the status bar.", .workbench, .bool(true)),
        .init("workbench.startupEditor", "Startup Editor", "Controls which editor is shown at startup.", .workbench, .string("welcomePage"), options: ["none", "welcomePage", "readme"]),
        .init("workbench.commandPalette.history", "Command Palette History", "Number of recently used commands to keep.", .workbench, .number(50), range: 0...200),
        .init("files.autoSave", "Auto Save", "Controls auto save. Tide defaults to 'afterDelay' because iOS may close the app at any time; VS Code defaults to 'off'.", .files, .string("afterDelay"), options: ["off", "afterDelay", "onFocusChange"]),
        .init("files.autoSaveDelay", "Auto Save Delay", "Milliseconds after which a dirty file is saved when Auto Save is 'afterDelay'.", .files, .number(1000), range: 100...60000),
        .init("files.trimTrailingWhitespace", "Trim Trailing Whitespace", "Trim trailing whitespace when saving.", .files, .bool(false)),
        .init("files.insertFinalNewline", "Insert Final Newline", "Insert a final newline at the end of the file when saving.", .files, .bool(false)),
        .init("files.eol", "End of Line", "The default end of line character for new files.", .files, .string("\n"), options: ["\n", "\r\n"]),
        .init("files.exclude", "Exclude", "Glob patterns for files and folders to hide from the Explorer and search.", .files, .globs(Dictionary(uniqueKeysWithValues: DefaultExcludes.files.map { ($0, true) }))),
        .init("search.exclude", "Search Exclude", "Glob patterns excluded from full text search and Quick Open, in addition to Files: Exclude.", .search, .globs(Dictionary(uniqueKeysWithValues: DefaultExcludes.search.map { ($0, true) }))),
        .init("search.useIgnoreFiles", "Use Ignore Files", "Respect .gitignore files when searching.", .search, .bool(true)),
        .init("terminal.integrated.fontSize", "Terminal Font Size", "Controls the font size of the terminal.", .terminal, .number(13), range: 8...30),
        .init("terminal.integrated.cursorStyle", "Terminal Cursor Style", "Controls the terminal cursor style.", .terminal, .string("block"), options: ["block", "line", "underline"]),
        .init("terminal.integrated.cursorBlinking", "Terminal Cursor Blinking", "Controls whether the terminal cursor blinks.", .terminal, .bool(false)),
        .init("tide.keyboardBar.enabled", "Keyboard Bar", "Show a row of coding keys (Tab, Esc, Ctrl, arrows, brackets) above the on-screen keyboard.", .editor, .bool(true)),
        .init("remote.SSH.connectTimeout", "Connect Timeout", "Seconds to wait for an SSH connection.", .remote, .number(15), range: 1...120),
        .init("remote.SSH.keepAliveInterval", "Keep-Alive Interval", "Seconds between SSH keep-alive messages; 0 turns them off.", .remote, .number(30), range: 0...600),
        .init("ai.provider", "Provider", "Which AI provider powers chat, inline edits and agent mode.", .ai, .string("anthropic"), options: ["anthropic", "openai", "xai", "apple"]),
        .init("ai.model", "Model", "Model id for the selected provider. Leave empty for the provider's default.", .ai, .string("")),
        .init("ai.agent.autoApproveReads", "Auto-Approve Reads", "Let agent mode read files and search without asking.", .ai, .bool(true)),
        .init("ai.agent.autoApproveEdits", "Auto-Approve Edits", "Apply agent edits without per-hunk review.", .ai, .bool(false)),
        .init("ai.agent.autoApproveCommands", "Auto-Approve Commands", "Run agent terminal commands without asking.", .ai, .bool(false)),
    ]

    public static let byKey: [String: SettingDescriptor] = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.key, $0) })
}

/// User settings: overrides on top of the registry defaults, read from and
/// written to `settings.json`. Unknown keys are kept so hand-written settings
/// survive a round trip.
public struct SettingsStore: Equatable, Sendable {
    public private(set) var overrides: [String: SettingValue] = [:]
    /// Keys Tide does not know, preserved as JSON text fragments.
    public private(set) var unknownJSON: [String: String] = [:]

    public init() {}

    public func value(_ key: String) -> SettingValue? {
        overrides[key] ?? SettingsRegistry.byKey[key]?.defaultValue
    }

    public func bool(_ key: String) -> Bool {
        if case .bool(let value)? = value(key) { return value }
        return false
    }

    public func number(_ key: String) -> Double {
        if case .number(let value)? = value(key) { return value }
        return 0
    }

    public func int(_ key: String) -> Int { Int(number(key)) }

    public func string(_ key: String) -> String {
        if case .string(let value)? = value(key) { return value }
        return ""
    }

    /// Enabled globs of a glob-map setting (`files.exclude`).
    public func globs(_ key: String) -> [String] {
        if case .globs(let value)? = value(key) { return value.filter(\.value).map(\.key).sorted() }
        return []
    }

    public func isModified(_ key: String) -> Bool { overrides[key] != nil }

    /// Sets a value; setting the default removes the override, like VS Code.
    public mutating func set(_ key: String, _ value: SettingValue) {
        if let descriptor = SettingsRegistry.byKey[key], descriptor.defaultValue == value {
            overrides[key] = nil
        } else {
            overrides[key] = value
        }
    }

    public mutating func reset(_ key: String) {
        overrides[key] = nil
    }

    /// Parses `settings.json` (JSONC). Values of the wrong type, and numbers
    /// outside a setting's range, are reported and ignored.
    public static func parse(_ text: String) -> (store: SettingsStore, problems: [String]) {
        var store = SettingsStore()
        var problems: [String] = []
        let object: [String: Any]
        do {
            object = try JSONC.parseObject(text)
        } catch {
            return (store, ["settings.json could not be parsed: \(error)"])
        }
        for (key, raw) in object {
            if let descriptor = SettingsRegistry.byKey[key] {
                guard let value = SettingValue(json: raw, like: descriptor.defaultValue) else {
                    problems.append("Incorrect type for '\(key)'.")
                    continue
                }
                // Out of range includes values such as 1e100, which int(_:) cannot convert.
                if case .number(let number) = value, let range = descriptor.range, !range.contains(number) {
                    problems.append("'\(key)' must be between \(Self.format(range.lowerBound)) and \(Self.format(range.upperBound)).")
                    continue
                }
                store.set(key, value)
            } else if let data = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed, .sortedKeys]),
                      let fragment = String(data: data, encoding: .utf8) {
                store.unknownJSON[key] = fragment
            }
        }
        return (store, problems)
    }

    /// A range bound as written in settings.json: `8`, not `8.0`.
    private static func format(_ bound: Double) -> String {
        bound.rounded() == bound ? String(Int(bound)) : String(bound)
    }

    /// The overrides as a pretty-printed `settings.json`.
    public func json() -> String {
        var object: [String: Any] = [:]
        for (key, value) in overrides { object[key] = value.jsonObject }
        for (key, fragment) in unknownJSON {
            if let data = fragment.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                object[key] = value
            }
        }
        guard !object.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\n}\n"
        }
        // JSONSerialization indents with two spaces; VS Code uses four.
        let lines: [String] = text.components(separatedBy: "\n")
        let reindented = lines.map { (line: String) -> String in
            let leading = line.prefix { $0 == " " }.count
            return String(repeating: " ", count: leading * 2) + String(line.dropFirst(leading))
        }.joined(separator: "\n")
        return reindented + "\n"
    }

    /// A read-only listing of every default, like VS Code's "Default Settings (JSON)".
    public static func defaultSettingsJSON() -> String {
        var lines = ["{"]
        for category in SettingDescriptor.Category.allCases {
            let settings = SettingsRegistry.descriptors.filter { $0.category == category }
            guard !settings.isEmpty else { continue }
            lines.append("    // \(category.rawValue)")
            for descriptor in settings {
                lines.append("")
                lines.append("    // \(descriptor.summary)")
                let data = try? JSONSerialization.data(withJSONObject: descriptor.defaultValue.jsonObject, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
                let value = data.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
                lines.append("    \"\(descriptor.key)\": \(value),")
            }
            lines.append("")
        }
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }
}
