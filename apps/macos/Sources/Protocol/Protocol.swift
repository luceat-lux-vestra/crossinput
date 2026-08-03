import Foundation

/// CXI binary protocol between the macOS app and the Android helper.
/// Full wire definition: protocol/protocol.md (both implementations must stay in sync).
public enum Protocol {
    public static let magic: [UInt8] = [0x43, 0x58, 0x49] // "CXI"
    public static let version: UInt16 = 1
    public static let headerLength: Int = 15 // magic(3) + version(2) + type(2) + requestId(4) + payloadLen(4)
}

public enum MessageType: UInt16, Sendable {
    // Mac -> Android
    case hello = 0x0001
    case listDisplays = 0x0002
    case selectDisplay = 0x0003
    case createHidDevice = 0x0004
    case destroyHidDevice = 0x0005
    case hidReport = 0x0006
    case ping = 0x0007
    case shutdown = 0x0008
    case pointerMoveRel = 0x0009
    case pointerButton = 0x000A
    case pointerScroll = 0x000B
    // Android -> Mac
    case helloAck = 0x8001
    case displayList = 0x8002
    case displayChanged = 0x8003
    case hidCreated = 0x8004
    case hidError = 0x8005
    case pong = 0x8006
    case logEvent = 0x8007
    case fatalError = 0x8008

    public var isRequest: Bool { rawValue < 0x8000 }
}

/// One complete CXI frame (header + payload), all integers little-endian.
public struct CxiFrame: Sendable, Equatable {
    public let type: MessageType
    public let requestId: UInt32
    public let payload: Data

    public init(type: MessageType, requestId: UInt32, payload: Data = Data()) {
        self.type = type
        self.requestId = requestId
        self.payload = payload
    }
}

// MARK: - Little-endian helpers

enum LE {
    static func u16(_ value: UInt16) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 2)
    }
    static func u32(_ value: UInt32) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 4)
    }
    static func i32(_ value: Int32) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 4)
    }
    static func f32(_ value: Float) -> Data {
        u32(value.bitPattern)
    }
    static func u8(_ value: UInt8) -> Data {
        Data([value])
    }
    static func lengthPrefixed(_ data: Data) -> Data {
        u32(UInt32(data.count)) + data
    }
}

/// Incremental frame parser: feed raw stream bytes, receive complete frames.
/// Safe for arbitrary read chunk sizes (partial frames are buffered).
public final class FrameParser: @unchecked Sendable {
    private var buffer = Data()

    public init() {}

    /// Appends stream bytes and returns any complete frames in order.
    public func append(_ chunk: Data) -> [CxiFrame] {
        buffer.append(chunk)
        var frames: [CxiFrame] = []
        var start = 0
        // Parse by absolute offset instead of mutating the buffer: Data's
        // removeFirst() keeps a slice view whose startIndex != 0, so later
        // buffer[0] access traps. The consumed prefix is compacted at the end.
        while buffer.count - start >= Protocol.headerLength {
            guard buffer[start] == Protocol.magic[0],
                  buffer[start + 1] == Protocol.magic[1],
                  buffer[start + 2] == Protocol.magic[2] else {
                // Stream misalignment: helper protocol is strict about framing.
                // Drop one byte so a late-joined stream can re-sync.
                start += 1
                continue
            }
            let version = readU16(buffer, at: start + 3)
            guard version == Protocol.version else {
                start += 1
                continue
            }
            let payloadLength = Int(readU32(buffer, at: start + 11))
            let totalLength = Protocol.headerLength + payloadLength
            guard buffer.count - start >= totalLength else { break }
            let type = MessageType(rawValue: readU16(buffer, at: start + 5)) ?? .fatalError
            let requestId = readU32(buffer, at: start + 7)
            let payload = buffer.subdata(in: (start + Protocol.headerLength)..<(start + totalLength))
            frames.append(CxiFrame(type: type, requestId: requestId, payload: payload))
            start += totalLength
        }
        if start > 0 {
            buffer = Data(buffer.dropFirst(start))
        }
        return frames
    }

    private func readU16(_ data: Data, at offset: Int) -> UInt16 {
        data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
    }
    private func readU32(_ data: Data, at offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }
}

/// Encodes a frame to wire bytes.
public func encode(_ frame: CxiFrame) -> Data {
    var data = Data(Protocol.magic)
    data.append(LE.u16(Protocol.version))
    data.append(LE.u16(frame.type.rawValue))
    data.append(LE.u32(frame.requestId))
    data.append(LE.u32(UInt32(frame.payload.count)))
    data.append(frame.payload)
    return data
}

// MARK: - Payload builders (Mac -> Android)

public enum Messages {
    public static func hello(version: UInt16 = Protocol.version) -> Data {
        LE.u16(version)
    }

    public static func selectDisplay(displayId: UInt32) -> Data {
        LE.u32(displayId)
    }

    public static func createHidDevice(descriptor: Data) -> Data {
        LE.lengthPrefixed(descriptor)
    }

    public static func destroyHidDevice(deviceId: UInt32) -> Data {
        LE.u32(deviceId)
    }

    public static func hidReport(deviceId: UInt32, report: Data) -> Data {
        LE.u32(deviceId) + LE.lengthPrefixed(report)
    }

    public static func pointerMoveRel(dx: Int32, dy: Int32) -> Data {
        LE.i32(dx) + LE.i32(dy)
    }

    /// button: 0=left 1=right 2=middle
    public static func pointerButton(button: UInt32, down: Bool) -> Data {
        LE.u32(button) + LE.u8(down ? 1 : 0)
    }

    /// Positive vertical = up, positive horizontal = left (Android AXIS_* convention).
    public static func pointerScroll(horizontal: Float, vertical: Float) -> Data {
        LE.f32(horizontal) + LE.f32(vertical)
    }
}

// MARK: - Payload decoders (Android -> Mac)

public struct DisplayInfo: Sendable, Equatable {
    public let displayId: UInt32
    public let type: UInt8
    public let flags: UInt32
    public let state: UInt8
    public let width: UInt32
    public let height: UInt32
    public let densityDpi: UInt32
    public let rotation: UInt8
    public let name: String
    public let uniqueId: String
    public let layerStack: UInt32

    public init(displayId: UInt32, type: UInt8, flags: UInt32, state: UInt8,
                width: UInt32, height: UInt32, densityDpi: UInt32, rotation: UInt8,
                name: String, uniqueId: String, layerStack: UInt32) {
        self.displayId = displayId
        self.type = type
        self.flags = flags
        self.state = state
        self.width = width
        self.height = height
        self.densityDpi = densityDpi
        self.rotation = rotation
        self.name = name
        self.uniqueId = uniqueId
        self.layerStack = layerStack
    }

    public var isDesktop: Bool { (flags & 0x40) != 0 } // Display.FLAG_DESKTOP
}

public enum DecodeError: Error, Equatable, Sendable {
    case truncated(String)
    case invalidString
    case invalidDisplay
}

struct Decoder {
    var data: Data
    var offset = 0

    init(_ data: Data) { self.data = data }

    mutating func u8() throws -> UInt8 {
        guard offset + 1 <= data.count else { throw DecodeError.truncated("u8") }
        let v = data[offset]
        offset += 1
        return v
    }
    mutating func u16() throws -> UInt16 {
        guard offset + 2 <= data.count else { throw DecodeError.truncated("u16") }
        let v = data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        offset += 2
        return v
    }
    mutating func u32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw DecodeError.truncated("u32") }
        let v = data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        offset += 4
        return v
    }
    mutating func lengthPrefixedString() throws -> String {
        let length = Int(try u32())
        guard offset + length <= data.count else { throw DecodeError.truncated("string") }
        guard let s = String(data: data.subdata(in: offset..<(offset + length)), encoding: .utf8) else {
            throw DecodeError.invalidString
        }
        offset += length
        return s
    }
}

public extension Messages {
    static func decodeHelloAck(_ payload: Data) throws -> UInt16 {
        var d = Decoder(payload)
        return try d.u16()
    }

    static func decodeDisplay(_ payload: Data) throws -> DisplayInfo {
        var d = Decoder(payload)
        let displayId = try d.u32()
        let type = try d.u8()
        let flags = try d.u32()
        let state = try d.u8()
        let width = try d.u32()
        let height = try d.u32()
        let densityDpi = try d.u32()
        let rotation = try d.u8()
        let name = try d.lengthPrefixedString()
        let uniqueId = try d.lengthPrefixedString()
        let layerStack = try d.u32()
        return DisplayInfo(displayId: displayId, type: type, flags: flags, state: state,
                           width: width, height: height, densityDpi: densityDpi,
                           rotation: rotation, name: name, uniqueId: uniqueId,
                           layerStack: layerStack)
    }

    static func decodeDisplayList(_ payload: Data) throws -> [DisplayInfo] {
        var d = Decoder(payload)
        let count = Int(try d.u32())
        var displays: [DisplayInfo] = []
        displays.reserveCapacity(count)
        let remaining = Data(payload[d.offset...])
        var sub = Decoder(remaining)
        for _ in 0..<count {
            displays.append(try decodeDisplayFromDecoder(&sub))
        }
        return displays
    }

    static func decodeHidCreated(_ payload: Data) throws -> UInt32 {
        var d = Decoder(payload)
        return try d.u32()
    }

    static func decodeHidError(_ payload: Data) throws -> (deviceId: UInt32, code: UInt32, message: String) {
        var d = Decoder(payload)
        let deviceId = try d.u32()
        let code = try d.u32()
        let message = try d.lengthPrefixedString()
        return (deviceId, code, message)
    }

    static func decodeLogEvent(_ payload: Data) throws -> (level: UInt8, tag: String, message: String) {
        var d = Decoder(payload)
        let level = try d.u8()
        let tag = try d.lengthPrefixedString()
        let message = try d.lengthPrefixedString()
        return (level, tag, message)
    }

    static func decodeFatalError(_ payload: Data) throws -> (code: UInt32, message: String) {
        var d = Decoder(payload)
        let code = try d.u32()
        let message = try d.lengthPrefixedString()
        return (code, message)
    }

    private static func decodeDisplayFromDecoder(_ d: inout Decoder) throws -> DisplayInfo {
        let displayId = try d.u32()
        let type = try d.u8()
        let flags = try d.u32()
        let state = try d.u8()
        let width = try d.u32()
        let height = try d.u32()
        let densityDpi = try d.u32()
        let rotation = try d.u8()
        let name = try d.lengthPrefixedString()
        let uniqueId = try d.lengthPrefixedString()
        let layerStack = try d.u32()
        return DisplayInfo(displayId: displayId, type: type, flags: flags, state: state,
                           width: width, height: height, densityDpi: densityDpi,
                           rotation: rotation, name: name, uniqueId: uniqueId,
                           layerStack: layerStack)
    }
}

extension Data {
    static func + (lhs: Data, rhs: Data) -> Data {
        var result = lhs
        result.append(rhs)
        return result
    }
}
