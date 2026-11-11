import Foundation
import Darwin

/// 一张网卡的累计接口计数（来自 AF_LINK 的 if_data，无需 fork 外部命令）。
public struct InterfaceCounters: Equatable {
    public let device: String
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    public let packetsIn: UInt64
    public let packetsOut: UInt64

    public init(device: String, bytesIn: UInt64, bytesOut: UInt64,
                packetsIn: UInt64, packetsOut: UInt64) {
        self.device = device
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.packetsIn = packetsIn
        self.packetsOut = packetsOut
    }
}

public enum TrafficCounters {
    /// ifi_ibytes / ifi_obytes 是 32 位计数器，长时间运行会回绕。
    private static let wrap = UInt64(UInt32.max) + 1

    public static func read() -> [String: InterfaceCounters] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let head = pointer else { return [:] }
        defer { freeifaddrs(pointer) }

        var result: [String: InterfaceCounters] = [:]
        var current = head
        while true {
            let entry = current.pointee
            if let address = entry.ifa_addr,
               address.pointee.sa_family == UInt8(AF_LINK),
               let raw = entry.ifa_data {
                let name = String(cString: entry.ifa_name)
                let data = raw.assumingMemoryBound(to: if_data.self).pointee
                result[name] = InterfaceCounters(
                    device: name,
                    bytesIn: UInt64(data.ifi_ibytes),
                    bytesOut: UInt64(data.ifi_obytes),
                    packetsIn: UInt64(data.ifi_ipackets),
                    packetsOut: UInt64(data.ifi_opackets))
            }
            guard let next = entry.ifa_next else { break }
            current = next
        }
        return result
    }

    /// 两次采样之间的增量，兼容 32 位计数回绕。
    public static func delta(_ current: UInt64, from previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : (current + wrap - previous)
    }
}
