import Foundation

/// Per-app preferences keyed by bundle ID (stable across app/system restarts) rather
/// than pid (a new random number every time a process launches), backed by
/// UserDefaults as JSON. Used for both the Output tab (per-app volume/mute/output
/// device) and the Input tab (per-app mic-mix inclusion/volume) -- same shape of
/// problem, different value type.
final class PersistedStore<Value: Codable> {
    private let defaultsKey: String
    private let defaultValue: Value
    private var storage: [String: Value]

    init(defaultsKey: String, defaultValue: Value) {
        self.defaultsKey = defaultsKey
        self.defaultValue = defaultValue
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Value].self, from: data) {
            storage = decoded
        } else {
            storage = [:]
        }
    }

    func get(_ bundleID: String) -> Value {
        storage[bundleID] ?? defaultValue
    }

    func set(_ value: Value, for bundleID: String) {
        storage[bundleID] = value
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

/// Output tab: per-app volume, mute, and chosen output device.
struct AppOutputPreference: Codable {
    var volume: Float = 1.0
    var isMuted: Bool = false
    var outputDeviceUID: String?
}

/// Input tab: whether an app is included in the mic mix, and its mix volume.
struct AppMixPreference: Codable {
    var isIncluded: Bool = false
    var mixVolume: Float = 1.0
}
