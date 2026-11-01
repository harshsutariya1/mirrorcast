import Foundation

/// A phone this Mac has paired with.
struct TrustedDevice: Codable, Equatable {
    let fingerprint: String
    var name: String
    var model: String
    let pairedAt: Date
    var lastSeenAt: Date?

    var asMap: [String: Any] {
        var map: [String: Any] = [
            "fingerprint": fingerprint,
            "name": name,
            "model": model,
            "pairedAt": Int64(pairedAt.timeIntervalSince1970 * 1000),
        ]
        if let lastSeenAt { map["lastSeenAt"] = Int64(lastSeenAt.timeIntervalSince1970 * 1000) }
        return map
    }
}

/// The list of trusted phones, stored as JSON in the app's sandbox container.
///
/// Only public information is stored here (certificate fingerprints and
/// names), so a plain file is enough. Removing an entry revokes that phone:
/// it can no longer connect until it pairs again.
final class TrustedDeviceStore {
    private let fileURL: URL
    private let lock = NSLock()
    private var devices: [String: TrustedDevice] = [:]

    init(storageDirectory: URL) {
        fileURL = storageDirectory.appendingPathComponent("trusted-phones.json")
        load()
    }

    func device(for fingerprint: String) -> TrustedDevice? {
        lock.lock()
        defer { lock.unlock() }
        return devices[fingerprint]
    }

    func isTrusted(_ fingerprint: String) -> Bool { device(for: fingerprint) != nil }

    func all() -> [TrustedDevice] {
        lock.lock()
        defer { lock.unlock() }
        return devices.values.sorted { $0.pairedAt > $1.pairedAt }
    }

    func trust(fingerprint: String, name: String, model: String) {
        lock.lock()
        let existing = devices[fingerprint]
        devices[fingerprint] = TrustedDevice(
            fingerprint: fingerprint,
            name: name,
            model: model,
            pairedAt: existing?.pairedAt ?? Date(),
            lastSeenAt: Date()
        )
        lock.unlock()
        save()
    }

    func markSeen(_ fingerprint: String, name: String, model: String) {
        lock.lock()
        guard var device = devices[fingerprint] else {
            lock.unlock()
            return
        }
        device.lastSeenAt = Date()
        device.name = name
        if !model.isEmpty { device.model = model }
        devices[fingerprint] = device
        lock.unlock()
        save()
    }

    @discardableResult
    func revoke(_ fingerprint: String) -> Bool {
        lock.lock()
        let removed = devices.removeValue(forKey: fingerprint) != nil
        lock.unlock()
        if removed { save() }
        return removed
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let list = try? decoder.decode([TrustedDevice].self, from: data) else {
            NSLog("MirrorCast: trusted-phones.json is unreadable; starting with an empty list")
            return
        }
        devices = Dictionary(list.map { ($0.fingerprint, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func save() {
        lock.lock()
        let list = Array(devices.values)
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try encoder.encode(list).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("MirrorCast: failed to save trusted phones: \(error)")
        }
    }
}
