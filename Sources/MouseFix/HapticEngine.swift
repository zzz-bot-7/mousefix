import Foundation

/// Reserved interface for future MX Master haptic support.
///
/// Haptic output stays disabled until the device's feature index is discovered
/// from a verified runtime response. Sending reports to a guessed feature
/// index can invoke an unrelated firmware command on other device revisions.
final class HapticEngine {
    private var deviceNameFilter: String = "mx master"

    init() {}

    func setDeviceFilter(_ name: String) {
        self.deviceNameFilter = name.lowercased()
    }

    func connect() {
        print(
            "[haptic] Disabled for \(deviceNameFilter): " +
            "verified runtime feature discovery is not implemented"
        )
    }

    func fireHaptic() {}

    func disconnect() {}
}
