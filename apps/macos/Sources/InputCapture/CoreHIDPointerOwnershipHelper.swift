import Foundation
import Darwin
import Dispatch
import InputDomain
import Diagnostics

#if canImport(CoreHID)
import CoreHID

@available(macOS 15.0, *)
enum CoreHIDPointerDeviceDiscovery {
    enum DiscoveryError: Error, Equatable, Sendable {
        case timeout
    }

    static func discoverBuiltInTrackpadMouse(
        timeout: Duration,
        identity: CoreHIDPointerDeviceIdentity? = nil
    ) async throws -> HIDDeviceClient.DeviceReference {
        try await withThrowingTaskGroup(
            of: HIDDeviceClient.DeviceReference.self
        ) { group in
            group.addTask {
                let manager = HIDDeviceManager()
                let criteria = HIDDeviceManager.DeviceMatchingCriteria(
                    primaryUsage: .genericDesktop(.mouse),
                    vendorID: identity?.vendorID,
                    productID: identity?.productID,
                    product: "Apple Internal Keyboard / Trackpad",
                    uniqueID: identity?.uniqueID,
                    locationID: identity?.locationID,
                    isBuiltIn: true
                )

                for try await notification in await manager.monitorNotifications(
                    matchingCriteria: [criteria]
                ) {
                    switch notification {
                    case .deviceMatched(let reference):
                        return reference
                    case .deviceRemoved:
                        continue
                    @unknown default:
                        continue
                    }
                }
                throw DiscoveryError.timeout
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                throw DiscoveryError.timeout
            }

            defer { group.cancelAll() }
            guard let reference = try await group.next() else {
                throw DiscoveryError.timeout
            }
            return reference
        }
    }
}

@available(macOS 15.0, *)
private final class CoreHIDPointerIPCWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(handle: FileHandle) {
        self.handle = handle
    }

    @discardableResult
    func send(_ frame: CoreHIDPointerIPC.Frame) -> Bool {
        let data = CoreHIDPointerIPC.encode(frame)
        return lock.withLock {
            do {
                try handle.write(contentsOf: data)
                return true
            } catch {
                return false
            }
        }
    }

    @discardableResult
    func send(_ event: SemanticPointerEvent) -> Bool {
        send(CoreHIDPointerIPC.frame(for: event))
    }

    @discardableResult
    func fail(_ failure: CoreHIDPointerIPC.Failure) -> Bool {
        send(.init(kind: .failure, a: failure.rawValue))
    }
}

@available(macOS 15.0, *)
private enum CoreHIDPointerOwnershipHelperRuntime {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3,
              arguments[1] == CoreHIDPointerOwnershipHelperMode.flag else {
            return
        }
        guard let generation = UInt64(arguments[2]) else {
            Darwin._exit(64)
        }

        Task.detached(priority: .userInitiated) {
            let status = await run(generation: generation)
            Darwin._exit(status)
        }
        dispatchMain()
    }

    private static func run(generation: UInt64) async -> Int32 {
        let writer = CoreHIDPointerIPCWriter(handle: .standardOutput)
        guard let expectedIdentity =
                CoreHIDPointerDeviceIdentity.fromEnvironment(
                    ProcessInfo.processInfo.environment
                ) else {
            _ = writer.fail(.invalidInvocation)
            return 69
        }

        let reference: HIDDeviceClient.DeviceReference
        do {
            reference = try await CoreHIDPointerDeviceDiscovery
                .discoverBuiltInTrackpadMouse(
                    timeout: .seconds(3),
                    identity: expectedIdentity
                )
        } catch {
            _ = writer.fail(.discoveryTimeout)
            return 70
        }

        guard let client = HIDDeviceClient(deviceReference: reference) else {
            _ = writer.fail(.clientCreation)
            return 71
        }

        let primaryUsage = await client.primaryUsage
        let isBuiltIn = await client.isBuiltIn
        let product = await client.product
        let vendorID = await client.vendorID
        let productID = await client.productID
        let uniqueID = await client.uniqueID
        let locationID = await client.locationID
        guard primaryUsage == .genericDesktop(.mouse),
              isBuiltIn,
              product == "Apple Internal Keyboard / Trackpad",
              expectedIdentity.matches(
                  vendorID: vendorID,
                  productID: productID,
                  uniqueID: uniqueID,
                  locationID: locationID
              ) else {
            _ = writer.fail(.wrongDevice)
            return 72
        }

        let descriptor: Data
        do {
            descriptor = try IOKitHIDReportDescriptorProvider.descriptor(
                matching: expectedIdentity
            )
            let xy = try HIDReportDescriptorSemantics.analyzePointerXY(
                descriptor: descriptor
            )
            guard xy.provesUnambiguousRelativeXY else {
                _ = writer.fail(.descriptorSemantics)
                return 73
            }
            try AppleTrackpadReportDescriptorVerifier.verify(descriptor)
        } catch let error as IOKitHIDReportDescriptorProvider.ProviderError {
            Diagnostics.log(
                "corehid descriptor bridge failed generation=\(generation) "
                    + "reason=\(String(describing: error))"
            )
            _ = writer.fail(.descriptorSemantics)
            return 73
        } catch {
            Diagnostics.log(
                "corehid descriptor validation failed generation=\(generation) "
                    + "errorType=\(String(reflecting: type(of: error)))"
            )
            _ = writer.fail(.descriptorSemantics)
            return 73
        }

        guard let reportID = HIDReportID(rawValue: 2) else {
            _ = writer.fail(.reportID)
            return 74
        }
        let elements = await client.elements

        // Acquisition is two-phase. Validation finishes before the helper is
        // allowed to seize, so a parent cancellation before commit is
        // provably non-seizing. Once the commit byte is accepted, the parent
        // conservatively treats seizure as possible until independent unseize
        // evidence arrives.
        guard writer.send(.init(kind: .prepared)) else {
            return 0
        }

        let activationData: Data
        do {
            activationData =
                try FileHandle.standardInput.read(upToCount: 1) ?? Data()
        } catch {
            return 0
        }
        guard activationData.count == 1 else {
            return 0
        }
        guard activationData.first == CoreHIDPointerIPC.activateCommand else {
            _ = writer.fail(.protocolViolation)
            return 82
        }

        // After commit, stdin becomes the process-lifetime lease. EOF means
        // either intentional release or parent death; both tear down the
        // owning task by terminating this disposable process.
        FileHandle.standardInput.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                Darwin._exit(0)
            }
        }

        do {
            try await client.seizeDevice()
        } catch {
            _ = writer.fail(.unexpectedSeizeState)
            return 75
        }

        let stream = await client.monitorNotifications(
            reportIDsToMonitor: [reportID...reportID],
            elementsToMonitor: elements
        )

        let streamState = CoreHIDPointerStreamState(
            onDeferredEvent: { event in
                if !writer.send(event) {
                    Darwin._exit(0)
                }
            }
        )

        guard writer.send(.init(kind: .ready)) else {
            return 0
        }

        do {
            for try await notification in stream {
                switch notification {
                case .inputReport(_, let data, _):
                    let events: [SemanticPointerEvent]
                    do {
                        events = try streamState.consume(data)
                    } catch {
                        _ = writer.fail(.semanticDecode)
                        return 76
                    }
                    for event in events {
                        guard writer.send(event) else { return 0 }
                    }

                case .deviceRemoved:
                    _ = writer.fail(.deviceRemoved)
                    return 77

                case .deviceSeized, .deviceUnseized:
                    _ = writer.fail(.unexpectedSeizeState)
                    return 78

                case .elementUpdates:
                    break

                @unknown default:
                    _ = writer.fail(.unknownNotification)
                    return 79
                }
            }

            _ = writer.fail(.streamEnded)
            return 80
        } catch {
            _ = writer.fail(.streamError)
            return 81
        }
    }
}
#endif

/// Entry hook called before the SwiftUI application is constructed. In normal
/// Ampersand mode this is a no-op. In helper mode it never returns: the child
/// exists only to own the CoreHID seizure and is disposable by design.
public enum CoreHIDPointerOwnershipHelperMode {
    static let flag = "--crossinput-corehid-pointer-helper"

    public static func runIfRequested() {
        #if canImport(CoreHID)
        if #available(macOS 15.0, *) {
            CoreHIDPointerOwnershipHelperRuntime.runIfRequested()
        }
        #endif
    }
}
