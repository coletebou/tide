import SwiftUI
import TideCore

/// File icons in the spirit of VS Code's Seti theme: a glyph and a color per
/// file type, drawn with SF Symbols or short monospaced badges.
struct FileIcon: View {
    let name: String
    var isDirectory = false
    var isExpanded = false
    var size: CGFloat = 14

    var body: some View {
        let style = Self.style(for: name, isDirectory: isDirectory, isExpanded: isExpanded)
        Group {
            switch style.glyph {
            case .symbol(let symbol):
                Image(systemName: symbol)
                    .font(.system(size: size * 0.85, weight: .semibold))
            case .text(let text):
                Text(text)
                    .font(.system(size: size * (text.count > 2 ? 0.55 : 0.68), weight: .heavy, design: .monospaced))
                    .minimumScaleFactor(0.5)
            }
        }
        .foregroundStyle(style.color)
        .frame(width: size + 2, height: size + 2)
    }

    enum Glyph {
        case symbol(String)
        case text(String)
    }

    struct Style {
        var glyph: Glyph
        var color: Color
    }

    static func style(for name: String, isDirectory: Bool, isExpanded: Bool = false) -> Style {
        if isDirectory {
            return Style(glyph: .symbol(isExpanded ? "folder.fill" : "folder.fill"), color: Color(red: 0.86, green: 0.71, blue: 0.42))
        }
        let lower = name.lowercased()
        let ext = WorkspacePath.fileExtension(of: lower)
        switch lower {
        case "readme.md", "readme": return Style(glyph: .symbol("info.circle.fill"), color: Color(hex: 0x519ABA))
        case "license", "license.md", "license.txt": return Style(glyph: .symbol("checkmark.seal.fill"), color: Color(hex: 0xCBCB41))
        case "package.json", "package-lock.json": return Style(glyph: .text("npm"), color: Color(hex: 0xCC3E44))
        case ".gitignore", ".gitattributes", ".gitmodules": return Style(glyph: .symbol("arrow.triangle.branch"), color: Color(hex: 0x41535B))
        case "dockerfile", ".dockerignore": return Style(glyph: .symbol("shippingbox.fill"), color: Color(hex: 0x519ABA))
        case "makefile": return Style(glyph: .symbol("hammer.fill"), color: Color(hex: 0xE37933))
        case "package.swift": return Style(glyph: .symbol("swift"), color: Color(hex: 0xF05138))
        default: break
        }
        switch ext {
        case "swift": return Style(glyph: .symbol("swift"), color: Color(hex: 0xF05138))
        case "js", "mjs", "cjs": return Style(glyph: .text("JS"), color: Color(hex: 0xCBCB41))
        case "jsx": return Style(glyph: .symbol("atom"), color: Color(hex: 0x519ABA))
        case "ts", "mts", "cts": return Style(glyph: .text("TS"), color: Color(hex: 0x519ABA))
        case "tsx": return Style(glyph: .symbol("atom"), color: Color(hex: 0x519ABA))
        case "json", "jsonc", "json5": return Style(glyph: .text("{}"), color: Color(hex: 0xCBCB41))
        case "md", "markdown", "mdx": return Style(glyph: .text("M↓"), color: Color(hex: 0x519ABA))
        case "py", "pyi": return Style(glyph: .text("py"), color: Color(hex: 0x519ABA))
        case "rb": return Style(glyph: .text("rb"), color: Color(hex: 0xCC3E44))
        case "go": return Style(glyph: .text("go"), color: Color(hex: 0x519ABA))
        case "rs": return Style(glyph: .text("rs"), color: Color(hex: 0xDEA584))
        case "c", "h": return Style(glyph: .text("C"), color: Color(hex: 0x519ABA))
        case "cpp", "cc", "cxx", "hpp", "hh": return Style(glyph: .text("C++"), color: Color(hex: 0xA074C4))
        case "m", "mm": return Style(glyph: .text("m"), color: Color(hex: 0x519ABA))
        case "cs": return Style(glyph: .text("C#"), color: Color(hex: 0x8DC149))
        case "java": return Style(glyph: .symbol("cup.and.saucer.fill"), color: Color(hex: 0xCC3E44))
        case "kt", "kts": return Style(glyph: .text("kt"), color: Color(hex: 0xA074C4))
        case "dart": return Style(glyph: .text("dt"), color: Color(hex: 0x519ABA))
        case "php": return Style(glyph: .text("php"), color: Color(hex: 0xA074C4))
        case "lua": return Style(glyph: .text("lua"), color: Color(hex: 0x519ABA))
        case "html", "htm", "xhtml", "vue", "svelte", "astro": return Style(glyph: .text("<>"), color: Color(hex: 0xE37933))
        case "xml", "plist", "storyboard", "xib", "svg": return Style(glyph: .text("<>"), color: Color(hex: 0xE37933))
        case "css": return Style(glyph: .text("#"), color: Color(hex: 0x519ABA))
        case "scss", "sass", "less": return Style(glyph: .text("#"), color: Color(hex: 0xF55385))
        case "yaml", "yml": return Style(glyph: .text("!"), color: Color(hex: 0xA074C4))
        case "toml", "ini", "cfg", "conf", "env", "properties": return Style(glyph: .symbol("gearshape.fill"), color: Color(hex: 0x6D8086))
        case "sh", "bash", "zsh", "fish", "command": return Style(glyph: .text(">_"), color: Color(hex: 0x4D5A5E).opacity(0.9))
        case "sql": return Style(glyph: .symbol("cylinder.split.1x2.fill"), color: Color(hex: 0xF55385))
        case "diff", "patch": return Style(glyph: .symbol("plusminus"), color: Color(hex: 0x8DC149))
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "ico", "bmp": return Style(glyph: .symbol("photo.fill"), color: Color(hex: 0xA074C4))
        case "pdf": return Style(glyph: .symbol("doc.richtext.fill"), color: Color(hex: 0xCC3E44))
        case "zip", "gz", "tar", "tgz", "xz", "7z": return Style(glyph: .symbol("doc.zipper"), color: Color(hex: 0xCBCB41))
        case "txt", "log", "text": return Style(glyph: .symbol("doc.text"), color: Color(hex: 0x6D8086))
        default: return Style(glyph: .symbol("doc"), color: Color(hex: 0x6D8086))
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
