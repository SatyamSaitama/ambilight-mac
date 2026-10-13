import Foundation
import CoreBluetooth
import AppKit

struct OutputStatus {
    var state: String
    var detail: String = ""
    var writesPerSecond: Double = 0
    var deviceID: UUID? = nil
    var connected: Bool = false
}

struct DiscoveredLight {
    let id: UUID
    let name: String
    let rssi: Int
}

/// Passive discovery only: selecting an entry is what authorizes a connection.
final class BLEDiscovery: NSObject, CBCentralManagerDelegate {
    var onDevices: (([DiscoveredLight]) -> Void)?
    private var central: CBCentralManager?
    private var devices: [UUID: DiscoveredLight] = [:]
    private var active = false
    func start() {
        stop(); devices = [:]; active = true
        onDevices?([])
        central = CBCentralManager(delegate: self, queue: .main)
    }
    func stop() { active = false; central?.stopScan(); central?.delegate = nil; central = nil }
    deinit { central?.stopScan() }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if active && central.state == .poweredOn { central.scanForPeripherals(withServices: nil) }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard active else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let service = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.contains(CBUUID(string: "FFF0")) ?? false
        guard service || name.uppercased().contains("MELK") || name.uppercased().contains("ELK") else { return }
        devices[peripheral.identifier] = DiscoveredLight(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        onDevices?(devices.values.sorted { $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name })
    }
}

protocol ColorSink: AnyObject {
    func send(_ colors: [UInt8])
    func suspend()
    func resume()
    func stop()
    func shutdown(completion: @escaping () -> Void)
}
extension ColorSink {
    func suspend() {}
    func resume() {}
    func stop() {}
    func shutdown(completion: @escaping () -> Void) {
        suspend()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.stop(); completion() }
    }
}

final class WLEDSender: ColorSink {
    private var fd: Int32
    private var addr: sockaddr_in
    private let ledCount: Int
    private let lock = NSLock()
    private var suspended = false
    private var stopped = false
    private var writes = 0
    private var reportAt = ProcessInfo.processInfo.systemUptime
    private let onStatus: ((OutputStatus) -> Void)?
    private var heartbeat: Timer?
    private var latest: [UInt8]?

    init?(host: String, port: UInt16, ledCount: Int, onStatus: ((OutputStatus) -> Void)? = nil) {
        guard (1...490).contains(ledCount) else { return nil }
        let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketFD >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        if inet_pton(AF_INET, host, &address.sin_addr) != 1 {
            var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_DGRAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { close(socketFD); return nil }
            defer { freeaddrinfo(first) }
            guard let sa = first.pointee.ai_addr else { close(socketFD); return nil }
            address.sin_addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        }
        self.fd = socketFD; self.addr = address; self.ledCount = ledCount; self.onStatus = onStatus
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard !self.stopped, !self.suspended, let colors = self.latest else { return }
            self.write(colors)
        }
        heartbeat = timer; RunLoop.main.add(timer, forMode: .common)
        emit(OutputStatus(state: "UDP ready", detail: "\(host):\(port) · delivery is not acknowledged"))
    }
    deinit { heartbeat?.invalidate(); if fd >= 0 { close(fd) } }
    private func emit(_ status: OutputStatus) { DispatchQueue.main.async { [onStatus] in onStatus?(status) } }
    private func write(_ colors: [UInt8], timeout: UInt8 = 2) {
        let packet: [UInt8] = [2, timeout] + colors
        let result = withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                packet.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        if result >= 0 { writes += 1 }
        let now = ProcessInfo.processInfo.systemUptime
        if now - reportAt >= 1 {
            let rate = Double(writes) / (now - reportAt)
            emit(OutputStatus(state: result >= 0 ? "UDP streaming" : "UDP send failed",
                              detail: result >= 0 ? "\(ledCount) pixels · UDP delivery unconfirmed" : String(cString: strerror(errno)),
                              writesPerSecond: rate))
            writes = 0; reportAt = now
        }
    }
    func send(_ colors: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, !suspended, colors.count == ledCount * 3 else { return }
        latest = colors; write(colors)
    }
    func suspend() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }; suspended = true
        write([UInt8](repeating: 0, count: ledCount * 3), timeout: 255)
    }
    func resume() { lock.lock(); if !stopped { suspended = false }; lock.unlock() }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }; stopped = true
        heartbeat?.invalidate(); heartbeat = nil
        close(fd); fd = -1
    }
}

/// Only the verified whole-controller E1 colour command is implemented.
/// Arbitrary bar/segment selection on a shared MELK controller is unverified.
final class BLESender: NSObject, ColorSink, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let serviceUUID = CBUUID(string: "FFF0")
    private let writeUUID = CBUUID(string: "FFF3")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private let nameFilter: String
    private var deviceID: UUID?
    private let minInterval: Double
    private let deadband: Int
    private var pending: [UInt8]?
    private var lastSent: [UInt8]?
    private var lastWrite = -Double.infinity
    private var suspended = false
    private var stopped = false
    private var timer: Timer?
    private var reportAt = ProcessInfo.processInfo.systemUptime
    private var writes = 0
    private var status = OutputStatus(state: "Waiting for Bluetooth")
    private var retry: DispatchWorkItem?
    private let oneShot: [Data]
    private var shotIndex = 0
    private var nextShotAt = 0.0
    private var shotCompletionAt: Double?
    private var needsPower = true
    /// The lamp's own BRIGHTNESS, sent after power-on and after every wake, when
    /// master dimming is done by the controller rather than in software.
    private let hardwareLevel: UInt8?
    private var needsLevel = true
    private var needsBlackout = false
    var stepDelay = 0.15
    var onOneShotComplete: (() -> Void)?
    var onStatus: ((OutputStatus) -> Void)?
    var onIdentified: ((UUID) -> Void)?
    var isReady: Bool { characteristic != nil && !stopped }

    init(nameFilter: String, rate: Double, deadband: Int, oneShot: [Data] = [],
         deviceID: UUID? = nil, hardwareLevel: UInt8? = nil,
         onStatus: ((OutputStatus) -> Void)? = nil,
         onIdentified: ((UUID) -> Void)? = nil) {
        self.nameFilter = nameFilter; self.minInterval = 1 / max(1, rate); self.deadband = deadband
        self.hardwareLevel = hardwareLevel
        self.oneShot = oneShot; self.deviceID = deviceID; self.onStatus = onStatus; self.onIdentified = onIdentified
        super.init()
        // All BLE state and callbacks are serialized on the main queue.
        central = CBCentralManager(delegate: self, queue: .main)
        let pacing = Timer(timeInterval: min(0.05, minInterval), repeats: true) { [weak self] _ in self?.tick() }
        timer = pacing; RunLoop.main.add(pacing, forMode: .common)
    }
    deinit { timer?.invalidate(); retry?.cancel() }
    private func report(_ state: String, detail: String = "", connected: Bool = false) {
        status.state = state; status.detail = detail; status.connected = connected; status.deviceID = deviceID
        onStatus?(status)
    }
    func send(_ colors: [UInt8]) {
        guard colors.count == 3 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped, !self.suspended else { return }
            self.pending = colors
            self.tick()
        }
    }
    private func frame(_ colors: [UInt8]) -> Data { Data([0x7E,0x07,0x05,0x03] + colors + [0x10,0xEF]) }
    private let powerOn = Data([0x7E,0x07,0x04,0xFF,0x01,0x01,0x02,0x01,0xEF])
    private let powerOff = Data([0x7E,0x07,0x04,0x00,0x01,0x00,0x02,0x01,0xEF])
    /// BRIGHTNESS uses a len byte of 4, not 7.
    private func levelFrame(_ v: UInt8) -> Data { Data([0x7E,0x04,0x01,v,0xFF,0xFF,0xFF,0x00,0xEF]) }
    private func tick() {
        guard !stopped else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - reportAt >= 1 {
            status.writesPerSecond = Double(writes) / (now - reportAt)
            onStatus?(status); writes = 0; reportAt = now
        }
        guard let p = peripheral, let ch = characteristic, p.canSendWriteWithoutResponse else { return }
        if suspended {
            if needsBlackout {
                // Hand the lamp back at full brightness, so the remote and the
                // phone app are not left stuck at our dimmed level.
                if hardwareLevel != nil { p.writeValue(levelFrame(255), for: ch, type: .withoutResponse) }
                p.writeValue(powerOff, for: ch, type: .withoutResponse); needsBlackout = false
            }
            return
        }
        if !oneShot.isEmpty {
            if let completeAt = shotCompletionAt, now >= completeAt {
                shotCompletionAt = nil
                let done = onOneShotComplete; onOneShotComplete = nil; done?()
                return
            }
            guard shotIndex < oneShot.count, now >= nextShotAt else { return }
            p.writeValue(oneShot[shotIndex], for: ch, type: .withoutResponse)
            writes += 1; shotIndex += 1; nextShotAt = now + max(0.05, stepDelay)
            if shotIndex == oneShot.count { shotCompletionAt = now + max(0.15, stepDelay) }
            return
        }
        if needsPower {
            p.writeValue(powerOn, for: ch, type: .withoutResponse)
            needsPower = false; lastWrite = now
            return
        }
        if needsLevel, let level = hardwareLevel {
            p.writeValue(levelFrame(level), for: ch, type: .withoutResponse)
            needsLevel = false; lastWrite = now
            return
        }
        guard let colors = pending, now - lastWrite >= minInterval else { return }
        if let last = lastSent {
            let delta = zip(colors, last).map { abs(Int($0) - Int($1)) }.max() ?? 0
            // Always deliver complete black, even when it falls inside the deadband.
            if delta == 0 || (delta < deadband && colors.contains(where: { $0 > 0 }) && now - lastWrite < 1) { return }
        }
        p.writeValue(frame(colors), for: ch, type: .withoutResponse)
        lastSent = colors; lastWrite = now; writes += 1
    }
    func suspend() {
        guard !stopped else { return }
        suspended = true; pending = nil; needsBlackout = true
        tick()
        report("Lights off", detail: "Output paused", connected: characteristic != nil)
    }
    func resume() {
        guard !stopped else { return }
        suspended = false; needsBlackout = false; lastSent = nil; needsPower = true; needsLevel = true
        report(characteristic == nil ? "Reconnecting" : "Connected", detail: peripheral?.name ?? nameFilter, connected: characteristic != nil)
        tick()
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        timer?.invalidate(); timer = nil; retry?.cancel(); retry = nil
        central.stopScan()
        if let p = peripheral { p.delegate = nil; central.cancelPeripheralConnection(p) }
        central.delegate = nil; peripheral = nil; characteristic = nil
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !stopped else { return }
        switch central.state {
        case .poweredOn:
            if let id = deviceID, let p = central.retrievePeripherals(withIdentifiers: [id]).first { connect(p) }
            else { report("Scanning", detail: deviceID?.uuidString ?? nameFilter); central.scanForPeripherals(withServices: nil) }
        case .unauthorized: report("Bluetooth permission needed", detail: "Allow Ambilight in Privacy & Security → Bluetooth")
        case .poweredOff: characteristic = nil; report("Bluetooth is off", detail: "Turn Bluetooth on to reconnect")
        case .unsupported: report("Bluetooth unavailable")
        default: characteristic = nil; report("Waiting for Bluetooth")
        }
    }
    private func connect(_ p: CBPeripheral) {
        guard !stopped else { return }
        central.stopScan(); peripheral = p; p.delegate = self
        deviceID = p.identifier; onIdentified?(p.identifier)
        report("Connecting", detail: p.name ?? p.identifier.uuidString)
        central.connect(p)
    }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi RSSI: NSNumber) {
        guard !stopped, peripheral == nil else { return }
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let matches = deviceID.map { $0 == p.identifier } ?? (!nameFilter.isEmpty && name.lowercased().contains(nameFilter.lowercased()))
        if matches { connect(p) }
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard !stopped else { return }
        report("Checking controller", detail: p.name ?? "FFF0")
        p.discoverServices([serviceUUID])
    }
    private func reconnect(_ p: CBPeripheral, error: Error?) {
        guard !stopped else { return }
        characteristic = nil; lastSent = nil; needsPower = true
        report("Reconnecting", detail: error?.localizedDescription ?? "Connection interrupted")
        retry?.cancel()
        let work = DispatchWorkItem { [weak self, weak p] in
            guard let self, let p, !self.stopped, self.central.state == .poweredOn else { return }
            self.central.connect(p)
        }
        retry = work; DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { reconnect(p, error: error) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { reconnect(p, error: error) }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard !stopped else { return }
        guard error == nil, let service = p.services?.first(where: { $0.uuid == serviceUUID }) else {
            report("Unsupported controller", detail: error?.localizedDescription ?? "Service FFF0 was not found"); return
        }
        p.discoverCharacteristics([writeUUID], for: service)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard !stopped else { return }
        guard error == nil, let ch = service.characteristics?.first(where: { $0.uuid == writeUUID && $0.properties.contains(.writeWithoutResponse) }) else {
            report("Unsupported controller", detail: error?.localizedDescription ?? "Writable FFF3 was not found"); return
        }
        characteristic = ch; lastSent = nil; needsPower = true
        if suspended { needsBlackout = true }
        nextShotAt = ProcessInfo.processInfo.systemUptime + max(0.05, stepDelay)
        report(suspended ? "Lights off" : "Connected", detail: "\(p.name ?? nameFilter) · \(p.identifier.uuidString)", connected: true)
        tick()
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { tick() }
}

final class DualBLESender: ColorSink {
    private let left: BLESender
    private let right: BLESender
    init(left: BLESender, right: BLESender) { self.left = left; self.right = right }
    func send(_ colors: [UInt8]) {
        guard colors.count == 6 else { return }
        left.send(Array(colors[0..<3])); right.send(Array(colors[3..<6]))
    }
    func suspend() { left.suspend(); right.suspend() }
    func resume() { left.resume(); right.resume() }
    func stop() { left.stop(); right.stop() }
}

func makeColorSink(_ cfg: Config, onStatus: ((OutputStatus) -> Void)? = nil,
                   onIdentified: ((UUID) -> Void)? = nil) throws -> ColorSink {
    let cfg = try validatedConfig(cfg)
    if let name = cfg.bleName {
        if let rightID = cfg.bleRightID {
            // Status is combined so a missing right controller cannot appear healthy.
            var statuses = [OutputStatus(state: "Connecting"), OutputStatus(state: "Connecting")]
            func update(_ side: Int, _ status: OutputStatus) {
                statuses[side] = status
                onStatus?(OutputStatus(state: statuses.allSatisfy { $0.connected } ? "Both bars connected" : "Connecting bars",
                                       detail: "Left: \(statuses[0].state) · Right: \(statuses[1].state)",
                                       writesPerSecond: statuses.reduce(0) { $0 + $1.writesPerSecond },
                                       connected: statuses.allSatisfy { $0.connected }))
            }
            let level: UInt8? = cfg.hardwareBrightness ? UInt8((max(0, min(1, cfg.brightness)) * 255).rounded()) : nil
            let left = BLESender(nameFilter: name, rate: cfg.bleRate, deadband: cfg.bleDeadband, deviceID: cfg.bleID,
                                 hardwareLevel: level, onStatus: { update(0, $0) }, onIdentified: onIdentified)
            let right = BLESender(nameFilter: name, rate: cfg.bleRate, deadband: cfg.bleDeadband, deviceID: rightID,
                                  hardwareLevel: level, onStatus: { update(1, $0) })
            return DualBLESender(left: left, right: right)
        }
        return BLESender(nameFilter: name, rate: cfg.bleRate, deadband: cfg.bleDeadband,
                         deviceID: cfg.bleID, hardwareLevel: cfg.hardwareBrightness ? UInt8((max(0, min(1, cfg.brightness)) * 255).rounded()) : nil,
                         onStatus: onStatus, onIdentified: onIdentified)
    }
    guard let sink = WLEDSender(host: cfg.host, port: cfg.port, ledCount: cfg.ledCount, onStatus: onStatus) else {
        throw ConfigurationError("Could not resolve or open WLED target \(cfg.host)")
    }
    return sink
}
