import UIKit

/// A row of coding keys above the on-screen keyboard: Tab, arrows, brackets
/// and symbols that need several taps on the iOS keyboard, plus undo/redo and
/// the Command Palette. Modeled on the extended keyboard rows of Termius and
/// Blink; each key goes through the editor's normal typing path, so
/// auto-closing and auto-indent still apply.
final class KeyboardBar: UIInputView {
    enum Key {
        case text(String)
        case tab, left, right, up, down, undo, redo, dismiss, palette, find, comment
    }

    var onKey: ((Key) -> Void)?

    private static let keys: [(String, Key)] = [
        ("⇥", .tab), ("{", .text("{")), ("}", .text("}")), ("(", .text("(")), (")", .text(")")), ("[", .text("[")),
        ("]", .text("]")), ("<", .text("<")), (">", .text(">")), ("=", .text("=")), (";", .text(";")), (":", .text(":")),
        ("\"", .text("\"")), ("'", .text("'")), ("`", .text("`")), ("/", .text("/")), ("\\", .text("\\")), ("|", .text("|")),
        ("&", .text("&")), ("!", .text("!")), ("?", .text("?")), ("-", .text("-")), ("_", .text("_")), ("+", .text("+")),
        ("*", .text("*")), ("#", .text("#")), ("$", .text("$")), ("%", .text("%")), ("@", .text("@")), ("~", .text("~")), ("^", .text("^")),
    ]

    init(tint: UIColor) {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 46), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let fixed = UIStackView()
        fixed.axis = .horizontal
        fixed.spacing = 6
        fixed.translatesAutoresizingMaskIntoConstraints = false
        for (symbol, key, label) in [
            ("arrow.uturn.backward", Key.undo, "Undo"), ("arrow.uturn.forward", Key.redo, "Redo"),
            ("chevron.left", Key.left, "Left"), ("chevron.up", Key.up, "Up"), ("chevron.down", Key.down, "Down"), ("chevron.right", Key.right, "Right"),
        ] {
            fixed.addArrangedSubview(makeButton(image: symbol, key: key, label: label, tint: tint))
        }
        for (title, key) in Self.keys {
            stack.addArrangedSubview(makeButton(title: title, key: key, tint: tint))
        }
        for (symbol, key, label) in [("text.badge.star", Key.comment, "Toggle Comment"), ("magnifyingglass", Key.find, "Find"), ("command", Key.palette, "Command Palette"), ("keyboard.chevron.compact.down", Key.dismiss, "Hide Keyboard")] {
            stack.addArrangedSubview(makeButton(image: symbol, key: key, label: label, tint: tint))
        }

        addSubview(scroll)
        addSubview(fixed)
        NSLayoutConstraint.activate([
            fixed.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            fixed.centerYAnchor.constraint(equalTo: centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: fixed.trailingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 34),
            heightAnchor.constraint(equalToConstant: 46),
        ])
        accessibilityIdentifier = "keyboard-bar"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func makeButton(title: String? = nil, image: String? = nil, key: Key, label: String? = nil, tint: UIColor) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        if let title {
            configuration.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: UIFont.monospacedSystemFont(ofSize: 17, weight: .medium)]))
        }
        if let image {
            configuration.image = UIImage(systemName: image, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        }
        configuration.baseForegroundColor = tint
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            UIDevice.current.playInputClick()
            self?.onKey?(key)
        })
        button.accessibilityLabel = label ?? title
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        return button
    }
}

extension KeyboardBar: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
