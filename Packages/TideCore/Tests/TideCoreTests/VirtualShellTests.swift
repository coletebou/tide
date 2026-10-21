import Foundation
import Testing
@testable import TideCore

/// Strips ANSI escape sequences and `\r` so assertions read plainly.
private func plain(_ output: ShellOutput) -> String {
    output.text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).replacingOccurrences(of: "\r\n", with: "\n")
}

struct VirtualShellTests {
    @Test func navigatesAndLists() throws {
        let workspace = try TemporaryWorkspace(["src/main.swift": "print(\"hi\")\n", "README.md": "# Tide\n", ".hidden": ""])
        let shell = VirtualShell(root: workspace.url)
        #expect(plain(shell.run("pwd")) == "/\n")
        #expect(plain(shell.run("ls")) == "README.md\nsrc\n")
        #expect(plain(shell.run("ls -a")).contains(".hidden"))
        #expect(shell.run("cd src").exitCode == 0)
        #expect(plain(shell.run("pwd")) == "/src\n")
        #expect(plain(shell.run("cat main.swift")) == "print(\"hi\")\n")
        #expect(shell.run("cd ..").exitCode == 0)
        #expect(plain(shell.run("cd nope")) == "cd: no such file or directory: nope\n")
        #expect(shell.run("cd ../..").exitCode == 1)
        #expect(plain(shell.run("pwd")) == "/\n")
    }

    @Test func createsMovesAndRemovesFiles() throws {
        let workspace = try TemporaryWorkspace()
        let shell = VirtualShell(root: workspace.url)
        #expect(shell.run("mkdir -p a/b && touch a/b/one.txt && echo hello > a/two.txt").exitCode == 0)
        #expect(workspace.read("a/two.txt") == "hello\n")
        #expect(shell.run("echo again >> a/two.txt").exitCode == 0)
        #expect(workspace.read("a/two.txt") == "hello\nagain\n")
        #expect(shell.run("cp a/two.txt a/three.txt; mv a/three.txt a/b/").exitCode == 0)
        #expect(workspace.read("a/b/three.txt") == "hello\nagain\n")
        #expect(shell.run("rm a").exitCode == 1)
        #expect(shell.run("rm -r a").exitCode == 0)
        #expect(plain(shell.run("ls")) == "")
        #expect(plain(shell.run("rm -rf /")) == "rm: refusing to remove the workspace root\n")
    }

    @Test func pipesFiltersAndVariables() throws {
        let workspace = try TemporaryWorkspace(["list.txt": "pear\napple\nfig\napple\n"])
        let shell = VirtualShell(root: workspace.url)
        #expect(plain(shell.run("cat list.txt | sort | uniq -c")) == "   2 apple\n   1 fig\n   1 pear\n")
        #expect(plain(shell.run("grep -n app list.txt")) == "2:apple\n4:apple\n")
        #expect(plain(shell.run("cat list.txt | wc -l")) == "       4\n")
        #expect(plain(shell.run("head -n 2 list.txt")) == "pear\napple\n")
        #expect(plain(shell.run("tail -1 list.txt")) == "apple\n")
        #expect(plain(shell.run("export NAME=Tide; echo \"hi $NAME\" '$NAME'")) == "hi Tide $NAME\n")
        #expect(plain(shell.run("false || echo recovered")) == "recovered\n")
        #expect(plain(shell.run("false && echo skipped")) == "")
        #expect(plain(shell.run("echo $?")) == "1\n")
        #expect(plain(shell.run("seq 3 | sort -r")) == "3\n2\n1\n")
    }

    @Test func globsFindAndTree() throws {
        let workspace = try TemporaryWorkspace(["a.swift": "", "b.swift": "", "c.md": "", "dir/d.swift": ""])
        let shell = VirtualShell(root: workspace.url)
        #expect(plain(shell.run("echo *.swift")) == "a.swift b.swift\n")
        #expect(plain(shell.run("echo '*.swift'")) == "*.swift\n")
        // Like bash, an unquoted glob expands before find sees it, so quote it.
        #expect(plain(shell.run("find . -name '*.swift' -type f")) == "./a.swift\n./b.swift\n./dir/d.swift\n")
        let tree = plain(shell.run("tree"))
        #expect(tree.contains("└── dir"))
        #expect(tree.hasSuffix("1 directory, 4 files\n"))
        #expect(plain(shell.run("grep -rl x .")) == "")
    }

    @Test func reportsUnknownCommandsAndOpensFiles() throws {
        let workspace = try TemporaryWorkspace(["notes.md": ""])
        let shell = VirtualShell(root: workspace.url)
        let missing = shell.run("gcc main.c")
        #expect(missing.exitCode == 127)
        #expect(plain(missing) == "tide-sh: command not found: gcc\n")
        #expect(shell.run("code notes.md new.txt").openFiles == ["notes.md", "new.txt"])
        #expect(workspace.read("new.txt") == "")
        #expect(shell.run("clear").clearScreen)
        #expect(shell.history.last == "clear")
        #expect(plain(shell.run("echo \"unterminated")) == "tide-sh: unterminated quote\n")
    }

    @Test func completesCommandsAndPaths() throws {
        let workspace = try TemporaryWorkspace(["Sources/App.swift": "", "Sources/Auth.swift": "", "README.md": ""])
        let shell = VirtualShell(root: workspace.url)
        #expect(shell.completions(for: "gr") == ["grep"])
        #expect(shell.completions(for: "cat Sou") == ["Sources/"])
        #expect(shell.completions(for: "cat Sources/A") == ["Sources/App.swift", "Sources/Auth.swift"])
    }

    @Test func outputUsesTerminalLineEndings() throws {
        let workspace = try TemporaryWorkspace()
        let shell = VirtualShell(root: workspace.url)
        #expect(shell.run("printf 'a\\nb\\n'").text == "a\r\nb\r\n")
        #expect(shell.prompt.contains("tide"))
    }

    /// As with cp(1) and mv(1), nothing is removed until the source is known
    /// to be usable, and a source that is its own destination is left alone.
    @Test func copyAndMoveNeverRemoveTheirDestinationFirst() throws {
        let workspace = try TemporaryWorkspace(["notes.txt": "keep me\n", "a.txt": "a\n", "dir/b.txt": "b\n"])
        let shell = VirtualShell(root: workspace.url)
        #expect(plain(shell.run("cp notes.txt notes.txt")) == "cp: notes.txt and notes.txt are identical (not copied).\n")
        #expect(plain(shell.run("mv notes.txt .")) == "mv: notes.txt and ./notes.txt are identical\n")
        #expect(shell.run("cp *.txt .").exitCode == 1)
        #expect(shell.run("cp dir/b.txt dir/").exitCode == 1)
        #expect(workspace.read("notes.txt") == "keep me\n")
        #expect(workspace.read("a.txt") == "a\n")
        #expect(workspace.read("dir/b.txt") == "b\n")

        // A missing source leaves an existing destination alone.
        #expect(plain(shell.run("cp missing.txt notes.txt")) == "cp: missing.txt: No such file or directory\n")
        #expect(plain(shell.run("mv missing.txt notes.txt")) == "mv: missing.txt: No such file or directory\n")
        #expect(workspace.read("notes.txt") == "keep me\n")

        // A folder cannot go inside itself, and the workspace root cannot be copied or moved.
        #expect(plain(shell.run("cp dir dir/inner")) == "cp: cannot copy dir into itself\n")
        #expect(plain(shell.run("mv dir dir/inner")) == "mv: cannot move dir into itself\n")
        #expect(plain(shell.run("cp . .")) == "cp: refusing to copy the workspace root\n")
        #expect(plain(shell.run("mv / moved")) == "mv: refusing to move the workspace root\n")
        #expect(workspace.read("dir/b.txt") == "b\n")

        // A file does not replace a folder, nor a folder a file.
        try FileManager.default.createDirectory(at: workspace.url.appendingPathComponent("box/a.txt"), withIntermediateDirectories: true)
        #expect(plain(shell.run("cp a.txt box")) == "cp: box/a.txt: Is a directory\n")
        #expect(plain(shell.run("mv dir notes.txt")) == "mv: notes.txt: Not a directory\n")
        #expect(workspace.read("notes.txt") == "keep me\n")
        #expect(workspace.read("dir/b.txt") == "b\n")

        // Replacing a different file still works.
        #expect(shell.run("cp a.txt notes.txt").exitCode == 0)
        #expect(workspace.read("notes.txt") == "a\n")
        #expect(shell.run("mv a.txt dir/b.txt").exitCode == 0)
        #expect(workspace.read("dir/b.txt") == "a\n")
        #expect(workspace.read("a.txt") == nil)
    }

    /// `>>` adds bytes to the end of the file; it never re-encodes or drops what was there.
    @Test func appendingKeepsTheExistingBytes() throws {
        let workspace = try TemporaryWorkspace()
        let legacy = workspace.url.appendingPathComponent("legacy.txt")
        // "café" in Windows-1252, which is not valid UTF-8.
        let original = Data([0x63, 0x61, 0x66, 0xE9, 0x0A])
        try original.write(to: legacy)
        let shell = VirtualShell(root: workspace.url)
        #expect(shell.run("echo note >> legacy.txt").exitCode == 0)
        #expect(try Data(contentsOf: legacy) == original + Data("note\n".utf8))
        #expect(shell.run("echo first >> new.txt && echo second >> new.txt").exitCode == 0)
        #expect(workspace.read("new.txt") == "first\nsecond\n")
    }

    /// A backslash quotes the character after it, so `\*` is a file named `*`, not a glob.
    @Test func escapedWildcardsAreLiteral() throws {
        let workspace = try TemporaryWorkspace(["*": "star\n", "keep.txt": "keep\n", "what?": "question\n"])
        let shell = VirtualShell(root: workspace.url)
        #expect(plain(shell.run("echo \\*")) == "*\n")
        #expect(plain(shell.run("echo what\\?")) == "what?\n")
        #expect(shell.run("rm \\*").exitCode == 0)
        #expect(workspace.read("*") == nil)
        #expect(workspace.read("keep.txt") == "keep\n")
        #expect(plain(shell.run("echo *")) == "keep.txt what?\n")
    }

    @Test func rmdirRefusesTheWorkspaceRoot() throws {
        let workspace = try TemporaryWorkspace()
        let shell = VirtualShell(root: workspace.url)
        #expect(plain(shell.run("rmdir .")) == "rmdir: refusing to remove the workspace root\n")
        #expect(plain(shell.run("rmdir /")) == "rmdir: refusing to remove the workspace root\n")
        #expect(FileManager.default.fileExists(atPath: workspace.url.path))
        #expect(shell.run("mkdir empty && rmdir empty").exitCode == 0)
    }

    #if os(macOS)
    /// Swift's `prefix` and `suffix` trap on negative lengths.
    @Test func negativeHeadCountDoesNotCrash() async {
        await #expect(processExitsWith: .success) {
            let workspace = try TemporaryWorkspace(["list.txt": "1\n2\n3\n"])
            _ = VirtualShell(root: workspace.url).run("head -n -1 list.txt")
        }
    }

    @Test func negativeTailCountDoesNotCrash() async {
        await #expect(processExitsWith: .success) {
            let workspace = try TemporaryWorkspace(["list.txt": "1\n2\n3\n"])
            _ = VirtualShell(root: workspace.url).run("tail -n -1 list.txt")
        }
    }
    #endif
}

struct LineEditorTests {
    /// Everything in one chunk of input is processed, including what follows
    /// Enter or ⌃C, so a pasted script runs every line.
    @Test func keepsInputAfterEnterAndInterrupt() {
        var editor = LineEditor()
        let lines = editor.feed(Array("pwd\recho hi\r".utf8), history: [])
        #expect(lines == [.output("pwd\r\n"), .submit("pwd"), .output("echo hi\r\n"), .submit("echo hi")])
        let interrupted = editor.feed(Array("oops\u{03}ls\r".utf8), history: [])
        #expect(interrupted == [.output("oops^C\r\n"), .interrupt, .output("ls\r\n"), .submit("ls")])
        // Text after the last line break stays in the editor.
        let partial = editor.feed(Array("cd src\nmake".utf8), history: [])
        #expect(partial == [.output("cd src\r\n"), .submit("cd src"), .output("make")])
        #expect(editor.line == "make")
    }

    /// A CRLF pair, as in text pasted from Windows files, is a single Enter.
    @Test func carriageReturnLineFeedIsOneEnter() {
        var editor = LineEditor()
        let pasted = editor.feed(Array("a\r\nb\r\n".utf8), history: [])
        #expect(pasted == [.output("a\r\n"), .submit("a"), .output("b\r\n"), .submit("b")])
        let lineFeed = editor.feed(Array("\n".utf8), history: [])
        #expect(lineFeed == [.output("\r\n"), .submit("")])
    }
}
