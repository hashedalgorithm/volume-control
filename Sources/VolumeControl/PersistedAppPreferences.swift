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

/// Output tab: per-app extra gain on top of the normal 0-100% volume slider, to make up
/// for Core Audio's own process-tap mixdown applying its own (undocumented, not
/// something we can disable) loudness compensation -- see ProcessAudioRoute's header
/// comment. `.off` applies no extra gain; `.auto` continuously measures the captured
/// signal and compensates on its own; `.preset`/`.custom` apply a fixed extra
/// percentage (`percent`), unused by `.auto`.
enum BoostMode: String, Codable {
    case off, auto, preset, custom
}

/// Preset extra-gain percentages offered in the boost dropdown.
enum BoostPreset: Double, CaseIterable, Identifiable {
    case low = 20
    case medium = 40
    case high = 60
    case veryHigh = 70
    case extreme = 80
    case maximum = 100

    var id: Double { rawValue }
    var label: String { "+\(Int(rawValue))% (\(name))" }
    private var name: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .veryHigh: return "Very High"
        case .extreme: return "Extreme"
        case .maximum: return "Maximum"
        }
    }
}

struct AppBoostPreference: Codable, Equatable {
    var mode: BoostMode = .off
    /// Extra gain percentage for `.preset` (one of BoostPreset's raw values) and
    /// `.custom` (10.00...100.00, at most 2 decimal places) -- ignored for `.off`/`.auto`.
    var percent: Double = BoostPreset.low.rawValue
}
