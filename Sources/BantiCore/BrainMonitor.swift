// Sources/BantiCore/BrainMonitor.swift
import Foundation
import SwiftUI

public struct MonitorEvent: Identifiable, Sendable {
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

    public init() {}

    public func append(_ event: BantiEvent) {
        // Track episode timestamp for latency calculation
        if case .episodeBound = event.payload { episodeTimestampNs = event.timestampNs }
        let latency = (event.topic.hasPrefix("brain.") || event.topic == "motor.speech_plan")
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
        case .faceUpdate(let p): return "face: \(p.personName ?? "unknown") (\(String(format: "%.2f", p.confidence)))"
        case .episodeBound(let p): return "episode: \"\(p.text.prefix(60))\""
        case .brainRoute(let p): return "route → \(p.tracks.joined(separator: ","))"
        case .brainResponse(let p): return "[\(p.track)]: \"\(p.text.prefix(40))\""
        case .speechPlan(let p): return "plan: \(p.sentences.count) sentences"
        case .memoryRetrieved(let p): return "memory: \(p.personName ?? p.personID) — \(p.facts.count) facts"
        case .memorySaved(let p): return "stored: \(p.stored)"
        case .screenUpdate(let p): return "screen: \(p.ocrLines.count) lines — \(p.interpretation.prefix(40))"
        case .emotionUpdate(let p): return "emotion: \(p.emotions.first.map { "\($0.label) \(String(format: "%.2f", $0.score))" } ?? "none") via \(p.source)"
        case .soundUpdate(let p): return "sound: \(p.label) (\(String(format: "%.2f", p.confidence)))"
        case .voiceSpeaking(let p): return "voice: speaking=\(p.speaking) ~\(p.estimatedDurationMs)ms"
        }
    }
}

public struct BrainMonitorView: View {
    @ObservedObject var vm: BrainMonitorViewModel

    public init(vm: BrainMonitorViewModel) { self.vm = vm }

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
                    Text(event.source)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 140, alignment: .leading)
                    VStack(alignment: .leading) {
                        Text(event.topic).font(.caption.bold())
                        Text(event.payloadSummary).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    if let ms = event.latencyMs {
                        Text(String(format: "%.0fms", ms))
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }
        }
        .frame(width: 700, height: 500)
    }
}

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
