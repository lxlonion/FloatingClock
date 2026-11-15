import AppKit
import ClockCore

/// A number field with a native up/down stepper and a persistent unit label.
final class TimerNumberInput: NSView, NSTextFieldDelegate {
    let field = NSTextField(string: "0")
    let stepper = NSStepper()
    private let unitLabel: NSTextField
    private let maximum: Int
    var onChange: (() -> Void)?
    var onSubmit: (() -> Void)?
    var value: Int { field.integerValue }

    init(unit: String, maximum: Int) {
        self.maximum = maximum
        unitLabel = NSTextField(labelWithString: unit)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = 0
        formatter.maximum = NSNumber(value: maximum)
        field.formatter = formatter
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        field.usesSingleLineMode = true
        field.cell?.sendsActionOnEndEditing = false
        field.delegate = self
        field.setAccessibilityLabel(unit)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        unitLabel.font = .systemFont(ofSize: 9, weight: .medium)
        stepper.minValue = 0
        stepper.maxValue = Double(maximum)
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.autorepeat = true
        stepper.controlSize = .small
        stepper.target = self
        stepper.action = #selector(step)
        stepper.setAccessibilityLabel("调整\(unit)")
        for view in [field, unitLabel, stepper] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
            heightAnchor.constraint(equalToConstant: 42),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            field.trailingAnchor.constraint(equalTo: stepper.leadingAnchor, constant: -2),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            field.heightAnchor.constraint(equalToConstant: 21),
            unitLabel.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 1),
            unitLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stepper.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            stepper.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(value: Int) {
        guard field.currentEditor() == nil else { return }
        field.integerValue = min(maximum, max(0, value))
        stepper.integerValue = field.integerValue
    }

    func apply(ink: NSColor, dark: Bool) {
        layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.055) : NSColor.white.withAlphaComponent(0.7)).cgColor
        layer?.borderColor = ink.withAlphaComponent(0.11).cgColor
        field.textColor = ink
        unitLabel.textColor = ink.withAlphaComponent(0.5)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        field.integerValue = min(maximum, max(0, field.integerValue))
        stepper.integerValue = field.integerValue
        onChange?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        window?.makeFirstResponder(nil)
        onSubmit?()
        return true
    }

    @objc private func step() {
        let selected = stepper.integerValue
        window?.makeFirstResponder(nil)
        field.integerValue = selected
        onChange?()
    }
}

final class TimerDurationInput: NSStackView {
    let hours = TimerNumberInput(unit: "小时", maximum: 16_666)
    let minutes = TimerNumberInput(unit: "分钟", maximum: 999_999)
    private(set) var remainingSeconds: TimeInterval = 0
    var onChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        distribution = .fillEqually
        spacing = 6
        addArrangedSubview(hours)
        addArrangedSubview(minutes)
        for input in [hours, minutes] {
            input.onChange = { [weak self] in self?.commit() }
            input.onSubmit = { [weak self] in self?.onSubmit?() }
        }
        setAccessibilityLabel("计时时长")
        toolTip = "分别输入小时与分钟，或点击上下箭头调节；分钟可输入 90，自动换算为 1 小时 30 分钟。"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(input: String) {
        guard hours.field.currentEditor() == nil, minutes.field.currentEditor() == nil else { return }
        let unsigned = input.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "+-−"))
        guard let seconds = try? TimerInputParser.duration(unsigned) else { return }
        let whole = Int(seconds)
        remainingSeconds = seconds.truncatingRemainder(dividingBy: 60)
        hours.update(value: whole / 3600)
        minutes.update(value: whole / 60 % 60)
    }

    func apply(ink: NSColor, dark: Bool) {
        hours.apply(ink: ink, dark: dark)
        minutes.apply(ink: ink, dark: dark)
    }

    private func commit() {
        let total = min(TimerInputParser.maximumDuration, Double(hours.value) * 3600 + Double(minutes.value) * 60 + remainingSeconds)
        let input = "\(total)秒"
        onChange?(input)
        // End-editing callbacks can arrive before AppKit detaches the field editor.
        DispatchQueue.main.async { [weak self] in self?.update(input: input) }
    }
}
