import Foundation
import Testing
@testable import TideCore

struct GitStatusTests {
    @Test func freshRepositoryListsUntrackedFilesIndividually() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        try sandbox.write("a\n", to: "a.txt", in: repository)
        try sandbox.write("b\n", to: "dir/sub/b.txt", in: repository)
        try FileManager.default.createDirectory(at: repository.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let ours = try sandbox.swiftStatus(repository)
        #expect(ours == ["?? a.txt", "?? dir/sub/b.txt"])
        #expect(ours == (try sandbox.porcelainStatus(repository)))
    }

    @Test func reportsStagedUnstagedDeletedAndUntrackedChanges() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        for path in ["modified.txt", "staged.txt", "both.txt", "deleted.txt", "removed.txt", "src/nested/deep.swift", "untouched.txt"] {
            try sandbox.write("original \(path)\n", to: path, in: repository)
        }
        try sandbox.commitAll("initial", in: repository)

        try sandbox.write("changed in work tree\n", to: "modified.txt", in: repository)
        try sandbox.write("changed and staged\n", to: "staged.txt", in: repository)
        try sandbox.git("add", "staged.txt", in: repository)
        try sandbox.write("staged version\n", to: "both.txt", in: repository)
        try sandbox.git("add", "both.txt", in: repository)
        try sandbox.write("then changed again\n", to: "both.txt", in: repository)
        try sandbox.remove("deleted.txt", in: repository)
        try sandbox.git("rm", "-q", "removed.txt", in: repository)
        try sandbox.write("new and staged\n", to: "added.txt", in: repository)
        try sandbox.git("add", "added.txt", in: repository)
        try sandbox.write("new, staged, then deleted\n", to: "gone.txt", in: repository)
        try sandbox.git("add", "gone.txt", in: repository)
        try sandbox.remove("gone.txt", in: repository)
        try sandbox.write("new, staged, then edited\n", to: "edited.txt", in: repository)
        try sandbox.git("add", "edited.txt", in: repository)
        try sandbox.write("edited\n", to: "edited.txt", in: repository)
        try sandbox.write("deep change\n", to: "src/nested/deep.swift", in: repository)
        try sandbox.write("untracked\n", to: "src/nested/untracked.swift", in: repository)
        try sandbox.write("still on disk\n", to: "src/unstaged-delete.txt", in: repository)

        let status = try GitRepository.opened(repository).status()
        #expect(status.porcelainLines == (try sandbox.porcelainStatus(repository)))
        #expect(status.porcelainLines == [
            "A  added.txt", "MM both.txt", " D deleted.txt", "AM edited.txt", "AD gone.txt", " M modified.txt",
            "D  removed.txt", " M src/nested/deep.swift", "M  staged.txt", "?? src/nested/untracked.swift",
            "?? src/unstaged-delete.txt",
        ])
        let both = try #require(status.entries.first { $0.path == "both.txt" })
        #expect(both.index == .modified && both.workTree == .modified && !both.isUntracked)
        #expect(status.head.branchName == "main")
        #expect(status.upstream == nil && status.ahead == nil)
    }

    @Test func removedFromIndexButPresentOnDiskIsDeletedAndUntracked() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        try sandbox.write("keep\n", to: "file.txt", in: repository)
        try sandbox.commitAll("initial", in: repository)
        try sandbox.git("rm", "-q", "--cached", "file.txt", in: repository)
        #expect(try sandbox.swiftStatus(repository) == ["D  file.txt", "?? file.txt"])
        #expect(try sandbox.swiftStatus(repository) == sandbox.porcelainStatus(repository))
    }

    @Test func reportsTypeChangesAndExecutableBits() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        for path in ["becomes-link.txt", "script.sh", "staged-mode.sh", "link-target.txt"] {
            try sandbox.write("content of \(path)\n", to: path, in: repository)
        }
        try sandbox.symlink("link", to: "link-target.txt", in: repository)
        try sandbox.symlink("retargeted", to: "link-target.txt", in: repository)
        try sandbox.symlink("becomes-file", to: "link-target.txt", in: repository)
        try sandbox.commitAll("initial", in: repository)

        try sandbox.remove("becomes-link.txt", in: repository)
        try sandbox.symlink("becomes-link.txt", to: "link-target.txt", in: repository)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repository.appendingPathComponent("script.sh").path)
        try sandbox.git("update-index", "--chmod=+x", "staged-mode.sh", in: repository)
        try sandbox.remove("retargeted", in: repository)
        try sandbox.symlink("retargeted", to: "script.sh", in: repository)
        try sandbox.remove("becomes-file", in: repository)
        try sandbox.write("now a file\n", to: "becomes-file", in: repository)

        let ours = try sandbox.swiftStatus(repository)
        #expect(ours == (try sandbox.porcelainStatus(repository)))
        #expect(ours == [" T becomes-file", " T becomes-link.txt", " M retargeted", " M script.sh", "MM staged-mode.sh"])

        // With core.fileMode off, executable-bit changes are not reported.
        try sandbox.git("config", "core.filemode", "false", in: repository)
        #expect(try sandbox.swiftStatus(repository) == sandbox.porcelainStatus(repository))
    }

    @Test func reportsMergeConflictKinds() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        for path in ["both-modified.txt", "deleted-by-them.txt", "deleted-by-us.txt", "clean.txt"] {
            try sandbox.write("base \(path)\n", to: path, in: repository)
        }
        try sandbox.commitAll("base", in: repository)
        try sandbox.git("switch", "-q", "-c", "theirs", in: repository)
        try sandbox.write("theirs\n", to: "both-modified.txt", in: repository)
        try sandbox.remove("deleted-by-them.txt", in: repository)
        try sandbox.write("theirs edit\n", to: "deleted-by-us.txt", in: repository)
        try sandbox.write("theirs add\n", to: "both-added.txt", in: repository)
        try sandbox.commitAll("theirs", in: repository)
        try sandbox.git("switch", "-q", "main", in: repository)
        try sandbox.write("ours\n", to: "both-modified.txt", in: repository)
        try sandbox.write("ours edit\n", to: "deleted-by-them.txt", in: repository)
        try sandbox.remove("deleted-by-us.txt", in: repository)
        try sandbox.write("ours add\n", to: "both-added.txt", in: repository)
        try sandbox.commitAll("ours", in: repository)
        _ = try? sandbox.git("merge", "-q", "theirs", in: repository)
        try sandbox.write("untracked during merge\n", to: "notes.txt", in: repository)

        let status = try GitRepository.opened(repository).status()
        #expect(status.porcelainLines == (try sandbox.porcelainStatus(repository)))
        let conflicts = Dictionary(uniqueKeysWithValues: status.entries.compactMap { entry in entry.conflict.map { (entry.path, $0) } })
        #expect(conflicts == [
            "both-added.txt": .bothAdded, "both-modified.txt": .bothModified,
            "deleted-by-them.txt": .deletedByThem, "deleted-by-us.txt": .deletedByUs,
        ])
        #expect(GitConflict(stageMask: 1) == .bothDeleted)
        #expect(GitConflict(stageMask: 2) == .addedByUs)
        #expect(GitConflict(stageMask: 4) == .addedByThem)
    }

    @Test func intentToAddEntriesAreAddedInTheWorkTree() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        try sandbox.write("base\n", to: "base.txt", in: repository)
        try sandbox.commitAll("base", in: repository)
        try sandbox.write("intended\n", to: "intended.txt", in: repository)
        try sandbox.write("intended, then deleted\n", to: "vanished.txt", in: repository)
        try sandbox.git("add", "-N", "intended.txt", "vanished.txt", in: repository)
        try sandbox.remove("vanished.txt", in: repository)
        #expect(try sandbox.swiftStatus(repository) == [" A intended.txt", " D vanished.txt"])
        #expect(try sandbox.swiftStatus(repository) == sandbox.porcelainStatus(repository))
    }

    @Test func nestedRepositoriesAreReportedWholeAndIgnoredDirectoriesAreNotEntered() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        try sandbox.write("build/\n*.o\n", to: ".gitignore", in: repository)
        try sandbox.write("tracked\n", to: "build/tracked.txt", in: repository)
        try sandbox.git("add", "-f", "build/tracked.txt", in: repository)
        try sandbox.commitAll("initial", in: repository)
        try sandbox.write("changed\n", to: "build/tracked.txt", in: repository)
        try sandbox.write("untracked in ignored directory\n", to: "build/new.txt", in: repository)
        try sandbox.write("object\n", to: "src/main.o", in: repository)
        let nested = try sandbox.makeRepository("repo/vendor/nested")
        try sandbox.write("inside nested\n", to: "file.txt", in: nested)
        try FileManager.default.createDirectory(at: repository.appendingPathComponent("empty/deeper"), withIntermediateDirectories: true)

        let ours = try sandbox.swiftStatus(repository)
        #expect(ours == (try sandbox.porcelainStatus(repository)))
        #expect(ours == [" M build/tracked.txt", "?? vendor/nested/"])
    }

    @Test func handlesSpacesUnicodeAndSymlinkedDirectories() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        try sandbox.write("one\n", to: "with space/naïve café.txt", in: repository)
        try sandbox.write("two\n", to: "real/inside.txt", in: repository)
        try sandbox.write("quote\n", to: "odd\"name\\.txt", in: repository)
        try sandbox.commitAll("initial", in: repository)
        try sandbox.write("changed\n", to: "with space/naïve café.txt", in: repository)
        try sandbox.write("new\n", to: "über/neu.txt", in: repository)
        // A tracked file whose directory became a symbolic link counts as deleted.
        try FileManager.default.moveItem(at: repository.appendingPathComponent("real"), to: repository.appendingPathComponent("elsewhere"))
        try sandbox.symlink("real", to: "elsewhere", in: repository)
        #expect(try sandbox.swiftStatus(repository) == sandbox.porcelainStatus(repository))
    }

    /// Edits that keep the size and even the modification time are still found:
    /// the index's racy-entry rule and the inode change time catch them.
    @Test func detectsSameSizeEditsAndRestoredTimestamps() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        try sandbox.write("aaaa\n", to: "racy.txt", in: repository)
        try sandbox.write("cccc\n", to: "restored.txt", in: repository)
        try sandbox.write("eeee\n", to: "touched.txt", in: repository)
        try sandbox.commitAll("initial", in: repository)
        // Immediately after `git add`, same size, same second.
        try sandbox.write("bbbb\n", to: "racy.txt", in: repository)

        // Rewrite in place, then put back the exact (nanosecond) modification
        // time, so only the inode change time differs from the index.
        let restored = repository.appendingPathComponent("restored.txt").path
        var before = stat()
        #expect(lstat(restored, &before) == 0)
        try Data("dddd\n".utf8).write(to: URL(fileURLWithPath: restored))
        var times = [before.st_atimespec, before.st_mtimespec]
        #expect(utimensat(AT_FDCWD, restored, &times, 0) == 0)
        var after = stat()
        #expect(lstat(restored, &after) == 0)
        #expect(after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec && after.st_size == before.st_size && after.st_ino == before.st_ino)

        // Touching a file without changing it is not a change.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: repository.appendingPathComponent("touched.txt").path)

        let ours = try sandbox.swiftStatus(repository)
        #expect(ours == [" M racy.txt", " M restored.txt"])
        #expect(ours == (try sandbox.porcelainStatus(repository)))
    }

    /// Git hashes work-tree files through its line-ending conversion (the
    /// `text`, `eol` and `crlf` attributes, and `core.autocrlf`), so CRLF
    /// files whose blobs hold LF are unchanged once their timestamps no
    /// longer match the index.
    @Test func hashesThroughLineEndingConversionLikeGit() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        // Committed before any attributes exist, so its blob keeps CRLF and text=auto leaves it alone.
        try sandbox.write("old\r\nfile\r\n", to: "committed.auto", in: repository)
        try sandbox.commitAll("crlf blob", in: repository)
        try sandbox.write("""
            [attr]windows text eol=crlf
            *.text text
            *.crlf eol=crlf
            *.auto text=auto
            *.legacy crlf
            *.macro windows
            *.binary binary
            *.none -text

            """, to: ".gitattributes", in: repository)
        try sandbox.write("*.text -text\n*.auto !text\n", to: "raw/.gitattributes", in: repository)
        try sandbox.write("info.text -text\n", to: ".git/info/attributes", in: repository)
        let names = ["a.text", "changed.text", "b.crlf", "c.auto", "d.legacy", "e.macro", "f.binary", "g.none", "raw/h.text", "raw/i.auto", "info.text", "plain.txt"]
        for name in names {
            try sandbox.write("one\r\ntwo\r\n", to: name, in: repository)
        }
        try sandbox.write("lone\rcarriage return\r\n", to: "lone.text", in: repository)
        try sandbox.write(Data("nul\0byte\r\n".utf8), to: "nul.auto", in: repository)
        try sandbox.commitAll("crlf work tree", in: repository)
        // Same size, different content.
        try sandbox.write("uno\r\ntwo\r\n", to: "changed.text", in: repository)
        try Self.touch(names + ["committed.auto", "lone.text", "nul.auto"], in: repository)

        #expect(try sandbox.swiftStatus(repository) == sandbox.porcelainStatus(repository))
        #expect(try sandbox.swiftStatus(repository) == [" M changed.text"])

        // core.autocrlf converts files that no attribute covers, like text=auto.
        let autoCRLF = try sandbox.makeRepository("autocrlf")
        try sandbox.git("config", "core.autocrlf", "true", in: autoCRLF)
        try sandbox.write("one\r\ntwo\r\n", to: "file.txt", in: autoCRLF)
        try sandbox.commitAll("autocrlf", in: autoCRLF)
        try Self.touch(["file.txt"], in: autoCRLF)
        #expect(try sandbox.swiftStatus(autoCRLF) == sandbox.porcelainStatus(autoCRLF))
        #expect(try sandbox.swiftStatus(autoCRLF).isEmpty)
    }

    /// Attribute lookup agrees with `git check-attr --all`: precedence between
    /// files and between lines, macros and where they may be defined, `!name`,
    /// quoted and folder patterns, and lines git rejects.
    @Test func attributesMatchCheckAttr() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        try sandbox.write("""
            [attr]mine text eol=crlf -diff
            *.txt text
            *.txt -text eol=lf
            "with space.md" mine
            docs/** linguist-documentation
            *.bin binary
            *.both binary text
            *.inv text in/valid
            build/ text
            *.dat !text crlf=input

            """, to: ".gitattributes", in: repository)
        try sandbox.write("*.txt text\n[attr]nested text\n*.md -mine\n", to: "docs/.gitattributes", in: repository)
        try sandbox.write("special.txt -eol\n", to: ".git/info/attributes", in: repository)
        let paths = ["a.txt", "with space.md", "docs/guide.md", "docs/notes.txt", "x.bin", "y.both", "z.inv", "special.txt", "build/out.txt", "q.dat"]
        let output = String(decoding: try sandbox.gitData(["check-attr", "--all", "--"] + paths, in: repository), as: UTF8.self)
        let theirs = Set(output.split(separator: "\n").map(String.init))

        let opened = try GitRepository.opened(repository)
        let attributes = opened.attributes(config: opened.config(), index: try opened.index())
        var ours = Set<String>()
        for path in paths {
            for (name, state) in attributes.states(forFile: path) {
                switch state {
                case .set: ours.insert("\(path): \(name): set")
                case .unset: ours.insert("\(path): \(name): unset")
                case .value(let value): ours.insert("\(path): \(name): \(value)")
                case .unspecified: break
                }
            }
        }
        #expect(ours == theirs)
        #expect(theirs.contains("with space.md: eol: crlf"))
        #expect(theirs.contains("y.both: text: set"))
    }

    /// Moves modification times into the past, so status must read the files.
    static func touch(_ paths: [String], in repository: URL) throws {
        let past = Date().addingTimeInterval(-3600)
        for path in paths {
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: repository.appendingPathComponent(path).path)
        }
    }

    @Test func statusWorksWithIndexVersion4AndPackedHistory() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        for number in 0..<40 {
            try sandbox.write("file \(number)\n", to: "Sources/Module\(number % 4)/File\(number).swift", in: repository)
        }
        try sandbox.commitAll("initial", in: repository)
        try sandbox.git("update-index", "--index-version", "4", in: repository)
        try sandbox.git("gc", "-q", "--aggressive", in: repository)
        try sandbox.git("pack-refs", "--all", in: repository)
        try sandbox.write("changed\n", to: "Sources/Module1/File5.swift", in: repository)
        try sandbox.remove("Sources/Module2/File6.swift", in: repository)
        try sandbox.write("new\n", to: "Sources/Module3/New.swift", in: repository)
        try sandbox.git("add", "Sources/Module3/New.swift", in: repository)

        let opened = try GitRepository.opened(repository)
        #expect(try opened.index().version == 4)
        #expect(try opened.status().porcelainLines == sandbox.porcelainStatus(repository))
        #expect(try opened.status().porcelainLines == [" M Sources/Module1/File5.swift", " D Sources/Module2/File6.swift", "A  Sources/Module3/New.swift"])
    }

    @Test func optionsSkipUntrackedFilesAndAheadBehind() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        try sandbox.write("x\n", to: "tracked.txt", in: repository)
        try sandbox.commitAll("initial", in: repository)
        try sandbox.write("y\n", to: "untracked.txt", in: repository)
        try sandbox.write("z\n", to: "tracked.txt", in: repository)
        let opened = try GitRepository.opened(repository)
        let status = try opened.status(GitStatusOptions(includeUntracked: false, includeAheadBehind: false))
        #expect(status.porcelainLines == [" M tracked.txt"])
        #expect(!status.isClean)
    }

    /// Random edits, staging, commits, ignore files, mode changes, symlinks and
    /// index-format changes, comparing the full status with git after every step.
    @Test(arguments: [UInt64(11), 12, 13, 14])
    func randomOperationsMatchGit(seed: UInt64) throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        var rng = SeededGenerator(seed: seed)
        let directories = ["", "src/", "src/deep/", "docs/", "build/", "with space/", "ünï/"]
        let names = ["a.txt", "b.log", "c.swift", "Makefile", "keep.log", "x", "README.md"]
        let contents = ["one\n", "two\n", "three\n", "", "four\n", "five\n", "a longer line of text\n"]
        let ignoreLines = ["*.log", "!keep.log", "build/", "/x", "src/**/c.swift", "docs/*", "!docs/README.md", "deep", "[ab].txt", "?akefile", "*.swift"]
        var log: [String] = []

        func randomPath() -> String { directories.randomElement(using: &rng)! + names.randomElement(using: &rng)! }
        func existingFiles() -> [String] {
            let enumerator = FileManager.default.enumerator(atPath: repository.path)
            var files: [String] = []
            while let path = enumerator?.nextObject() as? String {
                if path == ".git" { enumerator?.skipDescendants(); continue }
                var isDirectory: ObjCBool = false
                let full = repository.appendingPathComponent(path).path
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: full)) != nil || (FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory) && !isDirectory.boolValue) {
                    files.append(path)
                }
            }
            return files.sorted()
        }

        for step in 0..<90 {
            let roll = Int.random(in: 0..<100, using: &rng)
            let path = randomPath()
            let full = repository.appendingPathComponent(path)
            switch roll {
            case 0..<24:
                try? FileManager.default.removeItem(at: full)
                try sandbox.write(contents.randomElement(using: &rng)!, to: path, in: repository)
                log.append("write \(path)")
            case 24..<32:
                if let victim = existingFiles().randomElement(using: &rng) {
                    try? FileManager.default.removeItem(at: repository.appendingPathComponent(victim))
                    log.append("delete \(victim)")
                }
            case 32..<46:
                let target = Int.random(in: 0..<3, using: &rng) == 0 ? "-A" : path
                _ = try? sandbox.git("add", target, in: repository)
                log.append("add \(target)")
            case 46..<51:
                _ = try? sandbox.git("rm", "-q", "--cached", path, in: repository)
                log.append("rm --cached \(path)")
            case 51..<58:
                let all = Bool.random(using: &rng)
                _ = try? sandbox.git("commit", "-q", all ? "-am" : "-m", "step \(step)", in: repository)
                log.append("commit\(all ? " -a" : "")")
            case 58..<66:
                let directory = ["", "src/", "docs/"].randomElement(using: &rng)!
                let lines = (0..<Int.random(in: 0...4, using: &rng)).map { _ in ignoreLines.randomElement(using: &rng)! }
                try sandbox.write(lines.joined(separator: "\n") + "\n", to: directory + ".gitignore", in: repository)
                log.append("ignore \(directory): \(lines)")
            case 66..<71:
                if let file = existingFiles().randomElement(using: &rng) {
                    let mode: Int = Bool.random(using: &rng) ? 0o755 : 0o644
                    try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: repository.appendingPathComponent(file).path)
                    log.append("chmod \(String(mode, radix: 8)) \(file)")
                }
            case 71..<76:
                try? FileManager.default.removeItem(at: full)
                try FileManager.default.createDirectory(at: full.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(atPath: full.path, withDestinationPath: names.randomElement(using: &rng)!)
                log.append("symlink \(path)")
            case 76..<81:
                if let file = existingFiles().randomElement(using: &rng) {
                    try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Double.random(in: 1...10_000, using: &rng))], ofItemAtPath: repository.appendingPathComponent(file).path)
                    log.append("touch \(file)")
                }
            case 81..<84:
                let version = [2, 3, 4].randomElement(using: &rng)!
                _ = try? sandbox.git("update-index", "--index-version", "\(version)", in: repository)
                log.append("index version \(version)")
            case 84..<87:
                _ = try? sandbox.git("add", "-N", path, in: repository)
                log.append("add -N \(path)")
            case 87..<93:
                // Same size, different content, right after staging.
                if FileManager.default.fileExists(atPath: full.path) {
                    _ = try? sandbox.git("add", path, in: repository)
                    let data = (try? Data(contentsOf: full)) ?? Data()
                    try Data(data.map { $0 == 0x0A ? 0x0A : $0 ^ 0x01 }).write(to: full)
                    log.append("racy edit \(path)")
                }
            case 93..<97:
                _ = try? sandbox.git("reset", "-q", in: repository)
                log.append("reset")
            default:
                let nested = repository.appendingPathComponent("empty/\(step)", isDirectory: true)
                try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
                log.append("mkdir empty/\(step)")
            }
            let ours = try sandbox.swiftStatus(repository)
            let theirs = try sandbox.porcelainStatus(repository)
            #expect(ours == theirs, "seed \(seed) step \(step) after:\n\(log.suffix(6).joined(separator: "\n"))")
            if ours != theirs { return }
        }
    }
}
