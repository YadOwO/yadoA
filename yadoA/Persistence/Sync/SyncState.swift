import Foundation

/// 本机的云端同步状态，保存在 UserDefaults 中。
///
/// 不放进 SwiftData：清空本地数据时需要单独决定是否保留它（例如「仅清空本机」要先解除绑定）。
struct SyncState: Codable, Equatable {
    /// UserDefaults 中的存储键。
    static let storageKey = "sync.state"

    /// 本机数据归属的登录用户；为空表示从未绑定。绑定后本地删除需要保留墓碑等待上传。
    var boundUserID: String?

    /// 用户是否开启了同步；关闭后台账照常记录，只是不上传也不拉取。
    var isEnabled = false

    /// 已拉取到的服务端序号，下一次只拉取比它大的变化。
    var since: Int64 = 0

    /// 服务端数据代次；删除云端数据后加 1，不一致时暂停同步。
    var epoch = 0

    /// 本机的稳定设备标识，服务端据此记录每台设备的拉取进度。
    var deviceID = UUID()

    /// 本机已完成全量同步时的同步格式版本；低于当前版本时重新全量拉取。
    var syncSchemaVersion = 0

    /// 最近一次成功同步的时间。
    var lastSyncedAt: Date?

    /// 本机数据是否已绑定到某个登录用户。
    var isBound: Bool { boundUserID != nil }

    /// 读取同步状态；首次读取时生成设备标识并立即保存，保证之后保持不变。
    ///
    /// - Parameter defaults: 存储同步状态的 UserDefaults。
    /// - Returns: 已保存的状态，或新生成并保存的默认状态。
    static func load(from defaults: UserDefaults = .standard) -> SyncState {
        if let data = defaults.data(forKey: storageKey),
           let state = try? JSONDecoder().decode(SyncState.self, from: data) {
            return state
        }
        let state = SyncState()
        state.save(to: defaults)
        return state
    }

    /// 保存同步状态。
    ///
    /// - Parameter defaults: 存储同步状态的 UserDefaults。
    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
