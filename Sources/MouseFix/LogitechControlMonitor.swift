import Foundation
import IOKit
import IOKit.hid

/// Monitors Logitech controls that firmware does not expose as ordinary
/// mouse-button events. The MX Master SmartShift button is control 0x00C4.
///
/// Only explicitly requested control IDs are diverted. Disconnecting restores
/// their native reporting so MouseFix never leaves device firmware remapped.
final class LogitechControlMonitor {
    static let smartShiftControlID: UInt16 = 0x00C4
    static let gestureControlIDs: Set<UInt16> = [0x00C3]

    private static let logitechVendorID = 0x046D
    private static let reprogControlsV4FeatureID: UInt16 = 0x1B04
    private static let softwareID: UInt8 = 0x08
    private static let reportID: UInt8 = 0x11
    private static let reportLength = 20
    private static let requestTimeout: TimeInterval = 0.75

    private let deviceNameFilter: String
    private let monitoredControlIDs: Set<UInt16>
    private let controlChanged: (UInt16, Bool) -> Void

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var inputReportBuffer: UnsafeMutablePointer<UInt8>?
    private var inputReportBufferLength = 0
    private var featureIndex: UInt8?
    private var activeControlIDs: Set<UInt16> = []
    private var divertedControlIDs: Set<UInt16> = []
    private var originalDiversionByControlID: [UInt16: Bool] = [:]

    private var pendingMatcher: (([UInt8]) -> Bool)?
    private var pendingResponse: [UInt8]?

    private static let inputReportCallback: IOHIDReportCallback = {
        context, _, _, _, _, report, reportLength in
        guard let context else {
            return
        }

        let monitor = Unmanaged<LogitechControlMonitor>
            .fromOpaque(context)
            .takeUnretainedValue()
        monitor.handleInputReport(Array(UnsafeBufferPointer(start: report, count: reportLength)))
    }

    init(
        deviceNameFilter: String,
        monitoredControlIDs: Set<UInt16>,
        controlChanged: @escaping (UInt16, Bool) -> Void
    ) {
        self.deviceNameFilter = deviceNameFilter.lowercased()
        self.monitoredControlIDs = monitoredControlIDs
        self.controlChanged = controlChanged
    }

    @discardableResult
    func connect() -> Bool {
        guard device == nil, !monitoredControlIDs.isEmpty else {
            return device != nil
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(
            manager,
            [kIOHIDVendorIDKey: Self.logitechVendorID] as CFDictionary
        )
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )

        let managerStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard managerStatus == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first(where: isTargetDevice)
        else {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.defaultMode.rawValue
            )
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            print("[logitech-control] MX Master HID++ channel unavailable")
            return false
        }

        let openStatus = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openStatus == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.defaultMode.rawValue
            )
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            print("[logitech-control] Failed to open MX Master HID++ channel: \(openStatus)")
            return false
        }

        self.manager = manager
        self.device = device
        IOHIDDeviceScheduleWithRunLoop(
            device,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        registerInputReports(for: device)

        guard let featureIndex = requestFeatureIndex(Self.reprogControlsV4FeatureID) else {
            print("[logitech-control] REPROG_CONTROLS_V4 is unavailable")
            disconnect()
            return false
        }
        self.featureIndex = featureIndex

        for controlID in monitoredControlIDs.sorted() {
            guard let wasDiverted = isDiverted(controlID: controlID) else {
                print(String(
                    format: "[logitech-control] Failed to read control 0x%04X state",
                    controlID
                ))
                continue
            }
            originalDiversionByControlID[controlID] = wasDiverted

            guard setDiverted(true, controlID: controlID) else {
                print(String(
                    format: "[logitech-control] Failed to divert control 0x%04X",
                    controlID
                ))
                continue
            }

            divertedControlIDs.insert(controlID)
            print(String(
                format: "[logitech-control] Monitoring HID++ control 0x%04X",
                controlID
            ))
        }

        guard !divertedControlIDs.isEmpty else {
            disconnect()
            return false
        }
        return true
    }

    func disconnect() {
        if device != nil, featureIndex != nil {
            for controlID in divertedControlIDs.sorted() {
                let originalState = originalDiversionByControlID[controlID] ?? false
                _ = setDiverted(originalState, controlID: controlID)
            }
        }

        for controlID in activeControlIDs {
            controlChanged(controlID, false)
        }
        activeControlIDs.removeAll()
        divertedControlIDs.removeAll()
        originalDiversionByControlID.removeAll()
        featureIndex = nil
        pendingMatcher = nil
        pendingResponse = nil

        if let device {
            if let inputReportBuffer {
                IOHIDDeviceRegisterInputReportCallback(
                    device,
                    inputReportBuffer,
                    inputReportBufferLength,
                    nil,
                    nil
                )
            }
            IOHIDDeviceUnscheduleFromRunLoop(
                device,
                CFRunLoopGetMain(),
                CFRunLoopMode.defaultMode.rawValue
            )
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.defaultMode.rawValue
            )
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        inputReportBuffer?.deallocate()
        inputReportBuffer = nil
        inputReportBufferLength = 0
        device = nil
        manager = nil
    }

    deinit {
        disconnect()
    }

    static func parseActiveControls(from report: [UInt8]) -> Set<UInt16> {
        guard report.count >= 6 else {
            return []
        }

        let payload = report.dropFirst(4)
        var controls: Set<UInt16> = []
        var index = payload.startIndex

        while index < payload.endIndex {
            let nextIndex = payload.index(after: index)
            guard nextIndex < payload.endIndex else {
                break
            }

            let controlID = UInt16(payload[index]) << 8 | UInt16(payload[nextIndex])
            guard controlID != 0 else {
                break
            }

            controls.insert(controlID)
            index = payload.index(nextIndex, offsetBy: 1)
        }
        return controls
    }

    private func isTargetDevice(_ candidate: IOHIDDevice) -> Bool {
        let product = property(kIOHIDProductKey, from: candidate) as String? ?? ""
        let transport = property(kIOHIDTransportKey, from: candidate) as String? ?? ""
        let maxOutputReportSize = property(kIOHIDMaxOutputReportSizeKey, from: candidate) as Int? ?? 0

        return product.lowercased().contains(deviceNameFilter)
            && transport == "Bluetooth Low Energy"
            && maxOutputReportSize >= Self.reportLength
    }

    private func property<T>(_ key: String, from device: IOHIDDevice) -> T? {
        IOHIDDeviceGetProperty(device, key as CFString) as? T
    }

    private func registerInputReports(for device: IOHIDDevice) {
        let maxInputReportSize = property(kIOHIDMaxInputReportSizeKey, from: device) as Int?
            ?? Self.reportLength
        inputReportBufferLength = max(maxInputReportSize, Self.reportLength)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputReportBufferLength)
        inputReportBuffer = buffer

        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer,
            inputReportBufferLength,
            Self.inputReportCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func requestFeatureIndex(_ featureID: UInt16) -> UInt8? {
        request(
            featureIndex: 0,
            function: 0,
            parameters: [UInt8(featureID >> 8), UInt8(featureID & 0xFF)]
        )?.first.flatMap { $0 == 0 ? nil : $0 }
    }

    private func setDiverted(_ enabled: Bool, controlID: UInt16) -> Bool {
        guard let featureIndex else {
            return false
        }

        let flags: UInt8 = enabled ? 0x01 : 0x00
        let changeBits: UInt8 = enabled ? 0x03 : 0x02
        guard request(
            featureIndex: featureIndex,
            function: 3,
            parameters: [
                UInt8(controlID >> 8),
                UInt8(controlID & 0xFF),
                changeBits | flags,
                0,
                0,
            ]
        ) != nil else {
            return false
        }
        return isDiverted(controlID: controlID) == enabled
    }

    private func isDiverted(controlID: UInt16) -> Bool? {
        guard let featureIndex,
              let response = request(
                  featureIndex: featureIndex,
                  function: 2,
                  parameters: [
                      UInt8(controlID >> 8),
                      UInt8(controlID & 0xFF),
                  ]
              ),
              response.count >= 3
        else {
            return nil
        }

        return response[2] & 0x01 != 0
    }

    private func request(
        featureIndex: UInt8,
        function: UInt8,
        parameters: [UInt8]
    ) -> [UInt8]? {
        guard let device else {
            return nil
        }

        let address = (function << 4) | Self.softwareID
        var report = [UInt8](repeating: 0, count: Self.reportLength)
        report[0] = Self.reportID
        report[1] = 0xFF
        report[2] = featureIndex
        report[3] = address
        for (index, parameter) in parameters.enumerated() where index + 4 < report.count {
            report[index + 4] = parameter
        }

        pendingResponse = nil
        pendingMatcher = { response in
            guard response.count >= 7,
                  [UInt8(0x10), UInt8(0x11)].contains(response[0]),
                  [UInt8(0x00), UInt8(0xFF)].contains(response[1])
            else {
                return false
            }

            if response[2] == 0xFF {
                return response[3] == featureIndex && response[4] == address
            }
            return response[2] == featureIndex && response[3] == address
        }

        let result = report.withUnsafeBytes { rawBuffer -> IOReturn in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return kIOReturnBadArgument
            }
            return IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(Self.reportID),
                baseAddress,
                report.count
            )
        }
        guard result == kIOReturnSuccess else {
            pendingMatcher = nil
            print("[logitech-control] HID++ request failed: \(result)")
            return nil
        }

        let deadline = Date().addingTimeInterval(Self.requestTimeout)
        while pendingResponse == nil, Date() < deadline {
            _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
        }

        defer {
            pendingMatcher = nil
            pendingResponse = nil
        }
        guard let response = pendingResponse, response.count >= 4 else {
            return nil
        }

        if response[2] == 0xFF {
            let errorCode = response.count > 5 ? response[5] : 0xFF
            print(String(format: "[logitech-control] HID++ error 0x%02X", errorCode))
            return nil
        }
        return Array(response.dropFirst(4))
    }

    private func handleInputReport(_ report: [UInt8]) {
        if let matcher = pendingMatcher, matcher(report) {
            pendingResponse = report
            return
        }

        guard let featureIndex,
              report.count >= 4,
              [UInt8(0x10), UInt8(0x11)].contains(report[0]),
              [UInt8(0x00), UInt8(0xFF)].contains(report[1]),
              report[2] == featureIndex,
              report[3] >> 4 == 0
        else {
            return
        }

        let nextActive = Self.parseActiveControls(from: report)
            .intersection(divertedControlIDs)
        let changed = nextActive.symmetricDifference(activeControlIDs)
        activeControlIDs = nextActive

        for controlID in changed.sorted() {
            controlChanged(controlID, nextActive.contains(controlID))
        }
    }
}
