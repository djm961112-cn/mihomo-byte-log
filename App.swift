import AppKit
import SwiftUI

final class Collector {
    private let queue = DispatchQueue(label: "local.clash-traffic-monitor.collect")
    private var timer: DispatchSourceTimer?
    private var store: TrafficStore?
    private var previous: Snapshot?
    private var enabled = false
    private var nextRead = Date.distantPast
    private var nextPrune = Date.distantPast
    let url: URL
    private let status: (String) -> Void

    init(url: URL, status: @escaping (String) -> Void) {
        self.url = url
        self.status = status
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    deinit { timer?.cancel() }

    func setEnabled(_ value: Bool) {
        queue.async {
            self.enabled = value
            self.previous = nil
            self.nextRead = .distantPast
            self.status(value ? "正在连接 Clash…" : "采集已停止")
        }
    }

    private func tick() {
        let now = Date()
        guard now >= nextRead else { return }
        do {
            if store == nil {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                store = try TrafficStore(at: url)
            }
            if now >= nextPrune {
                try store?.prune(at: now)
                nextPrune = now.addingTimeInterval(60)
            }
            guard enabled else { return }
            let current = try Snapshot.read()
            if let previous { try store?.record(current, after: previous, at: Date()) }
            previous = current
            status("采集中")
        } catch {
            previous = nil
            nextRead = now.addingTimeInterval(5)
            status(error.localizedDescription)
        }
    }
}

final class MonitorModel: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var status = "采集已停止"
    @Published private(set) var rows: [TrafficRow] = []
    @Published private(set) var hasMore = false
    @Published var queryStatus = ""
    private var query = UUID()
    private let queryQueue = DispatchQueue(label: "local.clash-traffic-monitor.query", qos: .utility)
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Clash Traffic Monitor/traffic-v2.sqlite3")

    private lazy var collector = Collector(url: url) { [weak self] status in
        DispatchQueue.main.async {
            if self?.status != status { self?.status = status }
        }
    }

    init() { _ = collector }

    func toggle() {
        enabled.toggle()
        collector.setEnabled(enabled)
    }

    func refresh(_ filter: TrafficFilter, page: Int) {
        let token = UUID()
        query = token
        queryQueue.async {
            let result = Result { () -> [TrafficRow] in
                guard FileManager.default.fileExists(atPath: self.url.path) else { return [] }
                let store = try TrafficStore(at: self.url, readOnly: true)
                var rows: [TrafficRow] = []
                try store.read(filter, limit: 201, offset: Int64(page * 200)) { rows.append($0) }
                return rows
            }
            DispatchQueue.main.async {
                guard self.query == token else { return }
                switch result {
                case .success(let rows):
                    self.rows = Array(rows.prefix(200))
                    self.hasMore = rows.count > 200
                    self.queryStatus = rows.isEmpty ? "当前筛选没有记录" : ""
                case .failure(let error):
                    self.queryStatus = error.localizedDescription
                }
            }
        }
    }

    func export(_ filter: TrafficFilter) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Clash 流量明细.csv"
        panel.begin { response in
            guard response == .OK, let target = panel.url else { return }
            self.queryStatus = "正在导出…"
            self.queryQueue.async {
                let result = Result { try self.writeCSV(filter, to: target) }
                DispatchQueue.main.async {
                    switch result {
                    case .success: self.queryStatus = "CSV 已导出"
                    case .failure(let error): self.queryStatus = "导出失败。\(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func writeCSV(_ filter: TrafficFilter, to target: URL) throws {
        let store = try TrafficStore(at: url, readOnly: true)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).csv")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw MonitorError.message("无法创建导出文件。")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = try FileHandle(forWritingTo: temporary)
        defer { try? file.close() }
        try file.write(contentsOf: Data("\u{FEFF}采集分钟,连接开始时间,连接ID,进程,域名,出口节点,协议,规则,上行字节,下行字节,总字节,合计 MB\r\n".utf8))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let megabytesFormat = Decimal.FormatStyle.number
            .precision(.fractionLength(6))
            .grouping(.never)
            .locale(Locale(identifier: "en_US_POSIX"))
        var buffer = Data()
        try store.read(filter, limit: -1) { row in
            let fields = [formatter.string(from: row.date), row.started, row.connection, row.process,
                          row.host, row.node, row.network, row.rule].map(csvText)
                + [String(row.upload), String(row.download), String(row.totalBytes), row.totalMegabytes.formatted(megabytesFormat)]
            buffer.append(contentsOf: (fields.joined(separator: ",") + "\r\n").utf8)
            if buffer.count >= 64 * 1024 {
                try file.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try file.write(contentsOf: buffer)
        try file.close()
        guard rename(temporary.path, target.path) == 0 else {
            throw MonitorError.message("无法保存到所选位置。")
        }
    }
}

struct DetailView: View {
    @ObservedObject var model: MonitorModel
    @State private var filter = TrafficFilter()
    @State private var page = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(model.enabled ? "停止采集" : "开始采集") { model.toggle() }
                Text(model.status).foregroundStyle(.secondary)
                Spacer()
                Button("刷新") { model.refresh(filter, page: page) }
                Button("导出 CSV…") { model.export(filter) }.disabled(filter.end <= filter.start)
            }
            HStack {
                DatePicker("从", selection: $filter.start, displayedComponents: [.date, .hourAndMinute])
                DatePicker("到", selection: $filter.end, displayedComponents: [.date, .hourAndMinute])
                Toggle("只看代理", isOn: $filter.proxyOnly)
                Spacer()
            }
            TextField("筛选域名、进程、节点或规则", text: $filter.search)
            Table(model.rows) {
                TableColumn("采集分钟") { row in Text(row.date.formatted(.dateTime.month().day().hour().minute())) }
                    .width(min: 100, ideal: 112)
                TableColumn("进程", value: \.process).width(min: 90, ideal: 145)
                TableColumn("域名", value: \.host).width(min: 130, ideal: 230)
                TableColumn("出口节点", value: \.node).width(min: 100, ideal: 175)
                TableColumn("规则", value: \.rule).width(min: 80, ideal: 110)
                TableColumn("上行 B") { row in Text(row.upload.formatted()).monospacedDigit() }.width(82)
                TableColumn("下行 B") { row in Text(row.download.formatted()).monospacedDigit() }.width(82)
                TableColumn("合计 B") { row in Text(row.totalBytes.formatted()).monospacedDigit() }.width(82)
                TableColumn("合计 MB") { row in
                    Text(row.totalMegabytes.formatted(.number.precision(.fractionLength(6))))
                        .monospacedDigit()
                }.width(100)
            }
            HStack {
                Text(filter.end <= filter.start ? "结束时间必须晚于开始时间" : model.queryStatus)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("上一页") { page -= 1; model.refresh(filter, page: page) }.disabled(page == 0)
                Text("第 \(page + 1) 页")
                Button("下一页") { page += 1; model.refresh(filter, page: page) }.disabled(!model.hasMore)
            }
            Text("同一连接按分钟记录字节增量。保留最近 7 天，短连接和关闭前的末尾字节可能少计。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(minWidth: 1000, minHeight: 450)
        .onAppear { model.refresh(filter, page: page) }
        .task(id: filter) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            page = 0
            model.refresh(filter, page: 0)
        }
    }
}

struct TrayMenu: View {
    @ObservedObject var model: MonitorModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.status)
        Button(model.enabled ? "停止采集" : "开始采集") { model.toggle() }
        Button("查看记录") {
            openWindow(id: "traffic")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("退出 Mihomo Byte Log") { NSApp.terminate(nil) }
    }
}

@main
struct TrafficApp: App {
    @StateObject private var model = MonitorModel()

    init() { umask(0o077) }

    var body: some Scene {
        Window("Mihomo Byte Log", id: "traffic") {
            DetailView(model: model)
        }
        MenuBarExtra("Mihomo Byte Log", systemImage: "chart.bar.xaxis") {
            TrayMenu(model: model)
        }
    }
}
