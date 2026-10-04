import Foundation
import InputDomain

/// Fixed-width binary protocol between Ampersand and the disposable CoreHID
/// ownership helper. Every frame is exactly 13 bytes so stream parsing is
/// deterministic, allocation-light, and independent of line buffering.
enum CoreHIDPointerIPC {
    static let frameSize = 13
    static let activateCommand: UInt8 = 1

    enum Kind: UInt8, Sendable {
        case ready = 1
        case move = 2
        case button = 3
        case scroll = 4
        case failure = 5
        case prepared = 6
    }

    enum Failure: UInt32, Sendable, Equatable {
        case invalidInvocation = 1
        case discoveryTimeout = 2
        case clientCreation = 3
        case wrongDevice = 4
        case descriptorSemantics = 5
        case reportID = 6
        case semanticDecode = 7
        case deviceRemoved = 8
        case unexpectedSeizeState = 9
        case streamEnded = 10
        case streamError = 11
        case unknownNotification = 12
        case protocolViolation = 13
    }

    struct Frame: Sendable, Equatable {
        let kind: Kind
        let a: UInt32
        let b: UInt32
        let c: UInt32

        init(kind: Kind, a: UInt32 = 0, b: UInt32 = 0, c: UInt32 = 0) {
            self.kind = kind
            self.a = a
            self.b = b
            self.c = c
        }
    }

    enum CodecError: Error, Equatable {
        case unknownKind(UInt8)
    }

    static func encode(_ frame: Frame) -> Data {
        var data = Data()
        data.reserveCapacity(frameSize)
        data.append(frame.kind.rawValue)
        append(frame.a, to: &data)
        append(frame.b, to: &data)
        append(frame.c, to: &data)
        return data
    }

    /// Consumes all complete frames and retains only an incomplete trailing
    /// fragment. Unknown frame kinds fail closed instead of desynchronizing the
    /// remainder of the byte stream.
    static func decodeAvailable(from buffer: inout Data) throws -> [Frame] {
        var frames: [Frame] = []
        var offset = 0

        while buffer.count - offset >= frameSize {
            let kindRaw = byte(in: buffer, at: offset)
            guard let kind = Kind(rawValue: kindRaw) else {
                throw CodecError.unknownKind(kindRaw)
            }
            let a = readUInt32(in: buffer, at: offset + 1)
            let b = readUInt32(in: buffer, at: offset + 5)
            let c = readUInt32(in: buffer, at: offset + 9)
            frames.append(Frame(kind: kind, a: a, b: b, c: c))
            offset += frameSize
        }

        if offset > 0 {
            buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: offset))
        }
        return frames
    }

    static func frame(for event: SemanticPointerEvent) -> Frame {
        switch event.kind {
        case .move(let dx, let dy):
            return Frame(
                kind: .move,
                a: UInt32(bitPattern: dx),
                b: UInt32(bitPattern: dy)
            )
        case .button(let button, let down):
            return Frame(kind: .button, a: button, b: down ? 1 : 0)
        case .scroll(let horizontal, let vertical):
            return Frame(
                kind: .scroll,
                a: horizontal.bitPattern,
                b: vertical.bitPattern
            )
        }
    }

    static func event(from frame: Frame) -> SemanticPointerEvent? {
        switch frame.kind {
        case .move:
            return SemanticPointerEvent(
                .move(
                    dx: Int32(bitPattern: frame.a),
                    dy: Int32(bitPattern: frame.b)
                )
            )
        case .button:
            guard frame.b <= 1 else { return nil }
            return SemanticPointerEvent(
                .button(button: frame.a, down: frame.b == 1)
            )
        case .scroll:
            return SemanticPointerEvent(
                .scroll(
                    horizontal: Float(bitPattern: frame.a),
                    vertical: Float(bitPattern: frame.b)
                )
            )
        case .prepared, .ready, .failure:
            return nil
        }
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func readUInt32(in data: Data, at offset: Int) -> UInt32 {
        (UInt32(byte(in: data, at: offset)) << 24)
            | (UInt32(byte(in: data, at: offset + 1)) << 16)
            | (UInt32(byte(in: data, at: offset + 2)) << 8)
            | UInt32(byte(in: data, at: offset + 3))
    }

    private static func byte(in data: Data, at offset: Int) -> UInt8 {
        data[data.index(data.startIndex, offsetBy: offset)]
    }
}
