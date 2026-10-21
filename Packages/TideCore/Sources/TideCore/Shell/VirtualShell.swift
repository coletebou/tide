import Foundation

/// The result of running a command line in the virtual shell.
public struct ShellOutput: Equatable, Sendable {
    /// Text for the terminal, with `\r\n` line endings and ANSI colors.
    public var text: String
    public var exitCode: Int32
    public var clearScreen = false
    /// Workspace paths the command asked to open in the editor (`code`, `open`).
    public var openFiles: [String] = []
}

/// A small POSIX-flavored shell over a workspace folder, for the integrated
/// terminal when no SSH host is connected (iOS apps cannot spawn processes).
/// `/` is the workspace root. Supports pipes, `;`, `&&`, `||`, `>`, `>>`,
/// globs, `$VAR` expansion and a set of everyday commands.
public final class VirtualShell {
    public let root: URL
    public private(set) var cwd = ""
    public private(set) var history: [String] = []
    public var environment: [String: String]
    public var userName = "tide"
    public var hostName = "ipad"
    private var lastExitCode: Int32 = 0

    public init(root: URL) {
        self.root = root.standardizedFileURL
        environment = ["HOME": "/", "USER": "tide", "SHELL": "/bin/tide-sh", "TERM": "xterm-256color", "LANG": "en_US.UTF-8", "PATH": "/usr/bin"]
    }

    static let commands: [String] = [
        "basename", "cat", "cd", "clear", "code", "cp", "date", "dirname", "echo", "env", "exit", "export", "false", "find",
        "grep", "head", "help", "history", "hostname", "ls", "mkdir", "mv", "open", "printf", "pwd", "rm", "rmdir", "seq",
        "sleep", "sort", "stat", "tail", "touch", "tree", "true", "uname", "uniq", "unset", "wc", "which", "whoami",
    ]

    /// `tide@ipad project % ` with zsh-like colors.
    public var prompt: String {
        let folder = cwd.isEmpty ? root.lastPathComponent : WorkspacePath.name(of: cwd)
        return "\u{1B}[1;32m\(userName)@\(hostName)\u{1B}[0m \u{1B}[1;34m\(folder)\u{1B}[0m % "
    }

    /// The working directory as shown by `pwd`.
    public var displayDirectory: String { "/" + cwd }

    public func run(_ commandLine: String) -> ShellOutput {
        let trimmed = commandLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return ShellOutput(text: "", exitCode: lastExitCode) }
        history.append(trimmed)
        if history.count > 1_000 { history.removeFirst(history.count - 1_000) }

        // Split into `;`, `&&` and `||` lists first, and lex each command when
        // it runs, so `export X=1; echo $X` sees the new value as in a real shell.
        let list: [(command: String, separator: String)]
        do {
            list = try ShellLexer.splitList(trimmed)
        } catch {
            return finish(ShellOutput(text: "tide-sh: \(error)\n", exitCode: 2))
        }
        var output = ShellOutput(text: "", exitCode: 0)
        var skip = false
        for entry in list {
            if !skip {
                let result: ShellOutput
                do {
                    let tokens = try ShellLexer.tokenize(entry.command, environment: environment, lastExitCode: lastExitCode)
                    result = tokens.isEmpty ? ShellOutput(text: "", exitCode: lastExitCode) : runPipeline(tokens)
                } catch {
                    result = ShellOutput(text: "tide-sh: \(error)\n", exitCode: 2)
                }
                output.text += result.text
                output.exitCode = result.exitCode
                output.clearScreen = output.clearScreen || result.clearScreen
                output.openFiles += result.openFiles
                lastExitCode = result.exitCode
            }
            switch entry.separator {
            case "&&": skip = lastExitCode != 0
            case "||": skip = lastExitCode == 0
            default: skip = false
            }
        }
        return finish(output)
    }

    private func finish(_ output: ShellOutput) -> ShellOutput {
        lastExitCode = output.exitCode
        var output = output
        output.text = output.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        return output
    }

    // MARK: - Pipelines and redirection

    private struct CommandResult {
        var stdout = ""
        var stderr = ""
        var exitCode: Int32 = 0
        var clearScreen = false
        var openFiles: [String] = []
    }

    private func runPipeline(_ tokens: [ShellToken]) -> ShellOutput {
        let stages = tokens.split(separator: .op("|"), omittingEmptySubsequences: false).map(Array.init)
        var input: String?
        var text = ""
        var result = CommandResult()
        for (number, stage) in stages.enumerated() {
            var words: [String] = []
            var redirect: (path: String, append: Bool)?
            var iterator = stage.makeIterator()
            while let token = iterator.next() {
                switch token {
                case .word(let word, let pattern):
                    words.append(contentsOf: pattern.map { expandPattern($0, literal: word) } ?? [word])
                case .op(let op) where op == ">" || op == ">>":
                    if case .word(let target, _)? = iterator.next() {
                        redirect = (target, op == ">>")
                    } else {
                        return ShellOutput(text: "tide-sh: syntax error near unexpected token `newline'\n", exitCode: 2)
                    }
                default:
                    break
                }
            }
            guard let name = words.first else { continue }
            result = execute(name, Array(words.dropFirst()), stdin: input)
            if let redirect {
                do {
                    let file = url(for: try resolve(redirect.path))
                    let output = Data(result.stdout.utf8)
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if redirect.append, FileManager.default.fileExists(atPath: file.path) {
                        // Append bytes, as a shell does: the file may not be UTF-8 text at all.
                        let handle = try FileHandle(forWritingTo: file)
                        defer { try? handle.close() }
                        try handle.seekToEnd()
                        try handle.write(contentsOf: output)
                    } else {
                        try output.write(to: file, options: .atomic)
                    }
                    result.stdout = ""
                } catch {
                    result.stderr += "tide-sh: \(redirect.path): \(describe(error))\n"
                    result.exitCode = 1
                }
            }
            text += result.stderr
            if number == stages.count - 1 {
                text += result.stdout
            } else {
                input = result.stdout
            }
        }
        return ShellOutput(text: text, exitCode: result.exitCode, clearScreen: result.clearScreen, openFiles: result.openFiles)
    }

    // MARK: - Commands

    private func execute(_ name: String, _ args: [String], stdin: String?) -> CommandResult {
        if name.contains("="), let equals = name.firstIndex(of: "="), args.isEmpty {
            environment[String(name[..<equals])] = String(name[name.index(after: equals)...])
            return CommandResult()
        }
        do {
            switch name {
            case "help": return CommandResult(stdout: helpText())
            case "pwd": return CommandResult(stdout: displayDirectory + "\n")
            case "cd": return try cd(args)
            case "ls": return try ls(args)
            case "cat": return try cat(args, stdin: stdin)
            case "echo": return echo(args)
            case "printf": return CommandResult(stdout: printf(args))
            case "mkdir": return try mkdir(args)
            case "touch": return try touch(args)
            case "rm": return try rm(args)
            case "rmdir": return try rmdir(args)
            case "mv": return try mvOrCp(args, copy: false)
            case "cp": return try mvOrCp(args, copy: true)
            case "head", "tail": return try headTail(args, stdin: stdin, head: name == "head")
            case "wc": return try wc(args, stdin: stdin)
            case "grep": return try grep(args, stdin: stdin)
            case "find": return try find(args)
            case "tree": return try tree(args)
            case "sort": return try sort(args, stdin: stdin)
            case "uniq": return try uniq(args, stdin: stdin)
            case "stat": return try stat(args)
            case "seq": return seq(args)
            case "date": return CommandResult(stdout: Self.dateFormatter.string(from: Date()) + "\n")
            case "whoami": return CommandResult(stdout: userName + "\n")
            case "hostname": return CommandResult(stdout: hostName + "\n")
            case "uname": return CommandResult(stdout: args.contains("-a") ? "Tide \(hostName) 1.0 iOS arm64\n" : "Tide\n")
            case "env": return CommandResult(stdout: environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") + "\n")
            case "export": return export(args)
            case "unset":
                for key in args { environment[key] = nil }
                return CommandResult()
            case "history": return CommandResult(stdout: history.enumerated().map { String(format: "%5d  %@", $0.offset + 1, $0.element) }.joined(separator: "\n") + "\n")
            case "clear": return CommandResult(clearScreen: true)
            case "which":
                let found = args.filter(Self.commands.contains)
                return CommandResult(stdout: found.map { "\($0): shell built-in command\n" }.joined(), exitCode: found.count == args.count ? 0 : 1)
            case "code", "open":
                let paths = try args.map(resolve)
                for path in paths where !FileManager.default.fileExists(atPath: url(for: path).path) {
                    try Data().write(to: url(for: path))
                }
                return CommandResult(openFiles: paths)
            case "basename": return CommandResult(stdout: (args.first.map { WorkspacePath.name(of: $0) } ?? "") + "\n")
            case "dirname": return CommandResult(stdout: (args.first.map { let parent = WorkspacePath.parent(of: $0); return parent.isEmpty ? "." : parent } ?? ".") + "\n")
            case "true", "exit", "sleep": return CommandResult()
            case "false": return CommandResult(exitCode: 1)
            default:
                return CommandResult(stderr: "tide-sh: command not found: \(name)\n", exitCode: 127)
            }
        } catch {
            return CommandResult(stderr: "\(name): \(describe(error))\n", exitCode: 1)
        }
    }

    private func helpText() -> String {
        """
        Tide's built-in shell runs on this device, over the open workspace.
        Connect to an SSH host from the Remote Explorer for a full Unix shell.

        Commands: \(Self.commands.joined(separator: " "))
        Operators: | ; && || > >>   Globs: * ? [abc] {a,b}   Variables: $NAME ${NAME} $?
        Open a file in the editor with: code <file>

        """
    }

    private func cd(_ args: [String]) throws -> CommandResult {
        let target = try resolve(args.first ?? "/")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url(for: target).path, isDirectory: &isDirectory) else {
            return CommandResult(stderr: "cd: no such file or directory: \(args.first ?? "")\n", exitCode: 1)
        }
        guard isDirectory.boolValue else { return CommandResult(stderr: "cd: not a directory: \(args.first ?? "")\n", exitCode: 1) }
        cwd = target
        environment["PWD"] = displayDirectory
        return CommandResult()
    }

    private func ls(_ args: [String]) throws -> CommandResult {
        let flags = Set(args.filter { $0.hasPrefix("-") }.flatMap { $0.dropFirst() })
        let showAll = flags.contains("a")
        let long = flags.contains("l")
        let targets = args.filter { !$0.hasPrefix("-") }
        var output = ""
        var errors = ""
        for (number, target) in (targets.isEmpty ? ["."] : targets).enumerated() {
            let path = try resolve(target)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url(for: path).path, isDirectory: &isDirectory) else {
                errors += "ls: \(target): No such file or directory\n"
                continue
            }
            if targets.count > 1, isDirectory.boolValue { output += (number > 0 ? "\n" : "") + "\(target):\n" }
            let entries: [(name: String, isDirectory: Bool, size: Int64, modified: Date?)]
            if isDirectory.boolValue {
                let names = try FileManager.default.contentsOfDirectory(atPath: url(for: path).path)
                entries = names.filter { showAll || !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
                    let attributes = try? FileManager.default.attributesOfItem(atPath: url(for: WorkspacePath.join(path, name)).path)
                    return (name, (attributes?[.type] as? FileAttributeType) == .typeDirectory, (attributes?[.size] as? NSNumber)?.int64Value ?? 0, attributes?[.modificationDate] as? Date)
                }
            } else {
                let attributes = try? FileManager.default.attributesOfItem(atPath: url(for: path).path)
                entries = [(target, false, (attributes?[.size] as? NSNumber)?.int64Value ?? 0, attributes?[.modificationDate] as? Date)]
            }
            for entry in entries {
                let name = entry.isDirectory ? "\u{1B}[1;34m\(entry.name)\u{1B}[0m" : entry.name
                if long {
                    let date = entry.modified.map { Self.lsDateFormatter.string(from: $0) } ?? ""
                    output += "\(entry.isDirectory ? "d" : "-")rw-r--r--  \(userName)  \(String(format: "%8lld", entry.size))  \(date)  \(name)\n"
                } else {
                    output += name + "\n"
                }
            }
        }
        return CommandResult(stdout: output, stderr: errors, exitCode: errors.isEmpty ? 0 : 1)
    }

    private func cat(_ args: [String], stdin: String?) throws -> CommandResult {
        let files = args.filter { $0 != "-" }
        if files.isEmpty { return CommandResult(stdout: stdin ?? "") }
        var output = ""
        var errors = ""
        for file in files {
            let path = try resolve(file)
            guard let data = FileManager.default.contents(atPath: url(for: path).path) else {
                errors += "cat: \(file): No such file or directory\n"
                continue
            }
            guard let (text, _) = TextFileCodec.decode(data) else {
                errors += "cat: \(file): binary file\n"
                continue
            }
            output += text
            if !text.isEmpty, !text.hasSuffix("\n") { output += "\n" }
        }
        return CommandResult(stdout: output, stderr: errors, exitCode: errors.isEmpty ? 0 : 1)
    }

    private func echo(_ args: [String]) -> CommandResult {
        var words = args
        let noNewline = words.first == "-n"
        if noNewline { words.removeFirst() }
        return CommandResult(stdout: words.joined(separator: " ") + (noNewline ? "" : "\n"))
    }

    private func printf(_ args: [String]) -> String {
        guard var format = args.first else { return "" }
        format = format.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
        var values = args.dropFirst().makeIterator()
        var output = ""
        var index = format.startIndex
        while index < format.endIndex {
            let character = format[index]
            let next = format.index(after: index)
            if character == "%", next < format.endIndex, "sd".contains(format[next]) {
                output += values.next() ?? ""
                index = format.index(after: next)
            } else {
                output.append(character)
                index = next
            }
        }
        return output
    }

    private func mkdir(_ args: [String]) throws -> CommandResult {
        let parents = args.contains("-p")
        for target in args where !target.hasPrefix("-") {
            let directory = url(for: try resolve(target))
            if FileManager.default.fileExists(atPath: directory.path) {
                if !parents { return CommandResult(stderr: "mkdir: \(target): File exists\n", exitCode: 1) }
                continue
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: parents)
        }
        return CommandResult()
    }

    private func touch(_ args: [String]) throws -> CommandResult {
        for target in args {
            let file = url(for: try resolve(target))
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            } else {
                try Data().write(to: file)
            }
        }
        return CommandResult()
    }

    private func rm(_ args: [String]) throws -> CommandResult {
        let flags = Set(args.filter { $0.hasPrefix("-") }.flatMap { $0.dropFirst() })
        var errors = ""
        for target in args where !target.hasPrefix("-") {
            let path = try resolve(target)
            guard !path.isEmpty else {
                errors += "rm: refusing to remove the workspace root\n"
                continue
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url(for: path).path, isDirectory: &isDirectory) else {
                if !flags.contains("f") { errors += "rm: \(target): No such file or directory\n" }
                continue
            }
            if isDirectory.boolValue, !flags.contains("r"), !flags.contains("R") {
                errors += "rm: \(target): is a directory\n"
                continue
            }
            try FileManager.default.removeItem(at: url(for: path))
        }
        return CommandResult(stderr: errors, exitCode: errors.isEmpty ? 0 : 1)
    }

    private func rmdir(_ args: [String]) throws -> CommandResult {
        for target in args {
            let path = try resolve(target)
            guard !path.isEmpty else { return CommandResult(stderr: "rmdir: refusing to remove the workspace root\n", exitCode: 1) }
            let directory = url(for: path)
            guard (try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty else {
                return CommandResult(stderr: "rmdir: \(target): Directory not empty\n", exitCode: 1)
            }
            try FileManager.default.removeItem(at: directory)
        }
        return CommandResult()
    }

    private func mvOrCp(_ args: [String], copy: Bool) throws -> CommandResult {
        let name = copy ? "cp" : "mv"
        let operands = args.filter { !$0.hasPrefix("-") }
        guard operands.count >= 2, let destinationOperand = operands.last else {
            return CommandResult(stderr: "usage: \(name) source ... target\n", exitCode: 64)
        }
        let destination = try resolve(destinationOperand)
        let destinationIsDirectory = isDirectory(destination) == true
        if operands.count > 2, !destinationIsDirectory {
            return CommandResult(stderr: "\(name): \(destinationOperand) is not a directory\n", exitCode: 1)
        }
        var errors = ""
        for source in operands.dropLast() {
            let sourcePath = try resolve(source)
            // Check everything before changing anything, so a failed copy or move never costs the destination.
            guard !sourcePath.isEmpty else {
                errors += "\(name): refusing to \(copy ? "copy" : "move") the workspace root\n"
                continue
            }
            guard let sourceIsDirectory = isDirectory(sourcePath) else {
                errors += "\(name): \(source): No such file or directory\n"
                continue
            }
            let fileName = WorkspacePath.name(of: sourcePath)
            let target = destinationIsDirectory ? WorkspacePath.join(destination, fileName) : destination
            let shownTarget = destinationIsDirectory
                ? (destinationOperand.hasSuffix("/") ? destinationOperand : destinationOperand + "/") + fileName
                : destinationOperand
            let targetIsDirectory = isDirectory(target)
            let sameFile = target == sourcePath || isSameFile(sourcePath, target)
            // On a case-insensitive volume, `mv a.txt A.txt` renames a file onto itself.
            let isCaseRename = !copy && sameFile && target != sourcePath && target.lowercased() == sourcePath.lowercased()
            if sameFile, !isCaseRename {
                errors += copy ? "cp: \(shownTarget) and \(source) are identical (not copied).\n" : "mv: \(source) and \(shownTarget) are identical\n"
                continue
            }
            if sourceIsDirectory, WorkspacePath.isDescendant(target, of: sourcePath) {
                errors += "\(name): cannot \(copy ? "copy" : "move") \(source) into itself\n"
                continue
            }
            if !isCaseRename, let targetIsDirectory, targetIsDirectory != sourceIsDirectory {
                errors += "\(name): \(shownTarget): \(targetIsDirectory ? "Is a directory" : "Not a directory")\n"
                continue
            }
            let sourceURL = url(for: sourcePath)
            let targetURL = url(for: target)
            if !copy {
                // rename(2) replaces a file or an empty folder in one step, and otherwise changes nothing.
                if rename(sourceURL.path, targetURL.path) != 0 {
                    let code = errno
                    // Across volumes, only a move to a new name falls back to copying and deleting.
                    guard code == EXDEV, targetIsDirectory == nil else {
                        errors += "mv: rename \(source) to \(shownTarget): \(String(cString: strerror(code)))\n"
                        continue
                    }
                    try FileManager.default.moveItem(at: sourceURL, to: targetURL)
                }
            } else if targetIsDirectory == nil {
                try FileManager.default.copyItem(at: sourceURL, to: targetURL)
            } else {
                // Copy beside the destination, then swap the copy in.
                let staged = targetURL.deletingLastPathComponent().appendingPathComponent(".tide-copy-\(UUID().uuidString)")
                try FileManager.default.copyItem(at: sourceURL, to: staged)
                do {
                    _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: staged, options: .usingNewMetadataOnly)
                } catch {
                    try? FileManager.default.removeItem(at: staged)
                    throw error
                }
            }
        }
        return CommandResult(stderr: errors, exitCode: errors.isEmpty ? 0 : 1)
    }

    /// Whether `path` is a folder (following symbolic links), or nil when nothing is there.
    private func isDirectory(_ path: String) -> Bool? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url(for: path).path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue
    }

    /// Whether two paths reach the same file, through symbolic links, hard
    /// links or a case-insensitive volume.
    private func isSameFile(_ first: String, _ second: String) -> Bool {
        func identity(_ path: String) -> [NSNumber]? {
            let resolved = url(for: path).resolvingSymlinksInPath().path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
                  let volume = attributes[.systemNumber] as? NSNumber,
                  let file = attributes[.systemFileNumber] as? NSNumber else { return nil }
            return [volume, file]
        }
        guard let first = identity(first), let second = identity(second) else { return false }
        return first == second
    }

    private func headTail(_ args: [String], stdin: String?, head: Bool) throws -> CommandResult {
        var count = 10
        var files: [String] = []
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            if arg == "-n", let value = iterator.next(), let number = Int(value) {
                count = number
            } else if arg.hasPrefix("-"), let number = Int(arg.dropFirst()) {
                count = number
            } else {
                files.append(arg)
            }
        }
        if count < 0 {
            // head(1) refuses a negative count; tail(1) counts from the end either way.
            guard !head else { return CommandResult(stderr: "head: illegal line count -- \(count)\n", exitCode: 1) }
            count = Int(clamping: count.magnitude)
        }
        let text = files.isEmpty ? (stdin ?? "") : try cat(files, stdin: nil).stdout
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let selected = head ? Array(lines.prefix(count)) : Array(lines.suffix(count))
        return CommandResult(stdout: selected.isEmpty ? "" : selected.joined(separator: "\n") + "\n")
    }

    private func wc(_ args: [String], stdin: String?) throws -> CommandResult {
        let flags = Set(args.filter { $0.hasPrefix("-") }.flatMap { $0.dropFirst() })
        let files = args.filter { !$0.hasPrefix("-") }
        let text = files.isEmpty ? (stdin ?? "") : try cat(files, stdin: nil).stdout
        let lines = text.filter { $0 == "\n" }.count
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        let bytes = text.utf8.count
        var parts: [String] = []
        if flags.isEmpty || flags.contains("l") { parts.append(String(format: "%8d", lines)) }
        if flags.isEmpty || flags.contains("w") { parts.append(String(format: "%8d", words)) }
        if flags.isEmpty || flags.contains("c") { parts.append(String(format: "%8d", bytes)) }
        return CommandResult(stdout: parts.joined() + (files.count == 1 ? " \(files[0])" : "") + "\n")
    }

    private func grep(_ args: [String], stdin: String?) throws -> CommandResult {
        let flags = Set(args.filter { $0.hasPrefix("-") && $0.count > 1 }.flatMap { $0.dropFirst() })
        let operands = args.filter { !($0.hasPrefix("-") && $0.count > 1) }
        guard let pattern = operands.first else { return CommandResult(stderr: "usage: grep [-inrvcl] pattern [file ...]\n", exitCode: 2) }
        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return CommandResult(stderr: "grep: invalid regular expression\n", exitCode: 2)
        }
        let invert = flags.contains("v")
        let numbered = flags.contains("n")
        let countOnly = flags.contains("c")
        let namesOnly = flags.contains("l")
        var sources: [(name: String?, text: String)] = []
        var files = Array(operands.dropFirst())
        if flags.contains("r") || flags.contains("R") {
            if files.isEmpty { files = ["."] }
            files = try files.flatMap { try allFiles(under: resolve($0)).map { "/" + $0 } }
        }
        if files.isEmpty {
            sources = [(nil, stdin ?? "")]
        } else {
            for file in files {
                guard let data = FileManager.default.contents(atPath: url(for: try resolve(file)).path), let (text, _) = TextFileCodec.decode(data) else { continue }
                sources.append((files.count > 1 || flags.contains("r") ? String(file.drop { $0 == "/" }) : nil, text))
            }
        }
        var output = ""
        var matched = false
        for source in sources {
            var count = 0
            let lines = source.text.components(separatedBy: "\n")
            for (number, line) in lines.enumerated() where !(number == lines.count - 1 && line.isEmpty) {
                let isMatch = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
                guard isMatch != invert else { continue }
                count += 1
                matched = true
                if countOnly || namesOnly { continue }
                var prefix = source.name.map { "\u{1B}[35m\($0)\u{1B}[0m:" } ?? ""
                if numbered { prefix += "\u{1B}[32m\(number + 1)\u{1B}[0m:" }
                let highlighted = invert ? line : regex.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "\u{1B}[1;31m$0\u{1B}[0m")
                output += prefix + highlighted + "\n"
            }
            if countOnly { output += (source.name.map { "\($0):" } ?? "") + "\(count)\n" }
            if namesOnly, count > 0, let name = source.name { output += name + "\n" }
        }
        return CommandResult(stdout: output, exitCode: matched ? 0 : 1)
    }

    private func find(_ args: [String]) throws -> CommandResult {
        var start = "."
        var namePattern: Glob?
        var type: String?
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "-name", "-iname": namePattern = iterator.next().map { Glob($0) }
            case "-type": type = iterator.next()
            default: start = arg
            }
        }
        let base = try resolve(start)
        // The start directory is printed only when it passes the filters, as in find(1).
        let startMatches = type != "f" && (namePattern?.matches(base.isEmpty ? "." : WorkspacePath.name(of: base)) ?? true)
        var output = startMatches ? start + "\n" : ""
        for path in try allFiles(under: base, includeDirectories: true) {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url(for: path).path, isDirectory: &isDirectory)
            if type == "f", isDirectory.boolValue { continue }
            if type == "d", !isDirectory.boolValue { continue }
            if let namePattern, !namePattern.matches(WorkspacePath.name(of: path)) { continue }
            let relative = base.isEmpty ? path : String(path.dropFirst(base.count + 1))
            output += (start == "." ? "./" : start.hasSuffix("/") ? start : start + "/") + relative + "\n"
        }
        return CommandResult(stdout: output)
    }

    private func tree(_ args: [String]) throws -> CommandResult {
        let base = try resolve(args.first(where: { !$0.hasPrefix("-") }) ?? ".")
        var output = (base.isEmpty ? "." : WorkspacePath.name(of: base)) + "\n"
        var directories = 0
        var files = 0
        func walk(_ path: String, prefix: String) throws {
            let names = try FileManager.default.contentsOfDirectory(atPath: url(for: path).path)
                .filter { !$0.hasPrefix(".") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            for (index, name) in names.enumerated() {
                let child = WorkspacePath.join(path, name)
                let last = index == names.count - 1
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url(for: child).path, isDirectory: &isDirectory)
                output += prefix + (last ? "└── " : "├── ") + (isDirectory.boolValue ? "\u{1B}[1;34m\(name)\u{1B}[0m" : name) + "\n"
                if isDirectory.boolValue {
                    directories += 1
                    try walk(child, prefix: prefix + (last ? "    " : "│   "))
                } else {
                    files += 1
                }
            }
        }
        try walk(base, prefix: "")
        output += "\n\(directories) director\(directories == 1 ? "y" : "ies"), \(files) file\(files == 1 ? "" : "s")\n"
        return CommandResult(stdout: output)
    }

    private func sort(_ args: [String], stdin: String?) throws -> CommandResult {
        let flags = Set(args.filter { $0.hasPrefix("-") }.flatMap { $0.dropFirst() })
        let files = args.filter { !$0.hasPrefix("-") }
        let text = files.isEmpty ? (stdin ?? "") : try cat(files, stdin: nil).stdout
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if flags.contains("n") {
            lines.sort { (Double($0.trimmingCharacters(in: .whitespaces)) ?? 0) < (Double($1.trimmingCharacters(in: .whitespaces)) ?? 0) }
        } else {
            lines.sort()
        }
        if flags.contains("r") { lines.reverse() }
        if flags.contains("u") { lines = lines.reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } } }
        return CommandResult(stdout: lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n")
    }

    private func uniq(_ args: [String], stdin: String?) throws -> CommandResult {
        let counted = args.contains("-c")
        let files = args.filter { !$0.hasPrefix("-") }
        let text = files.isEmpty ? (stdin ?? "") : try cat(files, stdin: nil).stdout
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var output: [(String, Int)] = []
        for line in lines {
            if let last = output.last, last.0 == line {
                output[output.count - 1].1 += 1
            } else {
                output.append((line, 1))
            }
        }
        let rendered = output.map { counted ? String(format: "%4d %@", $0.1, $0.0) : $0.0 }
        return CommandResult(stdout: rendered.isEmpty ? "" : rendered.joined(separator: "\n") + "\n")
    }

    private func stat(_ args: [String]) throws -> CommandResult {
        var output = ""
        for target in args {
            let attributes = try FileManager.default.attributesOfItem(atPath: url(for: try resolve(target)).path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date).map { Self.dateFormatter.string(from: $0) } ?? "?"
            let kind = (attributes[.type] as? FileAttributeType) == .typeDirectory ? "directory" : "regular file"
            output += "  File: \(target)\n  Size: \(size)\tType: \(kind)\nModify: \(modified)\n"
        }
        return CommandResult(stdout: output)
    }

    private func seq(_ args: [String]) -> CommandResult {
        let numbers = args.compactMap(Int.init)
        let (first, last) = numbers.count >= 2 ? (numbers[0], numbers[1]) : (1, numbers.first ?? 1)
        guard first <= last, last - first < 100_000 else { return CommandResult() }
        return CommandResult(stdout: (first...last).map(String.init).joined(separator: "\n") + "\n")
    }

    private func export(_ args: [String]) -> CommandResult {
        for assignment in args {
            if let equals = assignment.firstIndex(of: "=") {
                environment[String(assignment[..<equals])] = String(assignment[assignment.index(after: equals)...])
            }
        }
        return CommandResult()
    }

    // MARK: - Paths

    /// Resolves a shell path (absolute from the workspace root, or relative to
    /// the working directory) to a workspace path.
    func resolve(_ path: String) throws -> String {
        if path == "~" || path.hasPrefix("~/") { return try WorkspacePath.normalize(String(path.dropFirst())) }
        if path.hasPrefix("/") { return try WorkspacePath.normalize(path) }
        return try WorkspacePath.normalize(WorkspacePath.join(cwd, path))
    }

    private func url(for path: String) -> URL {
        path.isEmpty ? root : root.appendingPathComponent(path)
    }

    private func allFiles(under path: String, includeDirectories: Bool = false) throws -> [String] {
        var results: [String] = []
        let base = url(for: path)
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        while let item = enumerator.nextObject() as? URL {
            if item.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory, !includeDirectories { continue }
            results.append(WorkspacePath.join(path, WorkspaceSearch.relativePath(of: item, base: base)))
        }
        return results.sorted()
    }

    /// Pathname expansion of a word's last path segment (see `ShellPattern`):
    /// the matching names in that folder, sorted and without hidden files, or
    /// `literal`, the word without its quotes, when none match, as in sh.
    private func expandPattern(_ pattern: String, literal: String) -> [String] {
        let directoryPart = ShellPattern.unescaped(WorkspacePath.parent(of: pattern))
        guard let directory = try? resolve(directoryPart.isEmpty ? "." : directoryPart),
              let names = try? FileManager.default.contentsOfDirectory(atPath: url(for: directory).path) else { return [literal] }
        let matcher = ShellPattern(WorkspacePath.name(of: pattern))
        let matches = names.filter { !$0.hasPrefix(".") && matcher.matches($0) }.sorted()
        if matches.isEmpty { return [literal] }
        return matches.map { directoryPart.isEmpty ? $0 : WorkspacePath.join(directoryPart, $0) }
    }

    /// File-name completions for the last word of a partial command line.
    public func completions(for line: String) -> [String] {
        let word = line.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let isFirstWord = !line.trimmingCharacters(in: .whitespaces).contains(" ")
        if isFirstWord {
            return Self.commands.filter { $0.hasPrefix(word) }
        }
        let directoryPart = word.contains("/") ? String(word[..<word.lastIndex(of: "/")!]) : ""
        let prefix = word.contains("/") ? String(word[word.index(after: word.lastIndex(of: "/")!)...]) : word
        guard let directory = try? resolve(directoryPart.isEmpty ? "." : (directoryPart.isEmpty && word.hasPrefix("/") ? "/" : directoryPart.isEmpty ? "." : directoryPart)),
              let names = try? FileManager.default.contentsOfDirectory(atPath: url(for: directory).path) else { return [] }
        return names.filter { $0.hasPrefix(prefix) && (prefix.hasPrefix(".") || !$0.hasPrefix(".")) }.sorted().map { name in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url(for: WorkspacePath.join(directory, name)).path, isDirectory: &isDirectory)
            let completed = directoryPart.isEmpty ? name : directoryPart + "/" + name
            return isDirectory.boolValue ? completed + "/" : completed
        }
    }

    private func describe(_ error: Error) -> String {
        if let error = error as? WorkspaceError, let description = error.errorDescription { return description }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return "No such file or directory"
            case NSFileWriteFileExistsError: return "File exists"
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return "Permission denied"
            default: break
            }
        }
        return nsError.localizedDescription
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d HH:mm:ss zzz yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static let lsDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

// MARK: - Lexing

enum ShellToken: Equatable {
    /// A word after quote removal. `pattern` is set when an unquoted `*`, `?`
    /// or `[` makes the word a pathname pattern: the same text with each
    /// quoted or escaped pattern character escaped by a backslash, so that,
    /// as in sh, only the unquoted characters act as wildcards.
    case word(String, pattern: String?)
    case op(String)
}

enum ShellLexer {
    enum LexError: Error, CustomStringConvertible {
        case unterminatedQuote
        var description: String { "unterminated quote" }
    }

    /// Characters with a meaning in a pathname pattern, escaped when quoted.
    private static let patternCharacters: Set<Character> = ["*", "?", "[", "]", "{", "}", ",", "\\"]

    /// Splits a command line at `;`, `&&` and `||` outside quotes. Each entry
    /// carries the separator that follows it (`;` for the last one).
    static func splitList(_ line: String) throws -> [(command: String, separator: String)] {
        var entries: [(String, String)] = []
        var current = ""
        var quote: Character?
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if let open = quote {
                current.append(character)
                if character == "\\", open == "\"", index + 1 < characters.count {
                    current.append(characters[index + 1])
                    index += 2
                    continue
                }
                if character == open { quote = nil }
                index += 1
                continue
            }
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            if character == "'" || character == "\"" {
                quote = character
                current.append(character)
            } else if character == "\\", let next {
                current.append(character)
                current.append(next)
                index += 2
                continue
            } else if character == ";" {
                entries.append((current, ";"))
                current = ""
            } else if (character == "&" && next == "&") || (character == "|" && next == "|") {
                entries.append((current, String([character, character])))
                current = ""
                index += 2
                continue
            } else {
                current.append(character)
            }
            index += 1
        }
        if quote != nil { throw LexError.unterminatedQuote }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty || entries.isEmpty { entries.append((current, ";")) }
        return entries
    }

    static func tokenize(_ line: String, environment: [String: String], lastExitCode: Int32) throws -> [ShellToken] {
        var tokens: [ShellToken] = []
        var current = ""
        // The word as a pathname pattern, and whether an unquoted wildcard makes it one.
        var pattern = ""
        var isPattern = false
        var hasWord = false
        let characters = Array(line)
        var index = 0

        func flush() {
            if hasWord { tokens.append(.word(current, pattern: isPattern ? pattern : nil)) }
            current = ""
            pattern = ""
            isPattern = false
            hasWord = false
        }

        /// Unquoted text, whose `*`, `?`, `[` and braces act as a pattern.
        func appendUnquoted(_ text: String) {
            current += text
            for character in text {
                // A backslash here comes from a variable's value and stays literal.
                if character == "\\" { pattern.append("\\") }
                pattern.append(character)
                if character == "*" || character == "?" || character == "[" { isPattern = true }
            }
        }

        /// Quoted or escaped text, which only matches itself.
        func appendQuoted(_ text: String) {
            current += text
            for character in text {
                if patternCharacters.contains(character) { pattern.append("\\") }
                pattern.append(character)
            }
        }

        func expandVariable(at position: inout Int) -> String {
            // `position` is at the `$`.
            var name = ""
            var cursor = position + 1
            if cursor < characters.count, characters[cursor] == "{" {
                cursor += 1
                while cursor < characters.count, characters[cursor] != "}" { name.append(characters[cursor]); cursor += 1 }
                cursor += 1
            } else if cursor < characters.count, characters[cursor] == "?" {
                position = cursor + 1
                return String(lastExitCode)
            } else {
                while cursor < characters.count, characters[cursor].isLetter || characters[cursor].isNumber || characters[cursor] == "_" {
                    name.append(characters[cursor])
                    cursor += 1
                }
            }
            position = cursor
            return name.isEmpty ? "$" : environment[name] ?? ""
        }

        while index < characters.count {
            let character = characters[index]
            switch character {
            case " ", "\t":
                flush()
                index += 1
            case "'":
                guard let close = characters[(index + 1)...].firstIndex(of: "'") else { throw LexError.unterminatedQuote }
                appendQuoted(String(characters[(index + 1)..<close]))
                hasWord = true
                index = close + 1
            case "\"":
                index += 1
                hasWord = true
                var closed = false
                while index < characters.count {
                    let inner = characters[index]
                    if inner == "\"" { closed = true; index += 1; break }
                    if inner == "\\", index + 1 < characters.count, "\"\\$`".contains(characters[index + 1]) {
                        appendQuoted(String(characters[index + 1]))
                        index += 2
                    } else if inner == "$" {
                        appendQuoted(expandVariable(at: &index))
                    } else {
                        appendQuoted(String(inner))
                        index += 1
                    }
                }
                if !closed { throw LexError.unterminatedQuote }
            case "\\":
                // A backslash quotes only the next character: `\*` is literal, the rest of the word is not.
                if index + 1 < characters.count { appendQuoted(String(characters[index + 1])) }
                hasWord = true
                index += 2
            case "$":
                appendUnquoted(expandVariable(at: &index))
                hasWord = true
            case ";":
                flush()
                tokens.append(.op(";"))
                index += 1
            case "&" where index + 1 < characters.count && characters[index + 1] == "&":
                flush()
                tokens.append(.op("&&"))
                index += 2
            case "|":
                flush()
                if index + 1 < characters.count, characters[index + 1] == "|" {
                    tokens.append(.op("||"))
                    index += 2
                } else {
                    tokens.append(.op("|"))
                    index += 1
                }
            case ">":
                flush()
                if index + 1 < characters.count, characters[index + 1] == ">" {
                    tokens.append(.op(">>"))
                    index += 2
                } else {
                    tokens.append(.op(">"))
                    index += 1
                }
            case "~" where !hasWord && (index + 1 == characters.count || characters[index + 1] == "/" || characters[index + 1] == " "):
                appendUnquoted("/")
                hasWord = true
                index += 1
                if index < characters.count, characters[index] == "/" { index += 1 }
            default:
                appendUnquoted(String(character))
                hasWord = true
                index += 1
            }
        }
        flush()
        return tokens
    }
}

/// A pathname pattern for one path segment, as the lexer builds it: `*`, `?`
/// and `[...]` as in sh (`!` or `^` negates a set, `a-z` is a range, and a
/// `[` that never closes is an ordinary character), a backslash escaping the
/// next character, and `{a,b}` alternatives. Characters compare as Swift
/// characters, so `?` matches one `é`.
struct ShellPattern {
    private enum Token {
        case literal(Character)
        case anyCharacter
        case anyRun
        case set([ClosedRange<Character>], negated: Bool)

        func matches(_ character: Character) -> Bool {
            switch self {
            case .literal(let literal): return literal == character
            case .anyCharacter: return true
            case .anyRun: return false
            case .set(let ranges, let negated): return ranges.contains(where: { $0.contains(character) }) != negated
            }
        }
    }

    /// The tokens of each `{a,b}` alternative.
    private let tokenLists: [[Token]]

    init(_ pattern: String) {
        tokenLists = Self.alternatives(pattern).map(Self.compile)
    }

    func matches(_ name: String) -> Bool {
        let characters = Array(name)
        return tokenLists.contains { Self.match($0, characters) }
    }

    private static func compile(_ pattern: String) -> [Token] {
        let characters = Array(pattern)
        var tokens: [Token] = []
        var index = 0
        while index < characters.count {
            switch characters[index] {
            case "\\" where index + 1 < characters.count:
                tokens.append(.literal(characters[index + 1]))
                index += 1
            case "*":
                tokens.append(.anyRun)
            case "?":
                tokens.append(.anyCharacter)
            case "[":
                if let set = compileSet(characters, from: index) {
                    tokens.append(set.token)
                    index = set.end - 1
                } else {
                    tokens.append(.literal("["))
                }
            case let character:
                tokens.append(.literal(character))
            }
            index += 1
        }
        return tokens
    }

    /// The `[...]` set at `start` and the index just after it, or nil when it
    /// never closes.
    private static func compileSet(_ characters: [Character], from start: Int) -> (token: Token, end: Int)? {
        var index = start + 1
        let negated = index < characters.count && (characters[index] == "!" || characters[index] == "^")
        if negated { index += 1 }
        var ranges: [ClosedRange<Character>] = []
        var isFirst = true
        // The member at `index`, which a backslash escapes; moves `index` past it.
        func member() -> Character {
            if characters[index] == "\\", index + 1 < characters.count { index += 1 }
            defer { index += 1 }
            return characters[index]
        }
        while index < characters.count {
            // A `]` right after the `[` (or `[!`) is a member, not the end.
            if characters[index] == "]", !isFirst { return (.set(ranges, negated: negated), index + 1) }
            isFirst = false
            let low = member()
            if index + 1 < characters.count, characters[index] == "-", characters[index + 1] != "]" {
                index += 1
                let high = member()
                if low <= high { ranges.append(low...high) }
            } else {
                ranges.append(low...low)
            }
        }
        return nil
    }

    /// Wildcard matching that lets the last `*` take more characters whenever the rest fails.
    private static func match(_ tokens: [Token], _ name: [Character]) -> Bool {
        var token = 0
        var position = 0
        // The token after the last `*`, and the position that `*` has reached.
        var resume: (token: Int, position: Int)?
        while position < name.count {
            if token < tokens.count, case .anyRun = tokens[token] {
                token += 1
                resume = (token, position)
            } else if token < tokens.count, tokens[token].matches(name[position]) {
                token += 1
                position += 1
            } else if let last = resume {
                resume = (last.token, last.position + 1)
                token = last.token
                position = last.position + 1
            } else {
                return false
            }
        }
        while token < tokens.count, case .anyRun = tokens[token] { token += 1 }
        return token == tokens.count
    }

    /// The text a pattern stands for literally: its escapes removed.
    static func unescaped(_ pattern: String) -> String {
        var result = ""
        var isEscaped = false
        for character in pattern {
            if character == "\\", !isEscaped {
                isEscaped = true
                continue
            }
            result.append(character)
            isEscaped = false
        }
        return result
    }

    /// The patterns that `{a,b,...}` groups stand for: `*.{js,ts}` gives
    /// `*.js` and `*.ts`. Escaped braces and commas, and a group without a
    /// comma, are literal.
    private static func alternatives(_ pattern: String) -> [String] {
        let characters = Array(pattern)
        var depth = 0
        var open = 0
        var commas: [Int] = []
        var index = 0
        while index < characters.count {
            switch characters[index] {
            case "\\":
                index += 1
            case "{":
                if depth == 0 {
                    open = index
                    commas = []
                }
                depth += 1
            case "," where depth == 1:
                commas.append(index)
            case "}" where depth > 0:
                depth -= 1
                guard depth == 0, !commas.isEmpty else { break }
                let prefix = String(characters[..<open])
                let suffix = String(characters[(index + 1)...])
                var choices: [String] = []
                var start = open + 1
                for end in commas + [index] {
                    choices.append(String(characters[start..<end]))
                    start = end + 1
                }
                return choices.flatMap { alternatives(prefix + $0 + suffix) }
            default:
                break
            }
            index += 1
        }
        return [pattern]
    }
}
