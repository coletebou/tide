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
}
