import SwiftUI
import TideCore
import UIKit

/// The Quick Open / Command Palette overlay.
struct QuickInputView: View {
    @Bindable var model: QuickInputModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            if let title = model.title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.color("quickInput.foreground"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(theme.color("quickInputTitle.background"))
            }
            PaletteTextField(text: $model.text, placeholder: model.placeholder, isSecure: model.pickList?.isSecure ?? false, theme: theme, onUp: { model.moveSelection(by: -1) }, onDown: { model.moveSelection(by: 1) }, onSubmit: { model.acceptSelected() }, onCancel: { model.cancel() })
                .frame(height: 30)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 3).fill(theme.color("input.background")))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(theme.color("focusBorder"), lineWidth: 1))
                .padding(6)
            if let message = model.message {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.color("quickInput.foreground"))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("quick-input-message")
            }
            if !model.items.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                                row(item, isSelected: index == model.selectedIndex)
                                    .onTapGesture {
                                        model.selectedIndex = index
                                        model.acceptSelected()
                                    }
                            }
                        }
                    }
                    .frame(maxHeight: 440)
                    // Rows have one identity, the item's id: a second one by
                    // index left the lazy stack showing stale and missing rows.
                    .onChange(of: model.selectedIndex) { _, index in
                        if model.items.indices.contains(index) { proxy.scrollTo(model.items[index].id) }
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .background(theme.color("quickInput.background"))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.color("widget.border"), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quick-input")
    }

    private func row(_ item: QuickInputItem, isSelected: Bool) -> some View {
        let foreground = theme.color(isSelected ? "quickInputList.focusForeground" : "quickInput.foreground")
        let highlight = isSelected ? foreground : theme.color("list.highlightForeground")
        return VStack(spacing: 0) {
            if let separator = item.separator {
                HStack {
                    Spacer()
                    if !separator.isEmpty {
                        Text(separator).font(.system(size: 11)).foregroundStyle(theme.color("pickerGroup.foreground"))
                    }
                }
                .padding(.trailing, 10)
                .frame(height: separator.isEmpty ? 6 : 18)
                .overlay(alignment: .top) { Rectangle().fill(theme.color("pickerGroup.border")).frame(height: 1).opacity(item.id == model.items.first?.id ? 0 : 1) }
            }
            HStack(spacing: 8) {
                switch item.icon {
                case .file(let path): FileIcon(name: WorkspacePath.name(of: path), size: 14)
                case .symbol(let symbol): Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
                case .none: EmptyView()
                }
                HighlightedText(text: item.label, ranges: item.labelHighlights, color: foreground, highlight: highlight)
                    .lineLimit(1)
                if let description = item.description, !description.isEmpty {
                    HighlightedText(text: description, ranges: item.descriptionHighlights, color: theme.color("descriptionForeground").opacity(isSelected ? 0.9 : 0.8), highlight: highlight, font: .system(size: 12))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let detail = item.detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(theme.color("descriptionForeground"))
                }
                if let keybinding = item.keybinding {
                    Text(keybinding)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(theme.color("keybindingLabel.background")))
                        .foregroundStyle(theme.color("keybindingLabel.foreground"))
                }
                if item.isPicked { Image(systemName: "checkmark").font(.system(size: 11)) }
            }
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(isSelected ? theme.color("quickInputList.focusBackground") : .clear)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("quick-input-item")
        .accessibilityAddTraits(item.isPicked ? .isSelected : [])
    }
}

/// A UIKit text field so arrow keys, Return and Escape reach the palette
/// with priority over the text system (SwiftUI's key handling loses them).
struct PaletteTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isSecure: Bool
    let theme: Theme
    let onUp: () -> Void
    let onDown: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeUIView(context: Context) -> KeyedTextField {
        let field = KeyedTextField()
        field.delegate = context.coordinator
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.returnKeyType = .go
        field.font = .systemFont(ofSize: 14)
        field.accessibilityIdentifier = "quick-input-field"
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        DispatchQueue.main.async { field.becomeFirstResponder() }
        return field
    }

    func updateUIView(_ field: KeyedTextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        // One field serves every input, so secure entry follows the current one.
        if field.isSecureTextEntry != isSecure { field.isSecureTextEntry = isSecure }
        field.textColor = theme.uiColor("input.foreground")
        field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: theme.uiColor("input.placeholderForeground")])
        field.keyboardAppearance = theme.kind.isDark ? .dark : .light
        field.onUp = onUp
        field.onDown = onDown
        field.onCancel = onCancel
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: PaletteTextField

        init(parent: PaletteTextField) { self.parent = parent }

        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}

final class KeyedTextField: UITextField {
    var onUp: (() -> Void)?
    var onDown: (() -> Void)?
    var onCancel: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(up)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(down)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel)),
            UIKeyCommand(input: "n", modifierFlags: .control, action: #selector(down)),
            UIKeyCommand(input: "p", modifierFlags: .control, action: #selector(up)),
        ]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    @objc private func up() { onUp?() }
    @objc private func down() { onDown?() }
    @objc private func cancel() { onCancel?() }
}
