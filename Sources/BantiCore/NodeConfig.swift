// Sources/BantiCore/NodeConfig.swift
import Foundation
import Yams

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
        let decoder = YAMLDecoder()
        struct Wrapper: Codable {
            let nodes: [String: NodeEntry]
        }
        let wrapper = try decoder.decode(Wrapper.self, from: yaml)
        return NodeConfig(nodes: wrapper.nodes)
    }

    private static var bantiRoot: String {
        if let root = ProcessInfo.processInfo.environment["BANTI_ROOT"] {
            return root
        }
        // For CLI: use executable's directory
        if let execPath = Bundle.main.executableURL?.deletingLastPathComponent().path {
            return execPath
        }
        return FileManager.default.currentDirectoryPath
    }

    public static func loadFromFile(_ path: String = "NodeConfig.yaml") -> NodeConfig? {
        let resolvedPath = path.hasPrefix("/") ? path : (bantiRoot as NSString).appendingPathComponent(path)
        guard let yaml = try? String(contentsOfFile: resolvedPath) else { return nil }
        return try? parse(yaml: yaml)
    }

    public func promptContent(for nodeName: String) -> String? {
        guard let entry = nodes[nodeName], let promptFile = entry.promptFile else { return nil }
        let resolvedPath = promptFile.hasPrefix("/") ? promptFile : (NodeConfig.bantiRoot as NSString).appendingPathComponent(promptFile)
        return try? String(contentsOfFile: resolvedPath)
    }
}
