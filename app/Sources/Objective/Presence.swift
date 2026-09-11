import AppKit
import CoreAudio
import CoreGraphics
import Darwin
import Foundation
import IOKit

// Whether you sit at the Mac.
//
// Agents reach you in one of two ways: the overlay while you are here, and
// Telegram while you are not. The Mac cannot see you, so the app reads what you
// do: real keys and mouse moves, the screen lock, the lid, your iPhone, a call.
// It writes one reading to presence.json next to the board, and every MCP
// server reads that same file.

enum PresenceState: String, Codable {
    case present, unsure, away
}

// A choice from the menu, above every signal. "Here" lasts one hour, or until
// you lock the screen. "Away" lasts until you come back.
struct PresenceOverride: Codable, Equatable {
    enum Kind: String, Codable { case here, away }
    var kind: Kind
    var since: Double
    var until: Double?
}

// One reading of every signal. The rules read only this, so they are tested
// without a real keyboard, lid, or phone.
struct PresenceSignals {
    var now: Double
    var lastInput: Double?
    var locked = false
    var lidClosedWithoutDisplay = false
    var phoneMissingSince: Double?
    var callActive = false
    var override: PresenceOverride?
}

struct PresenceReading: Equatable {
    var state: PresenceState
    var reason: String
}

// A state that has ended, so the menu can show what the app saw while you
// were gone. Opening the menu is itself input, so the current state alone
// always says you are here.
struct PresenceSpan {
    var state: PresenceState
    var reason: String
    var duration: TimeInterval
}

enum PresenceRules {
    // Input this recent means you are at the Mac.
    static let presentWindow: TimeInterval = 90
    // No input for this long means you left, even with the screen unlocked.
    static let idleAway: TimeInterval = 15 * 60
    // An iPhone out of range this long went with you.
    static let phoneAway: TimeInterval = 3 * 60

    static func evaluate(_ signals: PresenceSignals) -> PresenceReading {
        let now = signals.now
        if let choice = signals.override, choice.until.map({ now < $0 }) ?? true {
            return choice.kind == .here
                ? PresenceReading(state: .present, reason: "you chose here")
                : PresenceReading(state: .away, reason: "you chose away")
        }
        if signals.lidClosedWithoutDisplay {
            return PresenceReading(state: .away, reason: "lid closed with no external display")
        }
        let idle = signals.lastInput.map { now - $0 }
        // A lock is the usual way to leave, so input from before it proves nothing.
        if !signals.locked {
            if let idle, idle < presentWindow {
                return PresenceReading(state: .present, reason: "recent input")
            }
            if signals.callActive {
                return PresenceReading(state: .present, reason: "call active")
            }
        }
        if let gone = signals.phoneMissingSince, now - gone >= phoneAway {
            return PresenceReading(state: .away, reason: "iPhone out of range")
        }
        guard let idle, idle < idleAway else {
            return PresenceReading(state: .away, reason: "no input for 15 minutes")
        }
        return PresenceReading(state: .unsure, reason: signals.locked ? "screen locked" : "no recent input")
    }
}

// What the MCP servers read. `pid` lets them tell a live reading from the file
// of an app that has quit.
struct PresenceFile: Codable, Equatable {
    var state: PresenceState
    var reason: String
    var since: Double
    var locked: Bool
    var override: PresenceOverride.Kind?
    var realInput: Bool
    var pid: Int32
}

@MainActor
final class Presence {
    static let shared = Presence()

    // Drivers that send your real input again from their own process. Logi
    // Options+ does it for every scroll of an MX mouse.
    private static let inputDrivers: Set<String> = ["logioptionsplus_agent", "LogiMgrDaemon"]
    private static let anyInput = CGEventType(rawValue: ~0)!

    private(set) var reading = PresenceReading(state: .unsure, reason: "starting")
    private(set) var since = Date().timeIntervalSince1970
    private(set) var previous: PresenceSpan?
    private(set) var override: PresenceOverride? {
        didSet { saveOverride() }
    }

    // Without Input Monitoring the app sees only the system idle timer, and
    // fake input from computer use moves that timer too.
    var seesRealInput: Bool { tap != nil }

    private var started = false
    private var lastInput: Double?
    private var locked = false
    private var phoneSeen = false
    private var phoneMissingSince: Double?
    private var tap: CFMachPort?
    private var driverPIDs: [pid_t: Bool] = [:]
    private var lastRefresh: Double = 0
    private var written: PresenceFile?
    private var timers: [Timer] = []

    private let overrideKey = "presenceOverride"
    private var file: URL { StatePaths.directory.appendingPathComponent("presence.json") }

    func start() {
        override = loadOverride()
        locked = Self.screenIsLocked()
        lastInput = Self.idleTimerInput()
        if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
        }
        installTap()
        observeSession()
        timers = [
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                MainActor.assumeIsolated {
                    Presence.shared.setLocked(Self.screenIsLocked())
                    Presence.shared.refresh()
                }
            },
            Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                MainActor.assumeIsolated { Presence.shared.scanPhone() }
            },
        ]
        scanPhone()
        refresh()
    }

    func choose(_ kind: PresenceOverride.Kind?) {
        let now = Date().timeIntervalSince1970
        switch kind {
        case .here?: override = PresenceOverride(kind: .here, since: now, until: now + 3600)
        case .away?: override = PresenceOverride(kind: .away, since: now, until: nil)
        case nil: override = nil
        }
        refresh()
    }

    func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }

    func refresh() {
        let now = Date().timeIntervalSince1970
        lastRefresh = now
        if tap == nil {
            installTap()
            if tap == nil { lastInput = Self.idleTimerInput() }
        }
        if let until = override?.until, now >= until {
            override = nil
        }

        let next = PresenceRules.evaluate(PresenceSignals(
            now: now,
            lastInput: lastInput,
            locked: locked,
            lidClosedWithoutDisplay: Self.lidClosedWithoutDisplay(),
            phoneMissingSince: phoneMissingSince,
            callActive: Self.callActive(),
            override: override
        ))
        if next.state != reading.state {
            if started {
                previous = PresenceSpan(state: reading.state, reason: reading.reason, duration: now - since)
            }
            since = now
        }
        started = true
        reading = next
        write()
    }

    // MARK: - Input

    fileprivate func sawInput(from pid: pid_t) {
        guard pid == 0 || isInputDriver(pid) else { return }
        let now = Date().timeIntervalSince1970
        lastInput = now
        // The clicks that chose "away" in the menu must not end it at once.
        if let choice = override, choice.kind == .away, now - choice.since > 60 {
            override = nil
        }
        // Mouse moves arrive many times a second. Only a change of state is urgent.
        if reading.state != .present || override != nil, !locked, now - lastRefresh > 0.5 {
            refresh()
        }
    }

    fileprivate func enableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func installTap() {
        guard tap == nil, CGPreflightListenEventAccess() else { return }
        let types: [CGEventType] = [
            .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: presenceTapCallback,
            userInfo: nil
        ) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
    }

    private func isInputDriver(_ pid: pid_t) -> Bool {
        if let known = driverPIDs[pid] { return known }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let name = length > 0 ? URL(fileURLWithPath: String(cString: buffer)).lastPathComponent : ""
        let driver = Self.inputDrivers.contains(name)
        driverPIDs[pid] = driver
        return driver
    }

    private static func idleTimerInput() -> Double {
        Date().timeIntervalSince1970 - CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }

    // MARK: - Screen lock

    private func observeSession() {
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                Presence.shared.setLocked(true)
                Presence.shared.refresh()
            }
        }
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                Presence.shared.setLocked(false)
                Presence.shared.refresh()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Presence.shared.refresh() }
        }
    }

    private func setLocked(_ value: Bool) {
        guard value != locked else { return }
        locked = value
        if value {
            // "Here" was about this sitting. A lock ends it.
            if override?.kind == .here { override = nil }
        } else {
            // Only a person unlocks: Touch ID, a password, or a watch on the wrist.
            lastInput = Date().timeIntervalSince1970
            if override?.kind == .away { override = nil }
        }
    }

    private static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // MARK: - Lid, call, and phone

    private static func lidClosedWithoutDisplay() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let closed = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool ?? false
        guard closed else { return false }
        let external = NSScreen.screens.contains { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) == 0
        }
        return !external
    }

    // A call keeps you at the Mac without a key press. This asks Core Audio
    // which apps record now. Nothing here opens the microphone.
    private static func callActive() -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return false }

        return processes.contains { process in
            var running = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var value: UInt32 = 0
            var valueSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(process, &running, 0, nil, &valueSize, &value) == noErr else { return false }
            return value != 0
        }
    }

    // A phone that left the room is a strong sign that you left with it. A
    // phone that stays says nothing, because you may leave it on the desk.
    private func scanPhone() {
        driverPIDs.removeAll()
        DispatchQueue.global(qos: .utility).async {
            let near = Self.phoneInRange()
            DispatchQueue.main.async {
                Presence.shared.phoneScanned(near)
            }
        }
    }

    private func phoneScanned(_ near: Bool?) {
        switch near {
        case true?:
            phoneSeen = true
            phoneMissingSince = nil
        case false? where phoneSeen && phoneMissingSince == nil:
            phoneMissingSince = Date().timeIntervalSince1970
        default:
            break
        }
    }

    // nil when no iPhone is paired, so there is nothing to learn from it.
    nonisolated private static func phoneInRange() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return nil }
        var paired = false
        for controller in controllers {
            for key in ["device_connected", "device_not_connected"] {
                for entry in controller[key] as? [[String: Any]] ?? [] {
                    for (name, info) in entry where name.localizedCaseInsensitiveContains("iphone") {
                        paired = true
                        // A signal level shows only while the phone is in range.
                        if (info as? [String: Any])?["device_rssi"] != nil { return true }
                    }
                }
            }
        }
        return paired ? false : nil
    }

    // MARK: - Files

    private func write() {
        let snapshot = PresenceFile(
            state: reading.state,
            reason: reading.reason,
            since: since,
            locked: locked,
            override: override?.kind,
            realInput: tap != nil,
            pid: getpid()
        )
        guard snapshot != written, let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try FileManager.default.createDirectory(at: StatePaths.directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            written = snapshot
        } catch {
            // The next refresh tries again.
        }
    }

    private func loadOverride() -> PresenceOverride? {
        guard let data = UserDefaults.standard.data(forKey: overrideKey) else { return nil }
        return try? JSONDecoder().decode(PresenceOverride.self, from: data)
    }

    private func saveOverride() {
        if let override, let data = try? JSONEncoder().encode(override) {
            UserDefaults.standard.set(data, forKey: overrideKey)
        } else {
            UserDefaults.standard.removeObject(forKey: overrideKey)
        }
    }
}

// A C callback cannot capture anything, so it reaches the one monitor through
// `shared`. The tap runs on the main run loop.
private func presenceTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let pid = pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventSourceUnixProcessID))
    MainActor.assumeIsolated {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Presence.shared.enableTap()
        } else {
            Presence.shared.sawInput(from: pid)
        }
    }
    return Unmanaged.passUnretained(event)
}
