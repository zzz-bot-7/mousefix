import CoreGraphics
import Foundation
import IOKit.hidsystem
import MouseFixHIDBridge

enum InputDeviceKind: Equatable {
    case targetMouse
    case appleTrackpad
    case other
}

struct InputDeviceDescriptor: Equatable {
    let registryID: UInt64
    let product: String
    let vendorID: Int
    let productID: Int
    let transport: String

    func kind(targetVendorID: Int, targetProductName: String) -> InputDeviceKind {
        let normalizedProduct = product.lowercased()
        let normalizedTarget = targetProductName.lowercased()

        if vendorID == targetVendorID,
           normalizedTarget.isEmpty || normalizedProduct.contains(normalizedTarget) {
            return .targetMouse
        }

        if vendorID == 0x05AC, normalizedProduct.contains("trackpad") {
            return .appleTrackpad
        }

        return .other
    }
}

/// Resolves a Quartz event back to the physical HID service that produced it.
///
/// Quartz scroll events do not expose the device directly. The event still
/// carries an IOKit sender ID, which can be matched to the HID service catalog.
final class InputDeviceResolver {
    private static let logitechVendorID = 0x046D

    private let client: IOHIDEventSystemClient
    private let targetVendorID: Int
    private let targetProductName: String
    private var devicesByRegistryID: [UInt64: InputDeviceDescriptor] = [:]
    private var lastRefresh = Date.distantPast

    init(
        targetProductName: String,
        targetVendorID: Int = InputDeviceResolver.logitechVendorID
    ) {
        self.targetProductName = targetProductName
        self.targetVendorID = targetVendorID
        client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        refreshDevices()
    }

    func descriptor(for event: CGEvent) -> InputDeviceDescriptor? {
        let senderID = MouseFixCopyEventSenderID(event)
        guard senderID != 0 else {
            return nil
        }

        if let descriptor = devicesByRegistryID[senderID] {
            return descriptor
        }

        if Date().timeIntervalSince(lastRefresh) >= 1 {
            refreshDevices()
        }
        return devicesByRegistryID[senderID]
    }

    func kind(for event: CGEvent) -> InputDeviceKind {
        descriptor(for: event)?.kind(
            targetVendorID: targetVendorID,
            targetProductName: targetProductName
        ) ?? .other
    }

    private func refreshDevices() {
        lastRefresh = Date()

        guard let rawServices = IOHIDEventSystemClientCopyServices(client) else {
            devicesByRegistryID = [:]
            return
        }

        var refreshed: [UInt64: InputDeviceDescriptor] = [:]
        for case let service as IOHIDServiceClient in rawServices as NSArray {
            guard let registryNumber = IOHIDServiceClientGetRegistryID(service) as? NSNumber else {
                continue
            }

            let registryID = registryNumber.uint64Value
            refreshed[registryID] = InputDeviceDescriptor(
                registryID: registryID,
                product: stringProperty("Product", from: service),
                vendorID: intProperty("VendorID", from: service),
                productID: intProperty("ProductID", from: service),
                transport: stringProperty("Transport", from: service)
            )
        }

        devicesByRegistryID = refreshed
    }

    private func stringProperty(_ key: String, from service: IOHIDServiceClient) -> String {
        IOHIDServiceClientCopyProperty(service, key as CFString) as? String ?? "unknown"
    }

    private func intProperty(_ key: String, from service: IOHIDServiceClient) -> Int {
        (IOHIDServiceClientCopyProperty(service, key as CFString) as? NSNumber)?.intValue ?? 0
    }
}
