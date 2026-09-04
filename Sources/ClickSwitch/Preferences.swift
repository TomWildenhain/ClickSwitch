import CoreGraphics
import Foundation

enum CycleModifier: String, CaseIterable {
    /// Named `plain` rather than `none` to stay unambiguous next to `Optional.none`.
    case plain
    case command
    case option
    case control
    case shift
    case commandOption
    case commandShift
    case commandControl

    var symbol: String {
        switch self {
        case .plain: return ""
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        case .commandOption: return "⌘⌥"
        case .commandShift: return "⌘⇧"
        case .commandControl: return "⌘⌃"
        }
    }

    /// Fits into "… a Dock icon to cycle its windows".
    var clickDescription: String {
        self == .plain ? "click" : "\(symbol)-click"
    }

    var title: String {
        switch self {
        case .plain: return "No Modifier"
        case .command: return "⌘ Command"
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .shift: return "⇧ Shift"
        case .commandOption: return "⌘⌥ Command + Option"
        case .commandShift: return "⌘⇧ Command + Shift"
        case .commandControl: return "⌘⌃ Command + Control"
        }
    }

    private var flags: CGEventFlags {
        switch self {
        case .plain: return []
        case .command: return [.maskCommand]
        case .option: return [.maskAlternate]
        case .control: return [.maskControl]
        case .shift: return [.maskShift]
        case .commandOption: return [.maskCommand, .maskAlternate]
        case .commandShift: return [.maskCommand, .maskShift]
        case .commandControl: return [.maskCommand, .maskControl]
        }
    }

    /// Exact match, so ⌘⇧-click does not fire when plain ⌘ is configured.
    func matches(_ eventFlags: CGEventFlags) -> Bool {
        let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        return eventFlags.intersection(relevant) == flags
    }
}

final class Preferences {
    static let shared = Preferences()

    private enum Key {
        static let legacyModifier = "cycleModifier"
        static let modifiers = "cycleModifiers"
        static let allowsMultipleModifiers = "allowsMultipleModifiers"
        static let includeMinimized = "includeMinimized"
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [Key.includeMinimized: true])
    }

    /// Never empty: with nothing selected the app would be inert.
    var cycleModifiers: Set<CycleModifier> {
        get {
            if let stored = defaults.array(forKey: Key.modifiers) as? [String] {
                let parsed = Set(stored.compactMap(CycleModifier.init(rawValue:)))
                if !parsed.isEmpty { return parsed }
            }
            if let legacy = defaults.string(forKey: Key.legacyModifier),
                let parsed = CycleModifier(rawValue: legacy)
            {
                return [parsed]
            }
            return [.command]
        }
        set {
            let selection = newValue.isEmpty ? [CycleModifier.command] : newValue
            defaults.set(
                CycleModifier.allCases.filter(selection.contains).map(\.rawValue),
                forKey: Key.modifiers)
        }
    }

    var allowsMultipleModifiers: Bool {
        get { defaults.bool(forKey: Key.allowsMultipleModifiers) }
        set { defaults.set(newValue, forKey: Key.allowsMultipleModifiers) }
    }

    /// Selection in menu order, so callers can talk about "the first one".
    var orderedCycleModifiers: [CycleModifier] {
        let selection = cycleModifiers
        return CycleModifier.allCases.filter(selection.contains)
    }

    /// At most one can match, since every modifier maps to a distinct exact combination.
    func matchedCycleModifier(_ eventFlags: CGEventFlags) -> CycleModifier? {
        orderedCycleModifiers.first { $0.matches(eventFlags) }
    }

    /// Drops back to a single modifier, keeping the first one in menu order.
    func keepOnlyFirstCycleModifier() {
        guard let first = orderedCycleModifiers.first else { return }
        cycleModifiers = [first]
    }

    /// Opens a sentence: "⌘-click", or "Click, ⌥-click or ⇧-click" once several are active.
    var cycleModifierSummary: String {
        let phrases = orderedCycleModifiers.map(\.clickDescription)
        guard let last = phrases.last else { return "" }
        let sentence =
            phrases.count > 1
            ? phrases.dropLast().joined(separator: ", ") + " or " + last
            : last
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    var includeMinimized: Bool {
        get { defaults.bool(forKey: Key.includeMinimized) }
        set { defaults.set(newValue, forKey: Key.includeMinimized) }
    }
}
