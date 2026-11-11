import Foundation

public struct ResolvedService: Equatable {
    public let name: String
    public let device: String
    public let hardwarePort: String

    public init(name: String, device: String, hardwarePort: String) {
        self.name = name
        self.device = device
        self.hardwarePort = hardwarePort
    }
}

public enum ServiceResolver {
    public static func list() throws -> [ResolvedService] {
        let output = try NetworkSetup.read(["-listnetworkserviceorder"])
        var result: [ResolvedService] = []
        var pendingName: String?

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("(Hardware Port:") {
                let body = line
                    .replacingOccurrences(of: "(Hardware Port: ", with: "")
                    .replacingOccurrences(of: ")", with: "")
                let parts = body.components(separatedBy: ", Device: ")
                let hardwarePort = parts.first ?? ""
                let device = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                if let name = pendingName, !device.isEmpty {
                    result.append(ResolvedService(name: name, device: device,
                                                  hardwarePort: hardwarePort))
                }
                pendingName = nil
            } else if line.hasPrefix("("), let close = line.firstIndex(of: ")") {
                let tail = String(line[line.index(after: close)...])
                    .replacingOccurrences(of: "*", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty { pendingName = tail }
            }
        }
        return result
    }

    public static func resolve(_ match: ServiceMatch,
                               in services: [ResolvedService]) -> ResolvedService? {
        if let device = match.device, !device.isEmpty,
           let hit = services.first(where: { $0.device == device }) {
            return hit
        }
        if let name = match.serviceName, !name.isEmpty,
           let hit = services.first(where: { $0.name == name }) {
            return hit
        }
        return nil
    }
}
