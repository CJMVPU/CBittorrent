import Foundation

/// Missing keys from earlier app versions inherit defaults without losing saved values.
struct AppSettings: Codable, Equatable {
    var downloadPath: String = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.path
    var downloadLimitKB: Int = 0
    var uploadLimitKB: Int = 0
    var closeKeepsTransfers: Bool = true
    var notifyOnCompletion: Bool = false
    var addPaused: Bool = false
    var sequentialDownloads: Bool = false
    var preallocateFiles: Bool = false
    var listenPort: Int = 0
    var enableUPnP: Bool = true
    var enableNATPMP: Bool = true
    var enableDHT: Bool = true
    var enablePeX: Bool = true
    var enableLSD: Bool = true
    var transportMode: Int = 0
    var encryptionMode: Int = 0
    var maxConnections: Int = 200
    var maxConnectionsPerTorrent: Int = 100
    var uploadSlots: Int = 8
    var queueEnabled: Bool = true
    var maxActiveDownloads: Int = 3
    var maxActiveUploads: Int = 5
    var maxActiveTorrents: Int = 8
    var seedRatioLimit: Double = 0
    var seedTimeLimitMinutes: Int = 0
    var proxyType: Int = 0
    var proxyHost: String = ""
    var proxyPort: Int = 1080
    var proxyPeers: Bool = true
    var proxyTrackers: Bool = true
    var autoAddTrackers: Bool = false
    var defaultTrackers: String = ""

    init() {}

    private enum CodingKeys: String, CodingKey {
        case downloadPath
        case downloadLimitKB
        case uploadLimitKB
        case closeKeepsTransfers
        case notifyOnCompletion
        case addPaused
        case sequentialDownloads
        case preallocateFiles
        case listenPort
        case enableUPnP
        case enableNATPMP
        case enableDHT
        case enablePeX
        case enableLSD
        case transportMode
        case encryptionMode
        case maxConnections
        case maxConnectionsPerTorrent
        case uploadSlots
        case queueEnabled
        case maxActiveDownloads
        case maxActiveUploads
        case maxActiveTorrents
        case seedRatioLimit
        case seedTimeLimitMinutes
        case proxyType
        case proxyHost
        case proxyPort
        case proxyPeers
        case proxyTrackers
        case autoAddTrackers
        case defaultTrackers
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        downloadPath = try values.decodeIfPresent(String.self, forKey: .downloadPath) ?? downloadPath
        downloadLimitKB = try values.decodeIfPresent(Int.self, forKey: .downloadLimitKB) ?? downloadLimitKB
        uploadLimitKB = try values.decodeIfPresent(Int.self, forKey: .uploadLimitKB) ?? uploadLimitKB
        closeKeepsTransfers = try values.decodeIfPresent(Bool.self, forKey: .closeKeepsTransfers) ?? closeKeepsTransfers
        notifyOnCompletion = try values.decodeIfPresent(Bool.self, forKey: .notifyOnCompletion) ?? notifyOnCompletion
        addPaused = try values.decodeIfPresent(Bool.self, forKey: .addPaused) ?? addPaused
        sequentialDownloads = try values.decodeIfPresent(Bool.self, forKey: .sequentialDownloads) ?? sequentialDownloads
        preallocateFiles = try values.decodeIfPresent(Bool.self, forKey: .preallocateFiles) ?? preallocateFiles
        listenPort = try values.decodeIfPresent(Int.self, forKey: .listenPort) ?? listenPort
        enableUPnP = try values.decodeIfPresent(Bool.self, forKey: .enableUPnP) ?? enableUPnP
        enableNATPMP = try values.decodeIfPresent(Bool.self, forKey: .enableNATPMP) ?? enableNATPMP
        enableDHT = try values.decodeIfPresent(Bool.self, forKey: .enableDHT) ?? enableDHT
        enablePeX = try values.decodeIfPresent(Bool.self, forKey: .enablePeX) ?? enablePeX
        enableLSD = try values.decodeIfPresent(Bool.self, forKey: .enableLSD) ?? enableLSD
        transportMode = try values.decodeIfPresent(Int.self, forKey: .transportMode) ?? transportMode
        encryptionMode = try values.decodeIfPresent(Int.self, forKey: .encryptionMode) ?? encryptionMode
        maxConnections = try values.decodeIfPresent(Int.self, forKey: .maxConnections) ?? maxConnections
        maxConnectionsPerTorrent = try values.decodeIfPresent(Int.self, forKey: .maxConnectionsPerTorrent) ?? maxConnectionsPerTorrent
        uploadSlots = try values.decodeIfPresent(Int.self, forKey: .uploadSlots) ?? uploadSlots
        queueEnabled = try values.decodeIfPresent(Bool.self, forKey: .queueEnabled) ?? queueEnabled
        maxActiveDownloads = try values.decodeIfPresent(Int.self, forKey: .maxActiveDownloads) ?? maxActiveDownloads
        maxActiveUploads = try values.decodeIfPresent(Int.self, forKey: .maxActiveUploads) ?? maxActiveUploads
        maxActiveTorrents = try values.decodeIfPresent(Int.self, forKey: .maxActiveTorrents) ?? maxActiveTorrents
        seedRatioLimit = try values.decodeIfPresent(Double.self, forKey: .seedRatioLimit) ?? seedRatioLimit
        seedTimeLimitMinutes = try values.decodeIfPresent(Int.self, forKey: .seedTimeLimitMinutes) ?? seedTimeLimitMinutes
        proxyType = try values.decodeIfPresent(Int.self, forKey: .proxyType) ?? proxyType
        proxyHost = try values.decodeIfPresent(String.self, forKey: .proxyHost) ?? proxyHost
        proxyPort = try values.decodeIfPresent(Int.self, forKey: .proxyPort) ?? proxyPort
        proxyPeers = try values.decodeIfPresent(Bool.self, forKey: .proxyPeers) ?? proxyPeers
        proxyTrackers = try values.decodeIfPresent(Bool.self, forKey: .proxyTrackers) ?? proxyTrackers
        autoAddTrackers = try values.decodeIfPresent(Bool.self, forKey: .autoAddTrackers) ?? autoAddTrackers
        defaultTrackers = try values.decodeIfPresent(String.self, forKey: .defaultTrackers) ?? defaultTrackers
    }

    func validated() throws -> AppSettings {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw ClientError.message(message) }
        }
        try require(downloadPath.hasPrefix("/") && !downloadPath.contains("\0"), "请选择有效的绝对路径作为下载目录。")
        let maximumRate = Int(Int32.max) / 1024
        try require((0...maximumRate).contains(downloadLimitKB) && (0...maximumRate).contains(uploadLimitKB),
                    "速度上限必须在 0 至 \(maximumRate) KiB/s 之间，0 表示不限速。")
        try require((0...65535).contains(listenPort), "监听端口必须在 0 至 65535 之间，0 表示自动选择。")
        try require((0...2).contains(transportMode) && (0...2).contains(encryptionMode), "请选择有效的协议或加密模式。")
        for (label, value) in [("全局连接数", maxConnections), ("每任务连接数", maxConnectionsPerTorrent)] {
            try require(value == 0 || (2...Int(Int32.max)).contains(value), "\(label)必须为 0（不限）或至少 2。")
        }
        try require((0...Int(Int32.max)).contains(uploadSlots), "上传槽位必须为非负整数，0 表示不限。")
        for value in [maxActiveDownloads, maxActiveUploads, maxActiveTorrents] {
            try require((1...Int(Int32.max)).contains(value), "队列并发数量必须为正整数。")
        }
        try require(seedRatioLimit.isFinite && seedRatioLimit >= 0 && seedRatioLimit <= 10000, "分享率上限必须在 0 至 10000 之间，0 表示不限。")
        try require((0...(Int(Int32.max) / 60)).contains(seedTimeLimitMinutes), "做种时长必须为有效的非负分钟数，0 表示不限。")
        try require((0...2).contains(proxyType), "请选择有效的代理类型。")
        try require((0...65535).contains(proxyPort), "代理端口必须在 0 至 65535 之间。")
        if proxyType != 0 {
            let host = proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
            try require(!host.isEmpty && !host.contains("://") && !host.contains("/") && !host.contains("\0") && !host.contains(where: \.isWhitespace),
                        "代理服务器应为主机名或 IP 地址，不含协议前缀、路径或空格。")
            try require((1...65535).contains(proxyPort), "代理端口必须在 1 至 65535 之间。")
        }
        var trackers: [String] = []
        var seen = Set<String>()
        for (index, line) in defaultTrackers.components(separatedBy: .newlines).enumerated() {
            let tracker = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if tracker.isEmpty { continue }
            guard !tracker.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
                  let url = URLComponents(string: tracker), url.url != nil,
                  let scheme = url.scheme?.lowercased(), ["http", "https", "udp"].contains(scheme),
                  let host = url.host, !host.isEmpty,
                  url.port == nil || (1...65535).contains(url.port!) else {
                throw ClientError.message("第 \(index + 1) 行 Tracker 地址无效，请使用完整的 http、https 或 udp 地址和有效端口。")
            }
            if seen.insert(tracker).inserted { trackers.append(tracker) }
        }
        var normalized = self
        normalized.defaultTrackers = trackers.joined(separator: "\n")
        normalized.proxyHost = proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized
    }
}
