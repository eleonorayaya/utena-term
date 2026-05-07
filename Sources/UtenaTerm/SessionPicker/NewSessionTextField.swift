import AppKit

/// Styled text field for the "enter session name" step.
/// Uses palette colors and monospace font, with a subtle border.
final class NewSessionTextField: NSView {

    let textField = NSTextField()
    var onCommit: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)

        textField.bezelStyle = .roundedBezel
        textField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textField.placeholderString = "Session name (e.g., proj-main)"
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)

        NSLayoutConstraint.activate([
            textField.topAnchor.constraint(equalTo: topAnchor),
            textField.leadingAnchor.constraint(equalTo: leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Delegate for return key
        textField.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func getText() -> String {
        textField.stringValue.trimmingCharacters(in: .whitespaces)
    }

    func setText(_ text: String) {
        textField.stringValue = text
    }

    func focus() {
        textField.becomeFirstResponder()
    }

    func shake() {
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        a.duration = 0.3
        a.values = [-8, 8, -6, 6, -4, 4, 0]
        layer?.add(a, forKey: "shake")
    }
}

extension NewSessionTextField: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            onCommit?()
            return true
        }
        return false
    }
}
