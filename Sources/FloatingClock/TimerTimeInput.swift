import AppKit
import ClockCore

private final class TimerNumberFormatter: NumberFormatter, @unchecked Sendable {
    private func allows(_ text: String) -> Bool {
        text.count <= 4 && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    override func isPartialStringValid(_ partialString: String,
                                      newEditingString: AutoreleasingUnsafeMutablePointer<NSString?>?,
                                      errorDescription: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        allows(partialString)
    }

    override func isPartialStringValid(_ partialStringPtr: AutoreleasingUnsafeMutablePointer<NSString>,
                                      proposedSelectedRange: NSRangePointer?, originalString: String,
                                      originalSelectedRange: NSRange,
                                      errorDescription: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        allows(partialStringPtr.pointee as String)
    }
}

final class TimerNumberInput: NSView, NSTextFieldDelegate {
    let field = NSTextField(string: "0")
    let stepper = NSStepper()
    private let unitLabel: NSTextField
    private let maximum: Int
    private var isStepping = false
    var onChange: (() -> Void)?
    var onTextChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?
    var value: Int { Int(field.currentEditor()?.string ?? "") ?? field.integerValue }

    init(unit: String, maximum: Int, minimumDigits: Int = 1, accessibilityLabel: String? = nil) {
        self.maximum = maximum
        unitLabel = NSTextField(labelWithString: unit)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        let formatter = TimerNumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimumIntegerDigits = minimumDigits
        formatter.minimum = 0
        formatter.maximum = NSNumber(value: maximum)
        formatter.isPartialStringValidationEnabled = true
        field.formatter = formatter
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        field.usesSingleLineMode = true
        field.cell?.sendsActionOnEndEditing = false
        field.delegate = self
        field.setAccessibilityLabel(accessibilityLabel ?? unit)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        unitLabel.font = .systemFont(ofSize: 9, weight: .medium)
        unitLabel.setContentHuggingPriority(.required, for: .horizontal)
        unitLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        stepper.minValue = 0
        stepper.maxValue = Double(maximum)
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.autorepeat = true
        stepper.controlSize = .small
        stepper.target = self
        stepper.action = #selector(step)
        stepper.setAccessibilityLabel("调整\(accessibilityLabel ?? unit)")
        for view in [field, unitLabel, stepper] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            heightAnchor.constraint(equalToConstant: 32),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            field.trailingAnchor.constraint(equalTo: unitLabel.leadingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 21),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: ceil("9999".size(withAttributes: [.font: field.font!]).width) + 4),
            unitLabel.firstBaselineAnchor.constraint(equalTo: field.firstBaselineAnchor),
            unitLabel.trailingAnchor.constraint(equalTo: stepper.leadingAnchor, constant: -4),
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

    func apply(palette: ClockPalette) {
        let ink = palette.ink
        layer?.backgroundColor = palette.inputBackground.cgColor
        layer?.borderColor = ink.withAlphaComponent(0.11).cgColor
        field.textColor = ink
        unitLabel.textColor = ink.withAlphaComponent(0.5)
        if let editor = field.currentEditor() as? NSTextView {
            editor.textColor = ink
            editor.insertionPointColor = ink
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        field.integerValue = min(maximum, max(0, value))
        stepper.integerValue = field.integerValue
        if !isStepping { onChange?() }
    }

    func controlTextDidChange(_ obj: Notification) {
        let text = field.currentEditor()?.string ?? field.stringValue
        if let number = Int(text), (0...maximum).contains(number) {
            stepper.integerValue = number
        }
        onTextChange?(text)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        window?.makeFirstResponder(nil)
        onSubmit?()
        return true
    }

    @objc private func step() {
        let selected = stepper.integerValue
        isStepping = true
        defer { isStepping = false }
        guard window?.makeFirstResponder(nil) != false else { return }
        field.integerValue = selected
        stepper.integerValue = selected
        onChange?()
    }
}

final class TimerTimeInput: NSStackView {
    let hours: TimerNumberInput
    let minutes: TimerNumberInput
    let kind: ClockTimerInput
    private(set) var remainingSeconds: TimeInterval = 0
    private var targetDatePrefix = ""
    private var targetSecondsSuffix = ""
    private var updateRevision = 0
    private var originalDuration: (seconds: TimeInterval, hours: Int, minutes: Int)?
    var preservedDuration: TimeInterval? {
        guard let originalDuration, hours.value == originalDuration.hours,
              minutes.value == originalDuration.minutes else { return nil }
        return originalDuration.seconds
    }
    var onChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?

    init(kind: ClockTimerInput) {
        self.kind = kind
        hours = TimerNumberInput(unit: "h", maximum: kind == .duration ? 9_999 : 23, minimumDigits: kind == .duration ? 1 : 2, accessibilityLabel: "小时")
        minutes = TimerNumberInput(unit: "min", maximum: kind == .duration ? 9_999 : 59, minimumDigits: kind == .duration ? 1 : 2, accessibilityLabel: "分钟")
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
        setAccessibilityLabel(kind == .duration ? "计时时长" : "到点时间")
        toolTip = kind == .duration ? "分别输入小时与分钟，或点击上下箭头调节；分钟可输入 90，自动换算为 1 小时 30 分钟。" :
            "24 小时制：小时 00–23，分钟 00–59。小时输入两位后自动跳到分钟；连续输入 1930 即为 19 点 30 分。已过的时刻取次日。"
        hours.field.nextKeyView = minutes.field
        if kind == .targetTime {
            hours.onTextChange = { [weak self] in self?.hourTextChanged($0) }
            minutes.onTextChange = { [weak self] text in
                if let value = Int(text), (0...59).contains(value) { self?.commit() }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(input: String) {
        updateRevision += 1
        guard hours.field.currentEditor() == nil, minutes.field.currentEditor() == nil else { return }
        if kind == .targetTime {
            let parts = input.split(separator: " ")
            let time = (parts.last ?? "").split(separator: ":", omittingEmptySubsequences: false)
            guard (time.count == 2 || time.count == 3), let hour = Int(time[0]), let minute = Int(time[1]),
                  (0...23).contains(hour), (0...59).contains(minute) else { return }
            targetDatePrefix = parts.count == 2 ? String(parts[0]) + " " : ""
            targetSecondsSuffix = time.count == 3 ? ":" + String(time[2]) : ""
            hours.update(value: hour)
            minutes.update(value: minute)
            return
        }
        let unsigned = input.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "+-−"))
        guard let seconds = try? TimerInputParser.duration(unsigned) else { return }
        let whole = Int(seconds)
        remainingSeconds = seconds.truncatingRemainder(dividingBy: 60)
        let displayedHours = min(9_999, whole / 3600)
        let remainingMinutes = (whole - displayedHours * 3600) / 60
        let displayedMinutes = min(9_999, remainingMinutes)
        originalDuration = remainingMinutes > displayedMinutes ? (seconds, displayedHours, displayedMinutes) : nil
        hours.update(value: displayedHours)
        minutes.update(value: displayedMinutes)
    }

    func apply(palette: ClockPalette) {
        hours.apply(palette: palette)
        minutes.apply(palette: palette)
    }

    func commit() {
        let input: String
        if kind == .targetTime {
            guard (0...23).contains(hours.value), (0...59).contains(minutes.value) else { return }
            input = targetDatePrefix + String(format: "%02d:%02d", hours.value, minutes.value) + targetSecondsSuffix
        } else {
            let total = preservedDuration ?? min(TimerInputParser.maximumDuration, Double(hours.value) * 3600 + Double(minutes.value) * 60 + remainingSeconds)
            input = "\(total)秒"
        }
        onChange?(input)
        let revision = updateRevision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.updateRevision == revision else { return }
            self.update(input: input)
        }
    }

    private func hourTextChanged(_ text: String) {
        if text.count == 4, text.allSatisfy({ $0.isASCII && $0.isNumber }),
           let hour = Int(text.prefix(2)), let minute = Int(text.suffix(2)),
           (0...23).contains(hour), (0...59).contains(minute) {
            hours.field.currentEditor()?.string = String(text.prefix(2))
            minutes.update(value: minute)
            commit()
            focusMinutes()
        } else if let hour = Int(text), (0...23).contains(hour) {
            commit()
            if text.count == 2 { focusMinutes() }
        }
    }

    private func focusMinutes() {
        guard window?.makeFirstResponder(minutes.field) == true else { return }
        minutes.field.selectText(nil)
    }
}
