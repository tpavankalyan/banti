# Cortical Graph — Phase 3: Plumbing + Observability

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace HTTP sidecar with Unix domain socket + msgpack, rewrite `ConversationBuffer` as a ring buffer, add YAML config hot-reload, and build the `BrainMonitor` debug panel.

**Architecture:** The sidecar's FastAPI server is replaced with a raw socket server. Each improvement is independently shippable — the system runs correctly after each task. Phase 3 ends with the full cortical graph running on the target stack.

**Tech Stack:** Swift `Network.framework` (`NWConnection`), Python `socket` + `msgpack`, SwiftUI (macOS), PyYAML (already available), XCTest

**Prerequisite:** Phase 2 complete and merged.

---

## File Map

**New files:**
- `Sources/BantiCore/BrainMonitor.swift` — `CorticalNode` subscribing to `*`, SwiftUI list
- `Sources/BantiCore/NodeConfig.swift` — YAML config loader + hot-reload on SIGHUP
- `NodeConfig.yaml` — node definitions
- `prompts/brainstem.md`, `prompts/limbic.md`, `prompts/prefrontal.md`, `prompts/surprise_detector.md`, `prompts/temporal_binder.md`, `prompts/track_router.md`, `prompts/response_arbitrator.md`, `prompts/memory_consolidator.md`
- `memory_sidecar/socket_server.py` — Unix socket server replacing FastAPI

**Modified files:**
- `Sources/BantiCore/ConversationBuffer.swift` — ring buffer backing store
- `Sources/BantiCore/MemorySidecar.swift` — socket client replacing HTTP client
- `Sources/BantiCore/MemoryEngine.swift` — load prompts from config, pass to nodes
- `Sources/banti/main.swift` — `--monitor` flag → launch BrainMonitor
- `memory_sidecar/main.py` — replace FastAPI server with socket server
- `memory_sidecar/requirements.txt` — remove fastapi/uvicorn, add msgpack

**Deleted files:**
- `Sources/BantiCore/ContextAggregator.swift` — after `SelfModel` migrated to events

---

## Task 1: ConversationBuffer Ring Buffer

**Files:**
- Modify: `Sources/BantiCore/ConversationBuffer.swift`
- Modify: `Tests/BantiTests/ConversationBufferTests.swift`

- [ ] **Add ring buffer wrap-around tests**

```swift
// Add to Tests/BantiTests/ConversationBufferTests.swift
func testRingBufferWrapsAround() async {
    let buffer = ConversationBuffer(capacity: 3) // tiny capacity for test
    await buffer.addHumanTurn("turn1")
    await buffer.addHumanTurn("turn2")
    await buffer.addHumanTurn("turn3")
    await buffer.addHumanTurn("turn4") // should evict turn1

    let recent = await buffer.recentTurns(limit: 10)
    XCTAssertEqual(recent.count, 3)
    XCTAssertEqual(recent.first?.text, "turn2")
    XCTAssertEqual(recent.last?.text, "turn4")
}

func testRecentTurnsRespectLimit() async {
    let buffer = ConversationBuffer(capacity: 60)
    for i in 1...10 { await buffer.addHumanTurn("turn\(i)") }
    let recent = await buffer.recentTurns(limit: 3)
    XCTAssertEqual(recent.count, 3)
    XCTAssertEqual(recent.last?.text, "turn10")
}
```

- [ ] **Run new tests — expect failure** `swift test --filter ConversationBufferTests 2>&1 | tail -5`

- [ ] **Rewrite backing store**

```swift
// Sources/BantiCore/ConversationBuffer.swift — replace private vars
public actor ConversationBuffer {
    private let capacity: Int
    private var buffer: [ConversationTurn?]
    private var head: Int = 0    // next write index
    private var count: Int = 0   // number of valid entries

    public init(capacity: Int = 60) {
        self.capacity = capacity
        self.buffer = Array(repeating: nil, count: capacity)
    }

    private func append(_ turn: ConversationTurn) {
        buffer[head % capacity] = turn
        head += 1
        count = min(count + 1, capacity)
    }

    public func recentTurns(limit: Int = 10) -> [ConversationTurn] {
        let n = min(limit, count)
        var result: [ConversationTurn] = []
        let startOffset = count - n
        for i in 0..<n {
            let idx = ((head - count) + startOffset + i) % capacity
            if let turn = buffer[(idx + capacity) % capacity] {
                result.append(turn)
            }
        }
        return result
    }
    // addBantiTurn, addHumanTurn, lastBantiUtterance — unchanged
}
```

- [ ] **Run all ConversationBuffer tests** `swift test --filter ConversationBufferTests 2>&1 | tail -5`

- [ ] **Run full test suite** `swift test 2>&1 | tail -5`

- [ ] **Commit**
```bash
git add Sources/BantiCore/ConversationBuffer.swift Tests/BantiTests/ConversationBufferTests.swift
git commit -m "refactor: ConversationBuffer ring buffer — capacity 60, O(1) push"
```

---

## Task 2: Unix Socket Sidecar — Python side

**Files:**
- Create: `memory_sidecar/socket_server.py`
- Modify: `memory_sidecar/main.py`
- Modify: `memory_sidecar/requirements.txt`

- [ ] **Add msgpack to requirements**

```
# memory_sidecar/requirements.txt — replace fastapi, uvicorn, python-multipart with:
msgpack>=1.0
# keep: openai, anthropic, mem0ai, graphiti-core, python-dotenv, sqlalchemy, etc.
```

- [ ] **Write the failing test for socket server**

```python
# memory_sidecar/tests/test_socket_server.py
import socket, msgpack, threading, os, time, pytest

SOCK_PATH = "/tmp/banti_test.sock"

def test_health_ping():
    """Start the socket server, send a health ping, expect pong."""
    from socket_server import SocketServer
    server = SocketServer(sock_path=SOCK_PATH, testing=True)
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    time.sleep(0.05)

    sock = socket.socket(socket.AF_UNIX)
    sock.connect(SOCK_PATH)
    payload = msgpack.packb({"method": "health"})
    length = len(payload).to_bytes(4, "big")
    sock.sendall(length + payload)
    resp_len = int.from_bytes(sock.recv(4), "big")
    resp = msgpack.unpackb(sock.recv(resp_len))
    sock.close()
    server.stop()
    assert resp == {"status": "ok"}
```

- [ ] **Run test — expect failure** `cd memory_sidecar && python -m pytest tests/test_socket_server.py -v 2>&1 | tail -5`

- [ ] **Implement `socket_server.py`**

```python
# memory_sidecar/socket_server.py
import socket, os, struct, threading
import msgpack

DISPATCH = {}

def handler(method):
    def decorator(fn):
        DISPATCH[method] = fn
        return fn
    return decorator

class SocketServer:
    def __init__(self, sock_path="/tmp/banti_memory.sock", testing=False):
        self.sock_path = sock_path
        self._stop = threading.Event()
        self.testing = testing
        if os.path.exists(sock_path):
            os.unlink(sock_path)
        self._sock = socket.socket(socket.AF_UNIX)
        self._sock.bind(sock_path)
        self._sock.listen(5)
        self._sock.settimeout(0.5)

    def serve_forever(self):
        while not self._stop.is_set():
            try:
                conn, _ = self._sock.accept()
                threading.Thread(target=self._handle_conn, args=(conn,), daemon=True).start()
            except socket.timeout:
                continue

    def stop(self):
        self._stop.set()
        self._sock.close()
        if os.path.exists(self.sock_path):
            os.unlink(self.sock_path)

    def _handle_conn(self, conn):
        try:
            raw_len = conn.recv(4)
            if len(raw_len) < 4:
                return
            length = struct.unpack(">I", raw_len)[0]
            data = b""
            while len(data) < length:
                chunk = conn.recv(length - len(data))
                if not chunk:
                    return
                data += chunk
            request = msgpack.unpackb(data, raw=False)
            method = request.get("method", "")
            fn = DISPATCH.get(method)
            if fn:
                import asyncio
                if asyncio.iscoroutinefunction(fn):
                    result = asyncio.run(fn(request))
                else:
                    result = fn(request)
            else:
                result = {"error": f"unknown method: {method}"}
            response = msgpack.packb(result)
            conn.sendall(struct.pack(">I", len(response)) + response)
        except Exception as e:
            print(f"[socket] error: {e}")
        finally:
            conn.close()


@handler("health")
def health(_req):
    return {"status": "ok"}


@handler("identify_face")
async def identify_face(req):
    import base64
    from identity import identify_face as _identify
    try:
        jpeg = base64.b64decode(req["jpeg_b64"])
        person_id, name, confidence = _identify(jpeg)
        return {"matched": confidence >= 0.6, "person_id": person_id,
                "name": name, "confidence": confidence}
    except Exception as e:
        return {"error": str(e)}


@handler("query_memory")
async def query_memory(req):
    from memory import query_memory as _query
    result = await _query(req.get("q", ""), req.get("context_json"))
    return result


@handler("store_episode")
async def store_episode(req):
    from memory import ingest_snapshot
    from datetime import datetime
    result = await ingest_snapshot(req.get("snapshot_json", "{}"), datetime.utcnow())
    return result


@handler("reflect")
async def reflect(req):
    from memory import reflect_memory
    result = await reflect_memory(req.get("snapshots", []))
    return result
```

- [ ] **Update `main.py`** — start `SocketServer` in a thread instead of uvicorn. Keep `init_memory()` + `init_identity()` startup.

```python
# memory_sidecar/main.py (simplified replacement)
import asyncio, os, threading
from dotenv import load_dotenv
load_dotenv()

async def startup():
    from identity import init_identity
    await init_identity()
    from memory import init_memory
    await init_memory()

if __name__ == "__main__":
    asyncio.run(startup())
    from socket_server import SocketServer
    server = SocketServer()
    print("[sidecar] listening on /tmp/banti_memory.sock")
    server.serve_forever()
```

- [ ] **Run test — expect pass** `cd memory_sidecar && python -m pytest tests/test_socket_server.py -v 2>&1 | tail -5`

- [ ] **Commit**
```bash
git add memory_sidecar/socket_server.py memory_sidecar/main.py memory_sidecar/requirements.txt memory_sidecar/tests/test_socket_server.py
git commit -m "feat: replace FastAPI sidecar with Unix domain socket + msgpack"
```

---

## Task 3: MemorySidecar Socket Client — Swift side

**Files:**
- Modify: `Sources/BantiCore/MemorySidecar.swift`
- Modify: `Tests/BantiTests/MemorySidecarTests.swift`

- [ ] **Add socket ping test**

```swift
// Tests/BantiTests/MemorySidecarTests.swift — add
func testHealthPingOverSocket() async throws {
    // Launch the Python socket server as a subprocess
    let sidecar = MemorySidecar(logger: Logger())
    await sidecar.start()
    try? await Task.sleep(nanoseconds: 500_000_000) // wait for startup
    let healthy = await sidecar.isRunning
    XCTAssertTrue(healthy)
}
```

This test requires the Python sidecar to be running. Mark with `// requires_sidecar` and skip in CI via `XCTSkipIf(!sidecarAvailable)`.

- [ ] **Rewrite `MemorySidecar`** to use `NWConnection` with `NWEndpoint.unix(path: "/tmp/banti_memory.sock")`. Implement `send(method:payload:) async -> [String: Any]` as the private primitive. Implement all public typed methods:

```swift
public func identifyFace(_ jpegData: Data) async -> PersonIdentity {
    let b64 = jpegData.base64EncodedString()
    let resp = await send(method: "identify_face", payload: ["jpeg_b64": b64])
    return PersonIdentity(from: resp)
}

public func query(_ q: String, contextJSON: String? = nil) async -> [String] {
    let resp = await send(method: "query_memory", payload: ["q": q, "context_json": contextJSON as Any])
    return resp["results"] as? [String] ?? []
}

public func storeEpisode(_ snapshotJSON: String) async {
    _ = await send(method: "store_episode", payload: ["snapshot_json": snapshotJSON])
}

public func reflect(snapshots: [String]) async -> String {
    let resp = await send(method: "reflect", payload: ["snapshots": snapshots])
    return resp["summary"] as? String ?? ""
}
```

The `send` method serialises with `msgpack` (use a Swift msgpack library or a simple custom encoder for the small set of types used), writes 4-byte big-endian length prefix, reads response with same framing.

Note: `Network.framework` is available on macOS 10.14+. Use `NWConnection` with the `.unix(path:)` endpoint. Wrap in continuation-based async.

- [ ] **Update all callers** that previously called `MemorySidecar.post(...)` to use the new typed methods.

- [ ] **Build** `swift build 2>&1 | tail -3`

- [ ] **Run sidecar tests** `swift test --filter MemorySidecarTests 2>&1 | tail -5`

- [ ] **Commit**
```bash
git add Sources/BantiCore/MemorySidecar.swift Tests/BantiTests/MemorySidecarTests.swift
git commit -m "refactor: MemorySidecar — Unix socket client replacing HTTP, typed async API"
```

---

## Task 4: YAML Config + Prompts

**Files:**
- Create: `NodeConfig.yaml`
- Create: `Sources/BantiCore/NodeConfig.swift`
- Create: `prompts/brainstem.md` (and one per node)

- [ ] **Write the failing test**

```swift
// Tests/BantiTests/NodeConfigTests.swift
import XCTest
@testable import BantiCore

final class NodeConfigTests: XCTestCase {
    func testParsesNodeEntries() throws {
        let yaml = """
        nodes:
          brainstem:
            model: llama3.1-8b
            subscribes: [brain.route]
            publishes: [brain.brainstem.response]
            prompt_file: prompts/brainstem.md
            timeout_s: 3
        """
        let config = try NodeConfig.parse(yaml: yaml)
        let brainstem = try XCTUnwrap(config.nodes["brainstem"])
        XCTAssertEqual(brainstem.model, "llama3.1-8b")
        XCTAssertEqual(brainstem.subscribes, ["brain.route"])
        XCTAssertEqual(brainstem.timeoutS, 3)
    }
}
```

- [ ] **Run test — expect failure** `swift test --filter NodeConfigTests 2>&1 | tail -5`

- [ ] **Implement `NodeConfig.swift`** — parse YAML using `Codable` + a simple recursive descent YAML parser (or use a Swift YAML package like `Yams` added to `Package.swift`). `ConfigLoader` reads from `NodeConfig.yaml` relative to the working directory and registers a `SIGHUP` handler that re-reads the file and updates each node's system prompt.

```swift
// Sources/BantiCore/NodeConfig.swift
import Foundation

public struct NodeEntry: Codable {
    public let model: String?
    public let subscribes: [String]?
    public let publishes: [String]?
    public let promptFile: String?
    public let timeoutS: Int?
    public let windowMs: Int?

    enum CodingKeys: String, CodingKey {
        case model, subscribes, publishes
        case promptFile = "prompt_file"
        case timeoutS = "timeout_s"
        case windowMs = "window_ms"
    }
}

public struct NodeConfig {
    public let nodes: [String: NodeEntry]

    public static func parse(yaml: String) throws -> NodeConfig {
        // Use Yams: import Yams; let decoded = try Yams.load(yaml: yaml)
        // or implement a minimal YAML→JSON bridge
        // ...
        fatalError("implement with Yams")
    }

    public static func loadFromFile(_ path: String = "NodeConfig.yaml") -> NodeConfig? {
        guard let yaml = try? String(contentsOfFile: path) else { return nil }
        return try? parse(yaml: yaml)
    }
}
```

Add `Yams` to `Package.swift`:
```swift
.package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
// add to BantiCore target dependencies: .product(name: "Yams", package: "Yams")
```

- [ ] **Create `NodeConfig.yaml`** at project root — copy YAML from spec

- [ ] **Create prompt files** — one `.md` file per node in `prompts/`. Copy the system prompt strings from each node's Swift file into the corresponding `.md` file. Update each node's `init` to accept a `systemPrompt: String` parameter and read it from `NodeConfig` at startup.

- [ ] **Implement SIGHUP hot-reload** in `main.swift`:

```swift
signal(SIGHUP) { _ in
    Task {
        guard let config = NodeConfig.loadFromFile() else { return }
        // Re-read each prompt file and update node system prompts
        // Nodes expose a `setSystemPrompt(_ prompt: String) async` method
    }
}
```

- [ ] **Run test — expect pass** `swift test --filter NodeConfigTests 2>&1 | tail -5`

- [ ] **Commit**
```bash
git add NodeConfig.yaml Sources/BantiCore/NodeConfig.swift prompts/ Package.swift Package.resolved Tests/BantiTests/NodeConfigTests.swift
git commit -m "feat: YAML config loader + prompt files — hot-reload on SIGHUP"
```

---

## Task 5: BrainMonitor

**Files:**
- Create: `Sources/BantiCore/BrainMonitor.swift`
- Modify: `Sources/banti/main.swift`

No automated tests for the UI itself — verify manually.

- [ ] **Implement `BrainMonitor`**

```swift
// Sources/BantiCore/BrainMonitor.swift
import Foundation
import SwiftUI

public struct MonitorEvent: Identifiable {
    public let id = UUID()
    public let source: String
    public let topic: String
    public let timestampNs: UInt64
    public let payloadSummary: String
    public let latencyMs: Double?
}

@MainActor
public class BrainMonitorViewModel: ObservableObject {
    @Published public var events: [MonitorEvent] = []
    private let maxEvents = 500
    private var episodeTimestampNs: UInt64?

    public func append(_ event: BantiEvent) {
        // Track episode timestamp for latency calculation
        if case .episodeBound = event.payload { episodeTimestampNs = event.timestampNs }
        let latency = event.topic.hasPrefix("brain.") || event.topic == "motor.speech_plan"
            ? episodeTimestampNs.map { Double(event.timestampNs - $0) / 1_000_000 }
            : nil
        let monitor = MonitorEvent(source: event.source, topic: event.topic,
                                   timestampNs: event.timestampNs,
                                   payloadSummary: summarise(event),
                                   latencyMs: latency)
        events.insert(monitor, at: 0)
        if events.count > maxEvents { events.removeLast() }
    }

    private func summarise(_ event: BantiEvent) -> String {
        switch event.payload {
        case .speechDetected(let p): return "speech: \"\(p.transcript.prefix(40))\""
        case .faceUpdate(let p): return "face: \(p.personName ?? "unknown") \(p.confidence)"
        case .episodeBound(let p): return "episode: \"\(p.text.prefix(60))\""
        case .brainRoute(let p): return "route: \(p.tracks.joined(separator: ","))"
        case .brainResponse(let p): return "[\(p.track)]: \"\(p.text.prefix(40))\""
        case .speechPlan(let p): return "plan: \(p.sentences.count) sentences"
        case .memoryRetrieved(let p): return "memory: \(p.personName ?? p.personID) \(p.facts.count) facts"
        default: return event.topic
        }
    }
}

public struct BrainMonitorView: View {
    @ObservedObject var vm: BrainMonitorViewModel

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("BrainMonitor").font(.headline).padding()
                Spacer()
                Text("\(vm.events.count) events").foregroundColor(.secondary).padding()
            }
            Divider()
            List(vm.events) { event in
                HStack(alignment: .top, spacing: 8) {
                    Text(event.source).font(.caption).foregroundColor(.secondary).frame(width: 120, alignment: .leading)
                    VStack(alignment: .leading) {
                        Text(event.topic).font(.caption.bold())
                        Text(event.payloadSummary).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    if let ms = event.latencyMs {
                        Text(String(format: "%.0fms", ms)).font(.caption2).foregroundColor(.orange)
                    }
                }
            }
        }
        .frame(width: 700, height: 500)
    }
}
```

- [ ] **CorticalNode conformance** — add a `BrainMonitorNode` actor that subscribes to `*` and forwards each event to `vm.append()` on the main actor:

```swift
public actor BrainMonitorNode: CorticalNode {
    public let id = "brain_monitor"
    public let subscribedTopics = ["*"]
    private let vm: BrainMonitorViewModel

    public init(vm: BrainMonitorViewModel) { self.vm = vm }

    public func start(bus: EventBus) async {
        await bus.subscribe(topic: "*") { [weak self] event in
            await self?.handle(event)
        }
    }

    public func handle(_ event: BantiEvent) async {
        await MainActor.run { vm.append(event) }
    }
}
```

- [ ] **Add `--monitor` flag to `main.swift`**

```swift
if CommandLine.arguments.contains("--monitor") {
    let vm = await MainActor.run { BrainMonitorViewModel() }
    let monitorNode = BrainMonitorNode(vm: vm)
    await monitorNode.start(bus: memoryEngine.eventBus)
    await MainActor.run {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        win.title = "BrainMonitor"
        win.contentView = NSHostingView(rootView: BrainMonitorView(vm: vm))
        win.makeKeyAndOrderFront(nil)
    }
}
```

- [ ] **Manual test** — run `swift run banti --monitor`, speak a sentence, verify events appear in the monitor window

- [ ] **Commit**
```bash
git add Sources/BantiCore/BrainMonitor.swift Sources/banti/main.swift
git commit -m "feat: BrainMonitor — real-time event stream debug panel, opt-in via --monitor"
```

---

## Task 6: Delete ContextAggregator, Migrate SelfModel

**Files:**
- Modify: `Sources/BantiCore/SelfModel.swift`
- Delete: `Sources/BantiCore/ContextAggregator.swift`

- [ ] **Update `SelfModel`** — subscribe to `episode.bound` events instead of calling `snapshotJSON()`. Accumulate episode texts in a rolling window and call `reflect()` on the sidecar every 10 minutes.

- [ ] **Remove `ContextAggregator` from `MemoryEngine`**

- [ ] **Delete** `rm Sources/BantiCore/ContextAggregator.swift`

- [ ] **Run full test suite** `swift test 2>&1 | tail -5`

- [ ] **Commit**
```bash
git add Sources/BantiCore/SelfModel.swift Sources/BantiCore/MemoryEngine.swift
git rm Sources/BantiCore/ContextAggregator.swift
git commit -m "refactor: SelfModel uses episode.bound events, ContextAggregator deleted"
```

---

## Task 7: Phase 3 Final Verification

- [ ] **Run full test suite** `swift test 2>&1 | tail -10`

- [ ] **Integration smoke test**
```bash
swift run banti --monitor 2>&1 &
sleep 5
# Speak "hello banti" — verify in logs and monitor:
# [bus] audio_cortex → sensor.audio
# [bus] surprise_detector → gate.surprise
# [bus] temporal_binder → episode.bound
# [bus] track_router → brain.route
# [bus] brainstem → brain.brainstem.response
# [bus] response_arbitrator → motor.speech_plan
# [bus] banti_voice → motor.voice
kill %1
```

- [ ] **Verify sidecar latency**

```python
import socket, msgpack, struct, time
sock = socket.socket(socket.AF_UNIX)
sock.connect("/tmp/banti_memory.sock")
payload = msgpack.packb({"method": "health"})
t0 = time.time()
sock.sendall(struct.pack(">I", len(payload)) + payload)
resp_len = struct.unpack(">I", sock.recv(4))[0]
sock.recv(resp_len)
print(f"latency: {(time.time()-t0)*1000:.2f}ms")  # expect < 2ms
```

- [ ] **Final commit**
```bash
git commit -m "chore: Phase 3 complete — socket sidecar, ring buffer, YAML config, BrainMonitor"
```
