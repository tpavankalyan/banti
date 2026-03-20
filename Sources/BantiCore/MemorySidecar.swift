// Sources/BantiCore/MemorySidecar.swift
import Foundation
import Network
import os

// MARK: - Minimal msgpack encoder/decoder
// Supports the subset of msgpack used by banti:
//   nil, Bool, Int (0–127, neg int8, uint16), String (≤255 bytes),
//   [String], [String: Any] (string keys, values of above types)

enum MsgPack {

    // MARK: Encode

    static func encode(_ value: Any?) -> Data? {
        var out = Data()
        guard appendValue(value, to: &out) else { return nil }
        return out
    }

    private static func appendValue(_ value: Any?, to out: inout Data) -> Bool {
        switch value {
        case nil:
            out.append(0xC0)
        case let b as Bool:
            out.append(b ? 0xC3 : 0xC2)
        case let n as Int:
            if n >= 0 && n <= 127 {
                out.append(UInt8(n))
            } else if n >= -128 && n < 0 {
                out.append(0xD0)
                out.append(UInt8(bitPattern: Int8(n)))
            } else if n >= 0 && n <= 65535 {
                out.append(0xCD)
                out.append(UInt8((n >> 8) & 0xFF))
                out.append(UInt8(n & 0xFF))
            } else {
                // int32
                out.append(0xD2)
                let v = Int32(truncatingIfNeeded: n)
                out.append(UInt8((v >> 24) & 0xFF))
                out.append(UInt8((v >> 16) & 0xFF))
                out.append(UInt8((v >> 8) & 0xFF))
                out.append(UInt8(v & 0xFF))
            }
        case let s as String:
            guard let bytes = s.data(using: .utf8) else { return false }
            let len = bytes.count
            if len <= 31 {
                out.append(0xA0 | UInt8(len))
            } else if len <= 255 {
                out.append(0xD9)
                out.append(UInt8(len))
            } else if len <= 65535 {
                out.append(0xDA)
                out.append(UInt8((len >> 8) & 0xFF))
                out.append(UInt8(len & 0xFF))
            } else {
                return false // string too long
            }
            out.append(contentsOf: bytes)
        case let arr as [Any]:
            let n = arr.count
            if n <= 15 {
                out.append(0x90 | UInt8(n))
            } else if n <= 65535 {
                out.append(0xDC)
                out.append(UInt8((n >> 8) & 0xFF))
                out.append(UInt8(n & 0xFF))
            } else {
                return false
            }
            for item in arr {
                guard appendValue(item, to: &out) else { return false }
            }
        case let arr as [String]:
            let n = arr.count
            if n <= 15 {
                out.append(0x90 | UInt8(n))
            } else if n <= 65535 {
                out.append(0xDC)
                out.append(UInt8((n >> 8) & 0xFF))
                out.append(UInt8(n & 0xFF))
            } else {
                return false
            }
            for item in arr {
                guard appendValue(item, to: &out) else { return false }
            }
        case let dict as [String: Any]:
            let n = dict.count
            if n <= 15 {
                out.append(0x80 | UInt8(n))
            } else if n <= 65535 {
                out.append(0xDE)
                out.append(UInt8((n >> 8) & 0xFF))
                out.append(UInt8(n & 0xFF))
            } else {
                return false
            }
            for (key, val) in dict {
                guard appendValue(key, to: &out) else { return false }
                guard appendValue(val, to: &out) else { return false }
            }
        default:
            // Fallback: try converting to string
            out.append(0xA4) // fixstr len=4 "null"
            out.append(contentsOf: "null".utf8)
        }
        return true
    }

    // MARK: Decode

    static func decode(_ data: Data) -> [String: Any]? {
        var offset = 0
        guard let value = readValue(data, offset: &offset) else { return nil }
        return value as? [String: Any]
    }

    private static func readValue(_ data: Data, offset: inout Int) -> Any? {
        guard offset < data.count else { return nil }
        let byte = data[offset]
        offset += 1

        // Positive fixint
        if byte & 0xE0 == 0 || byte <= 0x7F {
            return Int(byte)
        }
        // Negative fixint
        if byte & 0xE0 == 0xE0 {
            return Int(Int8(bitPattern: byte))
        }
        // fixstr
        if byte & 0xE0 == 0xA0 {
            let len = Int(byte & 0x1F)
            return readString(data, offset: &offset, length: len)
        }
        // fixarray
        if byte & 0xF0 == 0x90 {
            let n = Int(byte & 0x0F)
            return readArray(data, offset: &offset, count: n)
        }
        // fixmap
        if byte & 0xF0 == 0x80 {
            let n = Int(byte & 0x0F)
            return readMap(data, offset: &offset, count: n)
        }

        switch byte {
        case 0xC0: return Optional<Any>.none as Any
        case 0xC2: return false
        case 0xC3: return true
        case 0xCA: // float32 — 4 bytes IEEE 754 big-endian
            guard offset + 4 <= data.count else { return nil }
            var bits: UInt32 = 0
            withUnsafeMutableBytes(of: &bits) { ptr in
                data.copyBytes(to: ptr, from: offset..<(offset + 4))
            }
            offset += 4
            return Double(Float(bitPattern: bits.bigEndian))
        case 0xCB: // float64 — 8 bytes IEEE 754 big-endian
            guard offset + 8 <= data.count else { return nil }
            var bits: UInt64 = 0
            withUnsafeMutableBytes(of: &bits) { ptr in
                data.copyBytes(to: ptr, from: offset..<(offset + 8))
            }
            offset += 8
            return Double(bitPattern: bits.bigEndian)
        case 0xD0: // int8
            guard offset < data.count else { return nil }
            let v = Int(Int8(bitPattern: data[offset])); offset += 1; return v
        case 0xCC: // uint8
            guard offset < data.count else { return nil }
            let v = Int(data[offset]); offset += 1; return v
        case 0xCD: // uint16
            guard offset + 1 < data.count else { return nil }
            let v = Int(data[offset]) << 8 | Int(data[offset + 1])
            offset += 2; return v
        case 0xD1: // int16
            guard offset + 1 < data.count else { return nil }
            let v = Int(Int16(bitPattern: UInt16(data[offset]) << 8 | UInt16(data[offset + 1])))
            offset += 2; return v
        case 0xD2: // int32
            guard offset + 3 < data.count else { return nil }
            let v = Int32(bitPattern: UInt32(data[offset]) << 24 | UInt32(data[offset+1]) << 16
                | UInt32(data[offset+2]) << 8 | UInt32(data[offset+3]))
            offset += 4; return Int(v)
        case 0xCE: // uint32
            guard offset + 3 < data.count else { return nil }
            let v = UInt32(data[offset]) << 24 | UInt32(data[offset+1]) << 16
                | UInt32(data[offset+2]) << 8 | UInt32(data[offset+3])
            offset += 4; return Int(v)
        case 0xD9: // str8
            guard offset < data.count else { return nil }
            let len = Int(data[offset]); offset += 1
            return readString(data, offset: &offset, length: len)
        case 0xDA: // str16
            guard offset + 1 < data.count else { return nil }
            let len = Int(data[offset]) << 8 | Int(data[offset+1]); offset += 2
            return readString(data, offset: &offset, length: len)
        case 0xDB: // str32
            guard offset + 3 < data.count else { return nil }
            let len = Int(UInt32(data[offset]) << 24 | UInt32(data[offset+1]) << 16
                | UInt32(data[offset+2]) << 8 | UInt32(data[offset+3]))
            offset += 4
            return readString(data, offset: &offset, length: len)
        case 0xDC: // array16
            guard offset + 1 < data.count else { return nil }
            let n = Int(data[offset]) << 8 | Int(data[offset+1]); offset += 2
            return readArray(data, offset: &offset, count: n)
        case 0xDD: // array32
            guard offset + 3 < data.count else { return nil }
            let n = Int(UInt32(data[offset]) << 24 | UInt32(data[offset+1]) << 16
                | UInt32(data[offset+2]) << 8 | UInt32(data[offset+3]))
            offset += 4
            return readArray(data, offset: &offset, count: n)
        case 0xDE: // map16
            guard offset + 1 < data.count else { return nil }
            let n = Int(data[offset]) << 8 | Int(data[offset+1]); offset += 2
            return readMap(data, offset: &offset, count: n)
        case 0xDF: // map32
            guard offset + 3 < data.count else { return nil }
            let n = Int(UInt32(data[offset]) << 24 | UInt32(data[offset+1]) << 16
                | UInt32(data[offset+2]) << 8 | UInt32(data[offset+3]))
            offset += 4
            return readMap(data, offset: &offset, count: n)
        default:
            return nil
        }
    }

    private static func readString(_ data: Data, offset: inout Int, length: Int) -> String? {
        guard offset + length <= data.count else { return nil }
        let s = String(bytes: data[offset..<(offset + length)], encoding: .utf8)
        offset += length
        return s
    }

    private static func readArray(_ data: Data, offset: inout Int, count: Int) -> [Any]? {
        var result: [Any] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            guard let v = readValue(data, offset: &offset) else { return nil }
            result.append(v)
        }
        return result
    }

    private static func readMap(_ data: Data, offset: inout Int, count: Int) -> [String: Any]? {
        var result: [String: Any] = [:]
        for _ in 0..<count {
            guard let k = readValue(data, offset: &offset) as? String else { return nil }
            guard let v = readValue(data, offset: &offset) else { return nil }
            result[k] = v
        }
        return result
    }
}

// MARK: - PersonIdentity

public struct PersonIdentity {
    public let matched: Bool
    public let personID: String
    public let name: String?
    public let confidence: Float

    public static let unknown = PersonIdentity(matched: false, personID: "unknown", name: nil, confidence: 0)
}

// MARK: - MemorySidecar

public actor MemorySidecar {
    public nonisolated let socketPath: String
    private let logger: Logger
    private var process: Process?
    private var _isRunning: Bool = false

    public var isRunning: Bool { _isRunning }

    /// Primary init — connects to the given Unix socket path.
    public init(socketPath: String = "/tmp/banti_memory.sock", logger: Logger) {
        self.socketPath = socketPath
        self.logger = logger
    }

    /// Legacy init used by MemoryEngine. `port` is ignored; the fixed socket path is used.
    /// The port parameter has no default value to avoid ambiguity with `init(socketPath:logger:)`.
    public init(logger: Logger, port: Int) {
        self.socketPath = "/tmp/banti_memory.sock"
        self.logger = logger
        _ = port // unused — socket replaces HTTP
    }

    // MARK: - Lifecycle

    public func start() async {
        guard !_isRunning else { return }

        let sidecarDir = resolveSidecarDir()
        let pythonPath = sidecarDir.appendingPathComponent(".venv/bin/python3").path
        let mainPath = sidecarDir.appendingPathComponent("main.py").path

        guard FileManager.default.fileExists(atPath: mainPath) else {
            logger.log(source: "memory", message: "[warn] sidecar not found at \(mainPath) — memory disabled")
            return
        }

        let python = FileManager.default.fileExists(atPath: pythonPath) ? pythonPath : "/usr/bin/python3"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [mainPath]
        proc.currentDirectoryURL = sidecarDir
        proc.environment = ProcessInfo.processInfo.environment

        do {
            try proc.run()
            process = proc
            logger.log(source: "memory", message: "sidecar launched (pid \(proc.processIdentifier))")
        } catch {
            logger.log(source: "memory", message: "[warn] sidecar launch failed: \(error.localizedDescription)")
            return
        }

        await waitForHealth()
    }

    public func stop() {
        process?.terminate()
        process = nil
        _isRunning = false
    }

    // MARK: - Core transport

    /// Send a msgpack request dict and receive a msgpack response dict.
    /// Creates a new NWConnection per call (simple, avoids state management).
    func send(method: String, payload: [String: Any] = [:]) async -> [String: Any] {
        var msg = payload
        msg["method"] = method

        guard let body = MsgPack.encode(msg) else {
            logger.log(source: "memory", message: "[warn] msgpack encode failed for method \(method)")
            return ["error": "encode failed"]
        }

        var frame = Data()
        let len = UInt32(body.count).bigEndian
        withUnsafeBytes(of: len) { frame.append(contentsOf: $0) }
        frame.append(body)

        return await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.unix(path: socketPath)
            let connection = NWConnection(to: endpoint, using: NWParameters())
            var resumed = false

            func finish(_ result: [String: Any]) {
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { [frame] state in
                switch state {
                case .ready:
                    connection.send(content: frame, completion: .contentProcessed { error in
                        if let error = error {
                            finish(["error": error.localizedDescription])
                            return
                        }
                        // Receive 4-byte length prefix
                        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, error in
                            if let error = error {
                                finish(["error": error.localizedDescription])
                                return
                            }
                            guard let lenData = data, lenData.count == 4 else {
                                finish(["error": "bad length frame"])
                                return
                            }
                            let bodyLen = Int(UInt32(bigEndian: lenData.withUnsafeBytes { $0.load(as: UInt32.self) }))
                            guard bodyLen > 0 else {
                                finish(["error": "zero-length response"])
                                return
                            }
                            // Receive body
                            connection.receive(minimumIncompleteLength: bodyLen, maximumLength: bodyLen) { body, _, _, error in
                                if let error = error {
                                    finish(["error": error.localizedDescription])
                                    return
                                }
                                guard let body = body, body.count == bodyLen else {
                                    finish(["error": "incomplete body"])
                                    return
                                }
                                let result = MsgPack.decode(body) ?? ["error": "decode failed"]
                                finish(result)
                            }
                        }
                    })
                case .failed(let error):
                    finish(["error": error.localizedDescription])
                case .waiting(let error):
                    finish(["error": "connection waiting: \(error.localizedDescription)"])
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .utility))
        }
    }

    // MARK: - Typed public API

    /// Check sidecar health; updates `isRunning`.
    public func health() async -> Bool {
        let resp = await send(method: "health")
        let ok = (resp["status"] as? String) == "ok"
        _isRunning = ok
        return ok
    }

    /// Identify a face from JPEG data.
    public func identifyFace(_ jpegData: Data) async -> PersonIdentity {
        let jpeg64 = jpegData.base64EncodedString()
        let resp = await send(method: "identify_face", payload: ["jpeg_b64": jpeg64])
        guard (resp["error"] as? String) == nil,
              let personID = resp["person_id"] as? String else {
            return .unknown
        }
        return PersonIdentity(
            matched: (resp["matched"] as? Bool) ?? false,
            personID: personID,
            name: resp["name"] as? String,
            confidence: Float((resp["confidence"] as? Double) ?? 0)
        )
    }

    /// Query memory, returning answer + sources.
    public func query(_ q: String, contextJSON: String? = nil) async -> (answer: String, sources: [String]) {
        var payload: [String: Any] = ["q": q]
        if let ctx = contextJSON { payload["context_json"] = ctx }
        let resp = await send(method: "query_memory", payload: payload)
        let answer = (resp["answer"] as? String) ?? ""
        let sources = (resp["sources"] as? [Any])?.compactMap { $0 as? String } ?? []
        return (answer, sources)
    }

    /// Store a snapshot episode.
    public func storeEpisode(_ snapshotJSON: String) async {
        _ = await send(method: "store_episode", payload: ["snapshot_json": snapshotJSON])
    }

    /// Reflect over a list of snapshots; returns summary string.
    public func reflect(snapshots: [String]) async -> String {
        let resp = await send(method: "reflect", payload: ["snapshots": snapshots])
        return (resp["summary"] as? String) ?? ""
    }

    // MARK: - Legacy HTTP compatibility shim
    // Callers (FaceIdentifier, SpeakerResolver, MemoryEngine, MemoryQuery, SelfModel)
    // still use post(path:body:). We route the old HTTP paths to the new socket methods.

    public func post<T: Encodable>(path: String, body: T) async -> Data? {
        guard _isRunning else { return nil }

        // Encode body to a JSON-derived dict we can pass to send()
        guard let jsonData = try? JSONEncoder().encode(body),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }

        let method: String
        switch path {
        case "/identity/face":    method = "identify_face"
        case "/identity/voice":   method = "identify_voice"
        case "/memory/query":     method = "query_memory"
        case "/memory/ingest":    method = "store_episode"
        case "/memory/reflect":   method = "reflect"
        default:                  method = String(path.dropFirst()) // strip leading "/"
        }

        let resp = await send(method: method, payload: dict)

        // Re-encode response dict back to JSON Data for callers that JSONDecode it
        return try? JSONSerialization.data(withJSONObject: resp)
    }

    // MARK: - Private helpers

    private func resolveSidecarDir() -> URL {
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("memory_sidecar")
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
        }
        if let execURL = Bundle.main.executableURL {
            var candidate = execURL.deletingLastPathComponent()
            for _ in 0..<6 {
                let sidecar = candidate.appendingPathComponent("memory_sidecar")
                if FileManager.default.fileExists(atPath: sidecar.appendingPathComponent("main.py").path) {
                    return sidecar
                }
                candidate = candidate.deletingLastPathComponent()
            }
        }
        return URL(fileURLWithPath: "memory_sidecar")
    }

    private func waitForHealth(attempts: Int = 20) async {
        for _ in 0..<attempts {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await health() {
                logger.log(source: "memory", message: "sidecar ready at \(socketPath)")
                return
            }
        }
        logger.log(source: "memory", message: "[warn] sidecar did not respond in 10s — memory disabled")
    }
}
