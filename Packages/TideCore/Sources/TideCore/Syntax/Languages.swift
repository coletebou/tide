import Foundation

private func words(_ list: String) -> Set<String> {
    Set(list.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
}

private let cStrings = [StringRule(open: "\"", close: "\""), StringRule(open: "'", close: "'")]
private let slashComments = (line: "//", block: BracketPair("/*", "*/"))

/// The built-in language catalog. Ids follow VS Code's language identifiers.
enum Languages {
    static let all: [LanguageDefinition] = [
        swift, javascript, typescript, python, rust, go, c, cpp, objectiveC, csharp, java, kotlin, dart,
        ruby, php, lua, shell, powershell, sql, json, yaml, toml, ini, markdown, html, xml, css, scss, less,
        dockerfile, makefile, diff, ignore, plaintext,
    ]

    static let swift = LanguageDefinition(
        id: "swift", name: "Swift", extensions: ["swift", "swiftinterface"], fileNames: [],
        lineComment: slashComments.line, blockComment: slashComments.block, nestedBlockComments: true,
        strings: [
            StringRule(open: "\"\"\"", close: "\"\"\"", multiline: true, interpolationOpen: "\\("),
            StringRule(open: "\"", close: "\"", interpolationOpen: "\\("),
        ],
        keywords: words("""
            associatedtype class deinit enum extension fileprivate func init inout internal let open operator private
            precedencegroup protocol public rethrows static struct subscript typealias var actor async convenience
            dynamic final indirect infix lazy mutating nonmutating optional override postfix prefix required some any
            unowned weak nonisolated isolated consuming borrowing consume copy package macro sending throws get set
            willSet didSet is as
            """),
        controlKeywords: words("if else guard switch case default for in while repeat do return break continue fallthrough throw try catch defer where import await discard"),
        constants: words("true false nil self Self super"),
        functionDeclarators: words("func macro"),
        typeDeclarators: words("class struct enum protocol extension actor typealias associatedtype"),
        attributePrefix: "@",
        directivePrefix: "#",
        identifierExtras: ["$"],
        indentAfterSuffixes: []
    )

    static let javascript = LanguageDefinition(
        id: "javascript", name: "JavaScript", extensions: ["js", "mjs", "cjs", "jsx"], shebangs: ["node", "deno", "bun"],
        lineComment: slashComments.line, blockComment: slashComments.block,
        strings: jsStrings,
        keywords: jsKeywords,
        controlKeywords: jsControl,
        constants: words("true false null undefined NaN Infinity this super arguments"),
        types: words("console window document globalThis Math JSON Reflect Intl Atomics"),
        functionDeclarators: words("function"),
        typeDeclarators: words("class"),
        attributePrefix: "@",
        attributeKind: .function,
        identifierExtras: ["$"],
        regexLiterals: true,
        autoClosingPairs: jsPairs
    )

    static let typescript = LanguageDefinition(
        id: "typescript", name: "TypeScript", extensions: ["ts", "mts", "cts", "tsx"], shebangs: ["ts-node", "tsx"],
        lineComment: slashComments.line, blockComment: slashComments.block,
        strings: jsStrings,
        keywords: jsKeywords.union(words("""
            interface type enum namespace module declare abstract implements public private protected readonly keyof
            infer is asserts satisfies override accessor unique
            """)),
        controlKeywords: jsControl,
        constants: words("true false null undefined NaN Infinity this super"),
        types: words("string number boolean any unknown never object symbol bigint console window document globalThis Math JSON"),
        functionDeclarators: words("function"),
        typeDeclarators: words("class interface type enum namespace"),
        attributePrefix: "@",
        attributeKind: .function,
        identifierExtras: ["$"],
        regexLiterals: true,
        autoClosingPairs: jsPairs
    )

    private static let jsStrings = [
        StringRule(open: "`", close: "`", multiline: true, interpolationOpen: "${"),
        StringRule(open: "\"", close: "\""),
        StringRule(open: "'", close: "'"),
    ]
    private static let jsKeywords = words("var let const function class extends static get set new delete typeof instanceof void in of async constructor")
    private static let jsControl = words("if else for while do switch case default break continue return throw try catch finally import export from as await yield with debugger")
    private static let jsPairs = [
        BracketPair("(", ")"), BracketPair("[", "]"), BracketPair("{", "}"),
        BracketPair("\"", "\""), BracketPair("'", "'"), BracketPair("`", "`"),
    ]

    static let python = LanguageDefinition(
        id: "python", name: "Python", extensions: ["py", "pyw", "pyi"], fileNames: ["SConstruct", "SConscript"],
        shebangs: ["python", "python3", "python2", "pypy", "pypy3"],
        lineComment: "#",
        strings: [
            StringRule(open: "\"\"\"", close: "\"\"\"", multiline: true),
            StringRule(open: "'''", close: "'''", multiline: true),
            StringRule(open: "\"", close: "\""),
            StringRule(open: "'", close: "'"),
        ],
        stringPrefixes: ["r", "u", "b", "f", "rb", "br", "fr", "rf", "t"],
        keywords: words("def class lambda global nonlocal and or not is in async del"),
        controlKeywords: words("if elif else for while try except finally with as return yield raise break continue pass import from await assert match case"),
        constants: words("True False None self cls NotImplemented Ellipsis __name__ __file__"),
        types: words("int float str bool list dict tuple set frozenset bytes bytearray object complex type memoryview"),
        builtins: words("""
            print len range open input enumerate zip map filter sorted reversed sum min max abs isinstance issubclass
            hasattr getattr setattr delattr super iter next repr format round any all id hash vars dir help chr ord hex
            oct bin exit divmod pow callable staticmethod classmethod property
            """),
        functionDeclarators: words("def"),
        typeDeclarators: words("class"),
        attributePrefix: "@",
        attributeKind: .function,
        capitalizedTypes: true,
        indentAfterSuffixes: [":"]
    )

    static let rust = LanguageDefinition(
        id: "rust", name: "Rust", extensions: ["rs"],
        lineComment: slashComments.line, blockComment: slashComments.block, nestedBlockComments: true,
        strings: [StringRule(open: "\"", close: "\"", multiline: true), StringRule(open: "'", close: "'")],
        keywords: words("as const crate dyn enum extern fn impl let mod move mut pub ref static struct super trait type unsafe use where async union macro_rules"),
        controlKeywords: words("break continue else for if in loop match return while await yield"),
        constants: words("true false self Self"),
        types: words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str"),
        functionDeclarators: words("fn"),
        typeDeclarators: words("struct enum trait type union"),
        bracketAttributeOpen: "#[",
        lifetimes: true,
        macroBang: true,
        autoClosingPairs: [BracketPair("(", ")"), BracketPair("[", "]"), BracketPair("{", "}"), BracketPair("\"", "\"")]
    )

    static let go = LanguageDefinition(
        id: "go", name: "Go", extensions: ["go"],
        lineComment: slashComments.line, blockComment: slashComments.block,
        strings: [StringRule(open: "`", close: "`", escape: nil, multiline: true), StringRule(open: "\"", close: "\""), StringRule(open: "'", close: "'")],
        keywords: words("chan const func interface map package struct type var"),
        controlKeywords: words("break case continue default defer else fallthrough for go goto if import range return select switch"),
        constants: words("true false nil iota"),
        types: words("bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any comparable"),
        builtins: words("append cap clear close complex copy delete imag len make max min new panic print println real recover"),
        functionDeclarators: words("func"),
        typeDeclarators: words("type"),
        autoClosingPairs: jsPairs
    )

    private static let cKeywords = words("auto const enum extern register signed sizeof static struct typedef union unsigned volatile inline restrict _Alignas _Alignof _Atomic _Generic _Noreturn _Static_assert _Thread_local")
    private static let cControl = words("break case continue default do else for goto if return switch while")
    private static let cTypes = words("void char short int long float double bool _Bool size_t ssize_t ptrdiff_t intptr_t uintptr_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t FILE wchar_t")

    static let c = LanguageDefinition(
        id: "c", name: "C", extensions: ["c"],
        lineComment: slashComments.line, blockComment: slashComments.block,
        strings: cStrings,
        keywords: cKeywords,
        controlKeywords: cControl,
        constants: words("true false NULL"),
        types: cTypes,
        typeDeclarators: words("struct union enum"),
        directivePrefix: "#",
        directivesAtLineStartOnly: true
    )

    static let cpp = LanguageDefinition(
        id: "cpp", name: "C++", extensions: ["cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx", "h", "ipp", "inl"],
        lineComment: slashComments.line, blockComment: slashComments.block,
        strings: cStrings,
        keywords: cKeywords.union(words("""
            class namespace template typename public private protected virtual override final friend operator explicit
            mutable using new delete constexpr consteval constinit noexcept static_cast dynamic_cast reinterpret_cast
            const_cast decltype concept requires thread_local alignas alignof export module import
            """)),
        controlKeywords: cControl.union(words("try catch throw co_await co_return co_yield")),
        constants: words("true false nullptr NULL this"),
        types: cTypes.union(words("auto string vector map set unordered_map unordered_set shared_ptr unique_ptr optional variant std")),
        typeDeclarators: words("class struct union enum namespace concept"),
        directivePrefix: "#",
        directivesAtLineStartOnly: true
    )

    static let objectiveC = LanguageDefinition(
        id: "objective-c", name: "Objective-C", extensions: ["m", "mm"],
        lineComment: slashComments.line, blockComment: slashComments.block,
        strings: [StringRule(open: "@\"", close: "\"")] + cStrings,
        keywords: cKeywords.union(words("self super in out inout bycopy byref oneway nonatomic atomic strong weak copy assign retain readonly readwrite nullable nonnull")),
        controlKeywords: cControl,
        constants: words("YES NO nil Nil NULL true false self super"),
        types: cTypes.union(words("id instancetype BOOL SEL Class IMP NSInteger NSUInteger CGFloat")),
        attributePrefix: "@",
        attributeKind: .keyword,
        directivePrefix: "#",
        directivesAtLineStartOnly: true
    )

    static let csharp = LanguageDefinition(
        id: "csharp", name: "C#", extensions: ["cs", "csx"],
        lineComment: slashComments.line, blockComment: slashComments.block,
        strings: [StringRule(open: "$\"", close: "\"", interpolationOpen: "{"), StringRule(open: "@\"", close: "\"", escape: nil, multiline: true)] + cStrings,
        keywords: words("""
            abstract as base class const delegate enum event explicit extern fixed implicit in interface internal is lock
            namespace new operator out override params private protected public readonly ref sealed sizeof stackalloc
            static struct this typeof unsafe using virtual volatile var async record init get set value partial where
            required file global dynamic
            """),
        controlKeywords: words("break case catch checked continue default do else finally for foreach goto if return switch throw try unchecked while yield await"),
        constants: words("true false null this base"),
        types: words("bool byte char decimal double float int long object sbyte short string uint ulong ushort void nint nuint"),
        typeDeclarators: words("class struct interface enum record"),
        directivePrefix: "#",
        directivesAtLineStartOnly: true
    )

    static let java = LanguageDefinition(
        id: "java", name: "Java", extensions: ["java"],
        lineComment: slashComments.line, blockComment: slashComments.block,
        strings: [StringRule(open: "\"\"\"", close: "\"\"\"", multiline: true)] + cStrings,
        keywords: words("""
            abstract assert class const enum extends final implements instanceof interface native new package private
            protected public static strictfp super synchronized this throws transient volatile var record sealed permits
            """),
        controlKeywords: words("break case catch continue default do else finally for if return switch throw try while yield import"),
        constants: words("true false null this super"),
        types: words("boolean byte char double float int long short void"),
        typeDeclarators: words("class interface enum record"),
        attributePrefix: "@"
    )

    static let kotlin = LanguageDefinition(
        id: "kotlin", name: "Kotlin", extensions: ["kt", "kts"],
        lineComment: slashComments.line, blockComment: slashComments.block, nestedBlockComments: true,
        strings: [
            StringRule(open: "\"\"\"", close: "\"\"\"", escape: nil, multiline: true, interpolationOpen: "${", dollarVariables: true),
            StringRule(open: "\"", close: "\"", interpolationOpen: "${", dollarVariables: true),
            StringRule(open: "'", close: "'"),
        ],
        keywords: words("""
            abstract actual annotation as by class companion const constructor crossinline data enum expect external
            final fun get set in infix init inline inner interface internal is lateinit noinline object open operator
            out override package private protected public reified sealed suspend tailrec typealias val var vararg value
            """),
        controlKeywords: words("if else when for while do return break continue throw try catch finally import"),
        constants: words("true false null this super it"),
        functionDeclarators: words("fun"),
        typeDeclarators: words("class interface object typealias"),
        attributePrefix: "@"
    )

    static let dart = LanguageDefinition(
        id: "dart", name: "Dart", extensions: ["dart"],
        lineComment: slashComments.line, blockComment: slashComments.block, nestedBlockComments: true,
        strings: [
            StringRule(open: "'''", close: "'''", multiline: true, interpolationOpen: "${", dollarVariables: true),
            StringRule(open: "\"\"\"", close: "\"\"\"", multiline: true, interpolationOpen: "${", dollarVariables: true),
            StringRule(open: "\"", close: "\"", interpolationOpen: "${", dollarVariables: true),
            StringRule(open: "'", close: "'", interpolationOpen: "${", dollarVariables: true),
        ],
        keywords: words("""
            abstract as async base class const covariant deferred dynamic enum extends extension external factory final
            get implements interface late library mixin new on operator part required sealed set static super this
            typedef var void with
            """),
        controlKeywords: words("if else for while do switch case default break continue return throw try catch finally rethrow assert import export in is yield await"),
        constants: words("true false null this super"),
        types: words("int double num bool String List Map Set Future Stream Object dynamic void Function"),
        typeDeclarators: words("class mixin enum extension typedef"),
        attributePrefix: "@"
    )

    static let ruby = LanguageDefinition(
        id: "ruby", name: "Ruby", extensions: ["rb", "rake", "gemspec", "ru"], fileNames: ["Gemfile", "Rakefile", "Podfile", "Fastfile", "Brewfile", "Vagrantfile"],
        shebangs: ["ruby"],
        lineComment: "#",
        strings: [StringRule(open: "\"", close: "\"", interpolationOpen: "#{"), StringRule(open: "'", close: "'")],
        keywords: words("alias and begin class def defined? do end module not or undef self super attr_accessor attr_reader attr_writer private protected public lambda proc"),
        controlKeywords: words("break case else elsif ensure for if in next redo rescue retry return then unless until when while yield require require_relative include extend"),
        constants: words("true false nil self __FILE__ __LINE__"),
        functionDeclarators: words("def"),
        typeDeclarators: words("class module"),
        variablePrefixes: ["@", "$"],
        identifiersAsVariables: false,
        indentAfterSuffixes: [" do", "|"]
    )

    static let php = LanguageDefinition(
        id: "php", name: "PHP", extensions: ["php", "phtml"], shebangs: ["php"],
        lineComment: slashComments.line, extraLineComments: ["#"], blockComment: slashComments.block,
        strings: [StringRule(open: "\"", close: "\"", dollarVariables: true), StringRule(open: "'", close: "'")],
        keywords: words("function class public private protected static abstract final interface trait extends implements namespace use new array fn match readonly enum const var echo print"),
        controlKeywords: words("if else elseif while for foreach switch case default break continue return try catch finally throw require require_once include include_once as do yield"),
        constants: words("true false null TRUE FALSE NULL"),
        functionDeclarators: words("function fn"),
        typeDeclarators: words("class interface trait enum"),
        caseInsensitiveKeywords: false,
        variablePrefixes: ["$"]
    )

    static let lua = LanguageDefinition(
        id: "lua", name: "Lua", extensions: ["lua"], shebangs: ["lua", "luajit"],
        lineComment: "--", blockComment: BracketPair("--[[", "]]"),
        strings: [StringRule(open: "[[", close: "]]", escape: nil, multiline: true), StringRule(open: "\"", close: "\""), StringRule(open: "'", close: "'")],
        keywords: words("local function and or not"),
        controlKeywords: words("if then else elseif end for in while do repeat until return break goto"),
        constants: words("true false nil self"),
        builtins: words("print pairs ipairs require tostring tonumber type error assert pcall select setmetatable getmetatable"),
        functionDeclarators: words("function"),
        capitalizedTypes: false
    )

    static let shell = LanguageDefinition(
        id: "shellscript", name: "Shell Script",
        extensions: ["sh", "bash", "zsh", "ksh", "command", "bats"],
        fileNames: [".bashrc", ".bash_profile", ".zshrc", ".zshenv", ".zprofile", ".profile", ".bash_aliases", "PKGBUILD"],
        shebangs: ["sh", "bash", "zsh", "ksh", "dash", "fish"],
        lineComment: "#",
        strings: [
            StringRule(open: "\"", close: "\"", multiline: true, dollarVariables: true),
            StringRule(open: "'", close: "'", escape: nil, multiline: true),
        ],
        keywords: words("function local export declare readonly typeset unset alias source"),
        controlKeywords: words("if then else elif fi for while until do done case esac in select return break continue exit time"),
        builtins: words("""
            echo printf cd pwd ls cat grep sed awk test read eval exec set shift trap wait kill mkdir rm cp mv chmod chown
            touch curl git npm npx yarn pnpm swift xcodebuild brew make docker ssh scp tar find xargs sort uniq head tail
            """),
        functionDeclarators: words("function"),
        variablePrefixes: ["$"],
        capitalizedTypes: false,
        identifiersAsVariables: false
    )

    static let powershell = LanguageDefinition(
        id: "powershell", name: "PowerShell", extensions: ["ps1", "psm1", "psd1"], shebangs: ["pwsh"],
        lineComment: "#", blockComment: BracketPair("<#", "#>"),
        strings: [StringRule(open: "\"", close: "\"", escape: "`", multiline: true, dollarVariables: true), StringRule(open: "'", close: "'", escape: nil, multiline: true)],
        keywords: words("function param filter class enum begin process end"),
        controlKeywords: words("if elseif else switch foreach for while do until break continue return throw try catch finally trap exit"),
        constants: words("$true $false $null"),
        functionDeclarators: words("function filter"),
        caseInsensitiveKeywords: true,
        variablePrefixes: ["$"],
        capitalizedTypes: false,
        identifiersAsVariables: false
    )

    static let sql = LanguageDefinition(
        id: "sql", name: "SQL", extensions: ["sql", "psql", "mysql", "sqlite"],
        lineComment: "--", blockComment: slashComments.block,
        strings: [StringRule(open: "'", close: "'", escape: nil), StringRule(open: "\"", close: "\"", escape: nil)],
        keywords: words("""
            select from where insert into values update set delete create table drop alter add column index view join inner
            left right outer full cross on as and or not null is in exists between like ilike order by group having limit
            offset union all distinct case when then else end primary key foreign references default constraint unique
            check begin commit rollback transaction with returning cascade if replace trigger function procedure
            database schema grant revoke asc desc explain analyze vacuum
            """),
        constants: words("true false null"),
        types: words("int integer bigint smallint tinyint varchar char text boolean bool date time timestamp timestamptz float real double decimal numeric serial bigserial json jsonb uuid blob bytea"),
        caseInsensitiveKeywords: true,
        capitalizedTypes: false,
        identifiersAsVariables: false
    )

    static let json = LanguageDefinition(
        id: "json", name: "JSON",
        extensions: ["json", "jsonc", "json5", "webmanifest", "code-workspace", "har", "geojson"],
        fileNames: [".babelrc", ".eslintrc", ".prettierrc", ".swiftlint.json", "package.json", "tsconfig.json"],
        lineComment: slashComments.line, blockComment: slashComments.block,
        strings: [StringRule(open: "\"", close: "\"")],
        constants: words("true false null"),
        capitalizedTypes: false,
        identifiersAsVariables: false,
        stringKeysAsProperties: true,
        autoClosingPairs: [BracketPair("[", "]"), BracketPair("{", "}"), BracketPair("\"", "\"")]
    )

    static let yaml = LanguageDefinition(
        id: "yaml", name: "YAML", extensions: ["yaml", "yml"], fileNames: [".clang-format", ".swiftlint.yml"], style: .yaml,
        lineComment: "#",
        indentAfterSuffixes: [":"]
    )

    static let toml = LanguageDefinition(id: "toml", name: "TOML", extensions: ["toml"], fileNames: ["Cargo.lock", "Pipfile"], style: .ini, lineComment: "#")

    static let ini = LanguageDefinition(
        id: "ini", name: "Ini", extensions: ["ini", "cfg", "conf", "properties", "env", "editorconfig", "gitconfig", "gitmodules"],
        fileNames: [".env", ".env.local", ".env.example", ".editorconfig", ".gitconfig", ".gitmodules", ".npmrc"],
        style: .ini, lineComment: "#"
    )

    static let markdown = LanguageDefinition(
        id: "markdown", name: "Markdown", extensions: ["md", "markdown", "mdown", "mkd", "mdx"], style: .markdown,
        blockComment: BracketPair("<!--", "-->"),
        autoClosingPairs: [BracketPair("(", ")"), BracketPair("[", "]"), BracketPair("{", "}"), BracketPair("`", "`")]
    )

    static let html = LanguageDefinition(
        id: "html", name: "HTML", extensions: ["html", "htm", "xhtml", "vue", "svelte", "astro"], style: .html,
        blockComment: BracketPair("<!--", "-->"),
        brackets: [BracketPair("(", ")"), BracketPair("[", "]"), BracketPair("{", "}"), BracketPair("<", ">")]
    )

    static let xml = LanguageDefinition(
        id: "xml", name: "XML",
        extensions: ["xml", "plist", "svg", "xsd", "xsl", "xslt", "storyboard", "xib", "entitlements", "csproj", "xcscheme", "rss", "atom"],
        style: .xml,
        blockComment: BracketPair("<!--", "-->"),
        brackets: [BracketPair("(", ")"), BracketPair("[", "]"), BracketPair("{", "}"), BracketPair("<", ">")]
    )

    static let css = LanguageDefinition(id: "css", name: "CSS", extensions: ["css"], style: .css, blockComment: slashComments.block)
    static let scss = LanguageDefinition(id: "scss", name: "SCSS", extensions: ["scss", "sass"], style: .css, lineComment: "//", blockComment: slashComments.block)
    static let less = LanguageDefinition(id: "less", name: "Less", extensions: ["less"], style: .css, lineComment: "//", blockComment: slashComments.block)

    static let dockerfile = LanguageDefinition(
        id: "dockerfile", name: "Dockerfile", extensions: ["dockerfile", "containerfile"], fileNames: ["Dockerfile", "Containerfile"],
        lineComment: "#",
        strings: [StringRule(open: "\"", close: "\"", dollarVariables: true), StringRule(open: "'", close: "'", escape: nil)],
        keywords: words("from run cmd label maintainer expose env add copy entrypoint volume user workdir arg onbuild stopsignal healthcheck shell as"),
        caseInsensitiveKeywords: true,
        variablePrefixes: ["$"],
        capitalizedTypes: false,
        identifiersAsVariables: false
    )

    static let makefile = LanguageDefinition(
        id: "makefile", name: "Makefile", extensions: ["mk", "mak"], fileNames: ["Makefile", "makefile", "GNUmakefile"],
        lineComment: "#",
        strings: [StringRule(open: "\"", close: "\""), StringRule(open: "'", close: "'", escape: nil)],
        keywords: words("ifeq ifneq ifdef ifndef else endif include define endef export override unexport vpath"),
        variablePrefixes: ["$"],
        capitalizedTypes: false,
        identifiersAsVariables: false,
        lineStartLabelKind: .function
    )

    static let diff = LanguageDefinition(id: "diff", name: "Diff", extensions: ["diff", "patch", "rej"], style: .diff)

    static let ignore = LanguageDefinition(
        id: "ignore", name: "Ignore", extensions: ["gitignore", "dockerignore", "npmignore", "prettierignore", "eslintignore"],
        fileNames: [".gitignore", ".dockerignore", ".npmignore", ".gitattributes", "CODEOWNERS"],
        lineComment: "#",
        capitalizedTypes: false,
        identifiersAsVariables: false
    )

    static let plaintext = LanguageDefinition(
        id: "plaintext", name: "Plain Text", extensions: ["txt", "text", "log"], fileNames: ["LICENSE", "README", "AUTHORS", "CHANGELOG"],
        style: .plain
    )
}
