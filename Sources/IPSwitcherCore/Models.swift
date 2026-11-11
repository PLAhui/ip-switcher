import Foundation

public struct ProfileStore: Codable, Equatable {
    public var version: Int
    public var activeProfileID: String?
    public var settings: AppSettings
    public var profiles: [Profile]

    public static let currentVersion = 1

    public static func empty() -> ProfileStore {
        ProfileStore(version: currentVersion, activeProfileID: nil,
                     settings: AppSettings(), profiles: [])
    }
}

public struct AppSettings: Codable, Equatable {
    public var verifyReadBack: Bool
    public var rollbackOnFail: Bool
    public var applyDNS: Bool
    public var applyProxyAndRoutes: Bool
    public var applyServiceOrder: Bool
    public var neutralizeUnlistedServices: Bool
    public var showLocationShortcuts: Bool

    public init() {
        verifyReadBack = true
        rollbackOnFail = true
        applyDNS = true
        applyProxyAndRoutes = false
        applyServiceOrder = false
        neutralizeUnlistedServices = false
        showLocationShortcuts = false
    }
}

public struct Profile: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var backend: String
    public var locationName: String?
    public var note: String?
    public var serviceOrder: [String]?
    public var services: [ServiceConfig]
    public var verify: VerifyPolicy?

    public var isDirect: Bool { backend != "location" }
}

public struct ServiceConfig: Codable, Equatable {
    public var match: ServiceMatch
    public var ipv4: IPv4Config?
    public var dns: DNSConfig?
    public var routes: [Route]?
    public var proxy: ProxyConfig?
    public var ipv6: String?
}

public struct ServiceMatch: Codable, Equatable {
    public var device: String?
    public var serviceName: String?
    public var mac: String?
    public var optional: Bool

    public var displayName: String {
        serviceName ?? device ?? mac ?? "未知网卡"
    }
}

public struct IPv4Config: Codable, Equatable {
    public var mode: String
    public var ip: String?
    public var mask: String?
    public var router: String?
}

public struct DNSConfig: Codable, Equatable {
    public var servers: [String]
    public var searchDomains: [String]?
}

public struct Route: Codable, Equatable {
    public var dest: String
    public var mask: String
    public var gateway: String
}

public struct ProxyConfig: Codable, Equatable {
    public var enabled: Bool
    public var host: String?
    public var port: Int?
    public var bypass: [String]?
}

public struct VerifyPolicy: Codable, Equatable {
    public var pingGateway: Bool
    public var rollbackOnFail: Bool
    public var timeoutSec: Int

    public static func defaults() -> VerifyPolicy {
        VerifyPolicy(pingGateway: false, rollbackOnFail: true, timeoutSec: 5)
    }
}

public struct ConfigSnapshot: Codable, Equatable {
    public var createdAt: String
    public var reason: String
    public var services: [ServiceConfig]
    public var serviceOrder: [String]?
    public var affectedServices: [String]?
    public var affectedDevices: [String]?
    public var applyCommands: [[String]]?
}
