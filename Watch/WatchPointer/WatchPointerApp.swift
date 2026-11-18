import CoreBluetooth
import CoreMotion
import SwiftUI
import WatchKit

// Must match the Mac receiver.
let serviceUUID = CBUUID(string: "6B1E0001-9F4C-4C2A-9B8E-3D2A1C0F5E01")
let inputUUID = CBUUID(string: "6B1E0002-9F4C-4C2A-9B8E-3D2A1C0F5E01")
/// Subscribing to this tells the Mac the moment the watch connects or disconnects. (It sends nothing back.)
let outputUUID = CBUUID(string: "6B1E0003-9F4C-4C2A-9B8E-3D2A1C0F5E01")

@main
struct WatchPointerApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

/// Packets: [kind, Int16 LE a, Int16 LE b].
/// `.aim`: where the watch's pointing edge points (12, 3, 6 or 9 o'clock, picked on the watch; the Mac needn't know
/// which), relative to "Center", in hundredths of a degree
/// (a = turned left, b = tipped up), then UInt16 LE: when it was measured, in ms on the watch's clock (wraps).
/// The Mac smooths with those times; Bluetooth delivers samples in bursts, so arrival times are useless.
/// `.pause`: a = 1 paused, 0 resumed.
/// `.info`: [kind, JSON] with the watch's model id, watchOS, battery and name (not the fixed 5 bytes).
/// `.drag`: a = 1 grab (mouse down), 0 drop (mouse up).
/// Clicks and drags may add the same UInt16 ms time as `.aim`: when the thumb touched down (or lifted, for a drop).
/// A `.leftClick` with b = 1 comes from the Double Tap gesture: the Mac then holds the pointer still for a moment.
/// `.settings`: the Speed and Steady sliders. a = speed ×100, b = steadiness ×100 (1.0× = 100). They scale the values
/// the Mac was started with.
enum Kind: UInt8 { case aim = 0, leftClick = 1, rightClick = 2, scroll = 3, center = 4, pause = 5, info = 6, drag = 7, settings = 8 }

/// How long you hold the screen before it grabs. The Mac uses the same number to undo the press's jolt.
let holdToDrag = 0.35

/// Mac scroll distance, in pixels, per unit of Crown turn, when Scroll is 1× in the settings. A turn of the Crown is a
/// lot of these units, which is why this is small. (1× is 20 times slower than the 8 it was; Scroll 20× is that again.)
private let crownPixels = 0.4

/// The fastest the Mac ever scrolls, in pixels a second, when Scroll is 1× (it scales with Scroll). Without a ceiling,
/// spinning the Crown scrolled as far as the units it produced, and no setting tamed that: one quick turn flew.
/// (Also 20 times lower than before: it was 1000.)
private let scrollCeiling = 50.0

/// A Mac running the receiver, seen nearby.
struct FoundMac: Identifiable {
    let id: UUID
    let name: String
    let peripheral: CBPeripheral
}

/// What the Mac says about this watch. The Mac asks its owner before a new watch may move the cursor: until then
/// writes that expect an answer fail with `.insufficientAuthorization` (waiting) or `.writeNotPermitted` (declined).
enum Access { case unknown, allowed, waiting, declined }

/// Which edge of the watch is the pointing end, named by where it sits on the clock face: 12 = the top, 3 = the Digital
/// Crown side (on the left wrist it faces your fingers), 6 = the bottom, 9 = the side opposite the Crown.
enum PointerEdge: Int {
    case twelve = 12, three = 3, six = 6, nine = 9

    var next: PointerEdge {
        switch self {
        case .twelve: .three
        case .three: .six
        case .six: .nine
        case .nine: .twelve
        }
    }
}

final class Pointer: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var connected = false
    @Published var access = Access.unknown
    @Published var paused = false
    /// Speed (how little you turn to cross the screen) and steadiness (how much of a trembling hand is ignored).
    /// 1.0 = as the Mac was started. Remembered, and sent to the Mac a moment after they stop changing.
    @Published var speed = UserDefaults.standard.object(forKey: "speed") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(speed, forKey: "speed"); scheduleSettings() }
    }
    @Published var steady = UserDefaults.standard.object(forKey: "steady") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(steady, forKey: "steady"); scheduleSettings() }
    }
    /// Which edge you point with. Remembered.
    @Published var edge = PointerEdge(rawValue: UserDefaults.standard.integer(forKey: "pointerEdge")) ?? .three {
        didSet { UserDefaults.standard.set(edge.rawValue, forKey: "pointerEdge") }
    }
    /// How fast the Digital Crown scrolls (1.0 = the default). Remembered; only the watch needs it.
    @Published var scrollSpeed = UserDefaults.standard.object(forKey: "scrollSpeed") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(scrollSpeed, forKey: "scrollSpeed") }
    }
    /// Macs nearby you can pair with (only while nothing is paired).
    @Published var found: [FoundMac] = []
    /// The Mac you paired with. The watch only ever connects to this one until you forget it.
    @Published var pairedName = UserDefaults.standard.string(forKey: "pairedMacName")
    private var pairedID = UserDefaults.standard.string(forKey: "pairedMacID").flatMap(UUID.init)

    private var central: CBCentralManager!
    private var mac: CBPeripheral?
    private var input: CBCharacteristic?
    private var output: CBCharacteristic?
    private let motion = CMMotionManager()

    private var heading = 0.0       // radians turned left since "Center"
    private var elevation = 0.0     // radians the pointing edge points above horizontal, right now
    private var elevationZero = 0.0 // elevation when "Center" was pressed
    private var lastUp = (x: 0.0, y: 0.0, z: 1.0) // which way is up, in the watch's own axes, from the latest sample
    private var lastTimestamp: TimeInterval?
    private var infoTimer: Timer?
    private var retryInfo: DispatchWorkItem? // asks the Mac again soon while it waits for its owner to approve
    private var settingsWork: DispatchWorkItem? // sends the sliders once they stop moving
    private var pendingScroll = 0.0 // Crown turn not sent yet, in pixels
    private var scrollBudget = 0.0  // pixels the ceiling still allows right now
    private var lastScrollTime = ProcessInfo.processInfo.systemUptime

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        startMotion()
    }

    /// Whatever direction the watch points now becomes the middle of the screen.
    func center() {
        recenter()
        send(.center)
    }

    /// Paused: the cursor stays put (aim keeps tracking, so resuming lines up again).
    func togglePause() {
        paused.toggle()
        send(.pause, paused ? 1 : 0)
    }

    /// 12 → 3 → 6 → 9 → 12. The old aim means nothing for another edge, so this recentres too, like the Center button.
    func cycleEdge() {
        edge = edge.next
        center()
    }

    private func recenter() {
        heading = 0
        elevation = elevationOf(lastUp) // for the current edge, not the sample before it was changed
        elevationZero = elevation
    }

    /// How far the pointing edge tips above horizontal, from the direction of gravity (`up`, in the watch's own axes:
    /// x toward 3 o'clock, y toward 12). The opposite edge just flips the sign.
    private func elevationOf(_ up: (x: Double, y: Double, z: Double)) -> Double {
        let sine: Double = switch edge {
        case .twelve: up.y
        case .three: up.x
        case .six: -up.y
        case .nine: -up.x
        }
        return asin(min(max(sine, -1), 1))
    }

    /// The Mac applies these on arrival. It ignores them until its owner has approved this watch, so they are sent again
    /// on connect and the moment that approval shows up (see `didWriteValueFor`).
    private func scheduleSettings() {
        settingsWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendSettings() }
        settingsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func sendSettings() {
        send(.settings, Int16((speed * 100).rounded()), Int16((steady * 100).rounded()))
    }

    /// Tells the Mac which watch this is. Sent on connect, then every minute for the battery level.
    private func sendInfo() {
        guard let mac, let input else { return }
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        let info: [String: Any] = [
            "model": model,                                          // e.g. "Watch7,5"
            "os": device.systemVersion,
            "battery": device.batteryLevel < 0 ? -1 : Int((device.batteryLevel * 100).rounded()),
            "charging": device.batteryState == .charging || device.batteryState == .full,
            "name": String(device.name.prefix(40)),                  // kept short so it fits in one packet
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: info) else { return }
        mac.writeValue(Data([Kind.info.rawValue]) + json, for: input, type: .withResponse)
    }

    // MARK: Motion → aim

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 100

        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            let dt = lastTimestamp.map { min(data.timestamp - $0, 0.05) } ?? 0
            lastTimestamp = data.timestamp

            let g = data.gravity, r = data.rotationRate
            let n = max((g.x * g.x + g.y * g.y + g.z * g.z).squareRoot(), 1e-6)
            let up = (x: -g.x / n, y: -g.y / n, z: -g.z / n)
            // Up/down comes straight from gravity, so it never drifts: how far the pointing edge tips above horizontal.
            lastUp = up
            elevation = elevationOf(up)
            // Left/right has no absolute reference, so add up every turn around the vertical axis.
            // No dead zone: dropping slow turns is what made the old version slide out of line.
            heading += (r.x * up.x + r.y * up.y + r.z * up.z) * dt

            guard connected else { return }
            flushScroll()
            guard !paused else { return }
            sendAim(at: data.timestamp)
        }
    }

    private func sendAim(at timestamp: TimeInterval) {
        guard let mac, let input, mac.canSendWriteWithoutResponse else { return } // link busy: the next sample replaces this one
        let left = Int16(clamping: Int((remainder(heading, 2 * .pi) * 180 / .pi * 100).rounded()))
        let upward = Int16(clamping: Int(((elevation - elevationZero) * 180 / .pi * 100).rounded()))
        let ms = UInt16(truncatingIfNeeded: Int64(timestamp * 1000))
        let bytes = [Kind.aim.rawValue,
                     UInt8(truncatingIfNeeded: left), UInt8(truncatingIfNeeded: left >> 8),
                     UInt8(truncatingIfNeeded: upward), UInt8(truncatingIfNeeded: upward >> 8),
                     UInt8(truncatingIfNeeded: ms), UInt8(truncatingIfNeeded: ms >> 8)]
        mac.writeValue(Data(bytes), for: input, type: .withoutResponse)
    }

    /// `at`: when it happened on the watch's clock (same clock as the motion samples). Clicks and drags send the
    /// moment the thumb touched down, so the Mac clicks where you were pointing then, before the tap jolted the watch.
    /// Each Crown event is a tiny fraction; keep the leftovers so slow turns still add up to scrolling.
    /// `units`: Crown turn since the last call. Scrolls the Mac by that much times Scroll, but never faster than the
    /// ceiling (also times Scroll): a bucket that refills at the ceiling and holds a tenth of a second of scrolling.
    func scroll(crown units: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        let rate = scrollCeiling * scrollSpeed
        scrollBudget = min(scrollBudget + (now - lastScrollTime) * rate, rate * 0.1)
        lastScrollTime = now
        let allowed = min(abs(units) * crownPixels * scrollSpeed, scrollBudget)
        scrollBudget -= allowed
        pendingScroll += units < 0 ? -allowed : allowed
        flushScroll()
    }

    /// Sent on the fast lane like aim samples, so scrolling never queues behind clicks. If the link is busy,
    /// the amount waits and goes with the next one (the motion loop retries 100 times a second).
    private func flushScroll() {
        let whole = Int16(clamping: Int(pendingScroll))
        guard whole != 0, let mac, let input, mac.canSendWriteWithoutResponse else { return }
        pendingScroll -= Double(whole)
        let bytes = [Kind.scroll.rawValue, UInt8(truncatingIfNeeded: whole), UInt8(truncatingIfNeeded: whole >> 8), 0, 0]
        mac.writeValue(Data(bytes), for: input, type: .withoutResponse)
    }

    func send(_ kind: Kind, _ a: Int16 = 0, _ b: Int16 = 0, at time: TimeInterval? = nil) {
        guard let mac, let input else { return }
        var bytes = [kind.rawValue,
                     UInt8(truncatingIfNeeded: a), UInt8(truncatingIfNeeded: a >> 8),
                     UInt8(truncatingIfNeeded: b), UInt8(truncatingIfNeeded: b >> 8)]
        if let time {
            let ms = UInt16(truncatingIfNeeded: Int64(time * 1000))
            bytes += [UInt8(truncatingIfNeeded: ms), UInt8(truncatingIfNeeded: ms >> 8)]
        }
        // Clicks must not be dropped; aim samples can be.
        mac.writeValue(Data(bytes), for: input, type: kind == .aim ? .withoutResponse : .withResponse)
    }

    // MARK: Bluetooth

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { start() }
    }

    /// Paired: wait for that Mac (the connect completes whenever it's in range). Not paired: list what's nearby.
    private func start() {
        guard central.state == .poweredOn, mac == nil else { return }
        found = []
        if let pairedID, let known = central.retrievePeripherals(withIdentifiers: [pairedID]).first {
            connect(to: known)
        }
        central.scanForPeripherals(withServices: [serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        if let pairedID {
            if peripheral.identifier == pairedID { connect(to: peripheral) }
            return
        }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Mac"
        guard !found.contains(where: { $0.id == peripheral.identifier }) else { return }
        found.append(FoundMac(id: peripheral.identifier, name: name, peripheral: peripheral))
    }

    /// Pair with this Mac: remember it, then connect.
    func pair(_ found: FoundMac) {
        pairedID = found.id
        pairedName = found.name
        UserDefaults.standard.set(found.id.uuidString, forKey: "pairedMacID")
        UserDefaults.standard.set(found.name, forKey: "pairedMacName")
        self.found = []
        connect(to: found.peripheral)
    }

    /// Unpair, drop the connection and go back to listing nearby Macs.
    func forget() {
        pairedID = nil
        pairedName = nil
        UserDefaults.standard.removeObject(forKey: "pairedMacID")
        UserDefaults.standard.removeObject(forKey: "pairedMacName")
        if let mac { central.cancelPeripheralConnection(mac) }
        reset()
    }

    private func connect(to peripheral: CBPeripheral) {
        guard mac == nil else { return }
        central.stopScan()
        mac = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        reset()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        reset()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else { return }
        peripheral.discoverCharacteristics([inputUUID, outputUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        input = service.characteristics?.first { $0.uuid == inputUUID }
        output = service.characteristics?.first { $0.uuid == outputUUID }
        if let output { peripheral.setNotifyValue(true, for: output) }
        connected = input != nil
        recenter()
        sendInfo()
        sendSettings()
        infoTimer?.invalidate()
        infoTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.sendInfo() }
    }

    /// The answer to a write that expects one (info, clicks, drags, pause). Aim and scroll don't get one.
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == inputUUID else { return }
        guard let error else {
            if access != .allowed {
                access = .allowed
                sendSettings() // the Mac ignored them until it approved this watch
            }
            return
        }
        switch (error as? CBATTError)?.code {
        case .insufficientAuthorization:
            access = .waiting
            // Ask again in a moment so the watch notices the approval right away, not at the next minute's info.
            retryInfo?.cancel()
            let work = DispatchWorkItem { [weak self] in
                if self?.access == .waiting { self?.sendInfo() }
            }
            retryInfo = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        case .writeNotPermitted:
            access = .declined
        default:
            break
        }
    }

    private func reset() {
        mac = nil
        input = nil
        output = nil
        connected = false
        access = .unknown
        paused = false
        pendingScroll = 0
        retryInfo?.cancel()
        settingsWork?.cancel()
        infoTimer?.invalidate()
        start()
    }
}
