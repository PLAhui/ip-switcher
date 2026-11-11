import Foundation
import IPSwitcherCore

/// 每秒采样一次接口计数，算出上行/下行速率并保留最近 60 秒的历史。
/// 只做数据，不碰 UI；通过 onUpdate 把轻量增量推给 WebView。
final class TrafficSampler {
    private struct Series {
        var down: [Double] = []
        var up: [Double] = []
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var peakDown: UInt64 = 0
        var peakUp: UInt64 = 0
        var online: Bool = true
    }

    private let limit = 60
    private var timer: Timer?
    private var tracked: Set<String> = []
    private var previous: [String: InterfaceCounters] = [:]
    private var series: [String: Series] = [:]
    private let started = Date()
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var onUpdate: (([String: Any]) -> Void)?

    /// devices 是 App 识别到的网卡（即使当前没插上，也保留一张 0 值图表并标记离线）。
    func start(devices: [String] = []) {
        guard timer == nil else { return }
        tracked = Set(devices)
        previous = TrafficCounters.read()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        IPSLog.write("流量采样已启动（1 秒/次）")
        tick()
    }

    func updateDevices(_ devices: [String]) { tracked = Set(devices) }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let current = TrafficCounters.read()
        let devices = tracked.union(Set(current.keys))
        guard !devices.isEmpty else { return }

        for device in devices {
            let value = current[device]
            let baseline = previous[device]
            let down = (value != nil && baseline != nil)
                ? TrafficCounters.delta(value!.bytesIn, from: baseline!.bytesIn) : 0
            let up = (value != nil && baseline != nil)
                ? TrafficCounters.delta(value!.bytesOut, from: baseline!.bytesOut) : 0
            var item = series[device] ?? Series()
            item.online = value != nil
            item.totalIn += down
            item.totalOut += up
            item.peakDown = max(item.peakDown, down)
            item.peakUp = max(item.peakUp, up)
            item.down.append(Double(down))
            item.up.append(Double(up))
            if item.down.count > limit {
                item.down.removeFirst(item.down.count - limit)
                item.up.removeFirst(item.up.count - limit)
            }
            series[device] = item
        }
        previous = current
        onUpdate?(payload())
    }

    private func payload() -> [String: Any] {
        let interfaces: [[String: Any]] = series.map { device, item in
            ["device": device,
             "down": item.down, "up": item.up,
             "downNow": item.down.last ?? 0,
             "upNow": item.up.last ?? 0,
             "totalIn": item.totalIn,
             "totalOut": item.totalOut,
             "peakDown": item.peakDown,
             "peakUp": item.peakUp,
             "online": item.online]
        }.sorted { $0["device"] as? String ?? "" < $1["device"] as? String ?? "" }

        return ["updatedAt": formatter.string(from: Date()),
                "elapsed": Int(Date().timeIntervalSince(started)),
                "sampleSeconds": limit,
                "interfaces": interfaces]
    }
}
