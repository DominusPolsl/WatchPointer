import AppKit

/// Asks the person at the Mac whether a Bluetooth device may move their cursor.
enum ConsentPrompt {
    /// Main thread only; returns once the person has answered. "Don't Allow" is the default button,
    /// so pressing Return never approves by accident.
    static func ask(watch: WatchInfo?, id: UUID) -> Bool {
        // The name and OS come from the device itself, so anything nearby can claim to be "Sam's Apple Watch".
        // The device ID below is the one thing it can't choose, which is why it is always shown.
        let name = watch.map { clean($0.name) }.flatMap { $0.isEmpty ? nil : $0 } ?? watch?.modelName ?? "Unknown device"
        var details: [String] = []
        if let watch { details.append("\(watch.modelName), watchOS \(clean(watch.os, limit: 12))") }
        details.append("Device ID …\(id.uuidString.suffix(8))")

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow “\(name)” to control your cursor?"
        alert.informativeText = details.joined(separator: "\n")
            + "\n\nIt will be able to move the pointer, click, drag and scroll on this Mac. "
            + "Allow it only if this is your watch and you just opened WatchPointer on it."
        alert.addButton(withTitle: "Don’t Allow") // first button = default
        alert.addButton(withTitle: "Allow")
        alert.window.level = .floating // this is an accessory app with no windows; make sure the alert is seen
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Text sent by another device, made safe to show: no control or invisible formatting characters
    /// (newlines, right-to-left overrides), and short.
    private static func clean(_ text: String, limit: Int = 40) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: continue
            default: scalars.append(scalar)
            }
            if scalars.count >= limit { break }
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }
}
