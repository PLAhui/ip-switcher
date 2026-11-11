import Foundation

public struct CommandPlan {
    public var commands: [[String]]
    public var skipped: [String]
    public var appliedServices: [String]

    public init(commands: [[String]], skipped: [String], appliedServices: [String]) {
        self.commands = commands
        self.skipped = skipped
        self.appliedServices = appliedServices
    }
}

public enum NetworkSetup {
    public static let path = "/usr/sbin/networksetup"

    public struct Result {
        public let code: Int32
        public let stdout: String
        public let stderr: String
    }

    public enum SetupError: Error, LocalizedError {
        case launchFailed(String)
        public var errorDescription: String? {
            switch self {
            case .launchFailed(let detail): return "无法执行 networksetup：\(detail)"
            }
        }
    }

    @discardableResult
    public static func run(_ args: [String]) throws -> Result {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            throw SetupError.launchFailed(error.localizedDescription)
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return Result(code: task.terminationStatus,
                      stdout: String(data: outData, encoding: .utf8) ?? "",
                      stderr: String(data: errData, encoding: .utf8) ?? "")
    }

    public static func read(_ args: [String]) throws -> String {
        let result = try run(args)
        guard result.code == 0 else {
            throw SetupError.launchFailed(result.stderr.isEmpty ? "exit \(result.code)" : result.stderr)
        }
        return result.stdout
    }

    /// 读取网卡当前实际分配到的 IP（DHCP 地址不在 preferences.plist 里，必须查 networksetup）。
    public static func liveIP(_ serviceName: String) -> String {
        guard let info = try? read(["-getinfo", serviceName]) else { return "未知" }
        for line in info.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("IP address:") {
                let value = text.replacingOccurrences(of: "IP address:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? "未分配" : value
            }
        }
        return "未分配"
    }

    public static func currentLocation() -> String {
        (try? read(["-getcurrentlocation"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知"
    }

    public static func listLocations() -> [String] {
        guard let output = try? read(["-listlocations"]) else { return [] }
        return output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func shellScript(apply commands: [[String]],
                                   rollback: [[String]] = []) -> String {
        var lines: [String] = ["#!/bin/bash", "fail=0",
                               "PATH=/usr/sbin:/usr/bin:/bin:/sbin"]
        for (index, command) in commands.enumerated() {
            lines.append(scriptLine(command, index: index + 1))
        }
        if !rollback.isEmpty {
            lines.append("if [ $fail -gt 0 ]; then")
            lines.append("  echo \"IPSW_ROLLBACK_START\" >&2")
            lines.append("  fail=0")
            for (index, command) in rollback.enumerated() {
                lines.append("  " + scriptLine(command, index: index + 1))
            }
            lines.append("  echo \"IPSWITCHER_ROLLED_BACK failures=$fail\"")
            lines.append("  exit 1")
            lines.append("fi")
        }
        lines.append("if [ $fail -gt 0 ]; then exit 1; fi")
        lines.append("echo \"IPSWITCHER_DONE failures=0\"")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func scriptLine(_ command: [[String]].Element,
                                   index: Int) -> String {
        let invocation = "/usr/sbin/networksetup " +
            command.map(shellQuote).joined(separator: " ")
        return "if ! \(invocation); then echo \"IPSW_FAILED_LINE=\(index)\" >&2; " +
               "fail=$((fail+1)); fi"
    }

    public static func buildCommands(services: [ServiceConfig],
                                     available: [ResolvedService],
                                     applyDNS: Bool = true,
                                     applyProxyAndRoutes: Bool = false,
                                     applyServiceOrder: Bool = false,
                                     serviceOrder: [String]? = nil) -> CommandPlan {
        var commands: [[String]] = []
        var skipped: [String] = []
        var applied: [String] = []

        for config in services {
            guard let target = ServiceResolver.resolve(config.match, in: available) else {
                skipped.append(config.match.displayName +
                               (config.match.device.map { " (\($0))" } ?? ""))
                continue
            }
            let service = target.name
            applied.append(service)

            if let ipv4 = config.ipv4 {
                switch ipv4.mode {
                case "manual":
                    guard let ip = ipv4.ip, let mask = ipv4.mask else { break }
                    commands.append(["-setmanual", service, ip, mask, ipv4.router ?? ""])
                case "off":
                    commands.append(["-setv4off", service])
                default:
                    commands.append(["-setdhcp", service])
                }
            }

            if applyDNS, let dns = config.dns {
                if dns.servers.isEmpty {
                    commands.append(["-setdnsservers", service, "Empty"])
                } else {
                    commands.append(["-setdnsservers", service] + dns.servers)
                }
                if let domains = dns.searchDomains {
                    if domains.isEmpty {
                        commands.append(["-setsearchdomains", service, "Empty"])
                    } else {
                        commands.append(["-setsearchdomains", service] + domains)
                    }
                }
            }

            if applyProxyAndRoutes {
                if let routes = config.routes {
                    var flat: [String] = []
                    for route in routes {
                        flat.append(contentsOf: [route.dest, route.mask, route.gateway])
                    }
                    commands.append(["-setadditionalroutes", service] + flat)
                }

                if let proxy = config.proxy {
                    if proxy.enabled, let host = proxy.host, let port = proxy.port {
                        let portString = String(port)
                        commands.append(["-setwebproxy", service, host, portString, "off", "", ""])
                        commands.append(["-setsecurewebproxy", service, host, portString, "off", "", ""])
                        commands.append(["-setsocksfirewallproxy", service, host, portString, "off", "", ""])
                        commands.append(["-setwebproxystate", service, "on"])
                        commands.append(["-setsecurewebproxystate", service, "on"])
                        commands.append(["-setsocksfirewallproxystate", service, "on"])
                    } else {
                        commands.append(["-setwebproxystate", service, "off"])
                        commands.append(["-setsecurewebproxystate", service, "off"])
                        commands.append(["-setsocksfirewallproxystate", service, "off"])
                    }
                    commands.append(["-setautoproxystate", service, "off"])
                    if let bypass = proxy.bypass, !bypass.isEmpty {
                        commands.append(["-setproxybypassdomains", service] + bypass)
                    }
                }

                if let ipv6 = config.ipv6 {
                    commands.append([ipv6 == "off" ? "-setv6off" : "-setv6automatic", service])
                }
            }
        }

        if applyServiceOrder, let order = serviceOrder, !order.isEmpty {
            let existing = Set(available.map { $0.name })
            let filtered = order.filter { existing.contains($0) }
            if filtered.count == existing.count, filtered.count >= 2 {
                commands.append(["-ordernetworkservices"] + filtered)
            }
        }

        return CommandPlan(commands: commands, skipped: skipped, appliedServices: applied)
    }

    public static func locationCommands(_ name: String) -> [[String]] {
        [["-switchtolocation", name]]
    }
}
