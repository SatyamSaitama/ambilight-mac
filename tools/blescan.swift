// blescan — lists nearby BLE peripherals, and with --connect <name> dumps the
// full GATT table (services, characteristics, properties) of a match.
//
// Used to identify a cheap BLE LED controller and find its write characteristic.

import Foundation
import CoreBluetooth

final class Scanner: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var seen = [UUID: String]()
    var target: String?
    var connected: CBPeripheral?

    init(target: String?) {
        self.target = target
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            print("scanning...")
            c.scanForPeripherals(withServices: nil,
                                 options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        case .unauthorized:
            print("!! Bluetooth permission denied for this process.")
            print("   System Settings > Privacy & Security > Bluetooth -> enable for this app.")
            exit(2)
        case .poweredOff:
            print("!! Bluetooth is off."); exit(3)
        case .unsupported:
            print("!! Bluetooth unsupported."); exit(4)
        default: break
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi RSSI: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "(no name)"
        guard seen[p.identifier] == nil else { return }
        seen[p.identifier] = name

        var line = String(format: "  %-26@  rssi=%4d", name as NSString, RSSI.intValue)
        if let svcs = ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], !svcs.isEmpty {
            line += "  svc=[" + svcs.map { $0.uuidString }.joined(separator: ",") + "]"
        }
        if let mfg = ad[CBAdvertisementDataManufacturerDataKey] as? Data {
            line += "  mfg=" + mfg.map { String(format: "%02X", $0) }.joined()
        }
        print(line); fflush(stdout)

        if let t = target, name.lowercased().contains(t.lowercased()) {
            print("\n>> connecting to \(name) [\(p.identifier)]")
            c.stopScan()
            connected = p
            p.delegate = self
            c.connect(p, options: nil)
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        print(">> connected, discovering services")
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        print(">> connect failed: \(error?.localizedDescription ?? "unknown")"); exit(5)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svcs = p.services else { return }
        for s in svcs {
            print("\nSERVICE \(s.uuid.uuidString)")
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let chars = s.characteristics else { return }
        for c in chars {
            var props: [String] = []
            let r = c.properties
            if r.contains(.read)                 { props.append("read") }
            if r.contains(.write)                { props.append("write") }
            if r.contains(.writeWithoutResponse) { props.append("writeNoResp") }
            if r.contains(.notify)               { props.append("notify") }
            if r.contains(.indicate)             { props.append("indicate") }
            print("  CHAR \(c.uuid.uuidString)  [\(props.joined(separator: ","))]")
        }
        fflush(stdout)
    }
}

var target: String?
var secs = 12.0
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--connect": target = it.next()
    case "--seconds": secs = Double(it.next() ?? "12") ?? 12
    case "-h", "--help":
        print("blescan [--seconds N] [--connect <name-substring>]")
        exit(0)
    default: break
    }
}

let s = Scanner(target: target)
RunLoop.main.run(until: Date().addingTimeInterval(secs))
print("\n-- \(s.seen.count) devices seen --")
