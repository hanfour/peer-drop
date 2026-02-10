import XCTest

// ═══════════════════════════════════════════════════════════════════════════
// Performance Metrics Collection
//
// Provides timing and metrics collection for E2E performance tests.
// Results are written to JSON files for analysis and baseline comparison.
//
// ═══════════════════════════════════════════════════════════════════════════

/// A single performance measurement result
struct PerformanceResult: Codable {
    let metric: String
    let value: Double
    let unit: String
    let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case metric = "name"
        case value
        case unit
        case timestamp
    }
}

/// Performance metrics collector for E2E tests
class PerformanceMetrics {

    /// Stored measurements grouped by metric name
    private var measurements: [String: [Double]] = [:]

    /// Active timers keyed by name
    private var activeTimers: [String: CFAbsoluteTime] = [:]

    /// Test run ID
    private let runID: String

    /// Role (initiator or acceptor)
    private let role: String

    init(runID: String, role: String) {
        self.runID = runID
        self.role = role
    }

    // MARK: - Timer Methods

    /// Start a timer and return the start time
    /// - Parameter name: Timer name
    /// - Returns: Start time
    @discardableResult
    func startTimer(_ name: String) -> CFAbsoluteTime {
        let start = CFAbsoluteTimeGetCurrent()
        activeTimers[name] = start
        print("[PERF:\(role.uppercased())] Timer started: \(name)")
        return start
    }

    /// Stop a timer and record the elapsed time
    /// - Parameters:
    ///   - name: Timer name
    ///   - start: Optional start time (uses stored timer if nil)
    /// - Returns: Elapsed time in seconds
    @discardableResult
    func stopTimer(_ name: String, start: CFAbsoluteTime? = nil) -> Double {
        let startTime = start ?? activeTimers[name] ?? CFAbsoluteTimeGetCurrent()
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        activeTimers.removeValue(forKey: name)
        record(name, value: elapsed, unit: "seconds")
        print("[PERF:\(role.uppercased())] Timer stopped: \(name) = \(String(format: "%.3f", elapsed))s")
        return elapsed
    }

    // MARK: - Recording Methods

    /// Record a metric value
    /// - Parameters:
    ///   - name: Metric name
    ///   - value: Metric value
    ///   - unit: Unit of measurement
    func record(_ name: String, value: Double, unit: String) {
        if measurements[name] == nil {
            measurements[name] = []
        }
        measurements[name]?.append(value)
        print("[PERF:\(role.uppercased())] Recorded: \(name) = \(String(format: "%.3f", value)) \(unit)")
    }

    // MARK: - Statistics Methods

    /// Get average value for a metric
    func average(_ name: String) -> Double? {
        guard let values = measurements[name], !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Get p95 value for a metric
    func p95(_ name: String) -> Double? {
        guard let values = measurements[name], !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int(Double(sorted.count) * 0.95)
        return sorted[Swift.min(index, sorted.count - 1)]
    }

    /// Get minimum value for a metric
    func minValue(_ name: String) -> Double? {
        measurements[name]?.min()
    }

    /// Get maximum value for a metric
    func maxValue(_ name: String) -> Double? {
        measurements[name]?.max()
    }

    // MARK: - Summary Methods

    /// Generate summary results for all metrics
    func summary() -> [PerformanceResult] {
        var results: [PerformanceResult] = []
        let now = Date()

        for (name, values) in measurements.sorted(by: { $0.key < $1.key }) {
            guard !values.isEmpty else { continue }

            // For single measurements, just output the value
            if values.count == 1 {
                results.append(PerformanceResult(
                    metric: name,
                    value: values[0],
                    unit: "seconds",
                    timestamp: now
                ))
            } else {
                // For multiple measurements, output avg and p95
                let avg = values.reduce(0, +) / Double(values.count)
                results.append(PerformanceResult(
                    metric: "\(name)-avg",
                    value: avg,
                    unit: "seconds",
                    timestamp: now
                ))

                let sorted = values.sorted()
                let p95Index = Int(Double(sorted.count) * 0.95)
                let p95Value = sorted[Swift.min(p95Index, sorted.count - 1)]
                results.append(PerformanceResult(
                    metric: "\(name)-p95",
                    value: p95Value,
                    unit: "seconds",
                    timestamp: now
                ))
            }
        }

        return results
    }

    // MARK: - File Output

    /// Write metrics to a JSON file
    /// - Parameter path: File path
    func writeToFile(_ path: String) {
        let results = summary()

        let output: [String: Any] = [
            "runId": runID,
            "role": role,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "metrics": results.map { result in
                [
                    "name": result.metric,
                    "value": result.value,
                    "unit": result.unit
                ]
            }
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
            print("[PERF:\(role.uppercased())] Metrics written to: \(path)")
        } catch {
            print("[PERF:\(role.uppercased())] Failed to write metrics: \(error)")
        }
    }

    /// Write metrics to the sync directory for aggregation
    func writeToSyncDirectory(_ syncDir: String) {
        let path = "\(syncDir)/metrics-\(role).json"
        writeToFile(path)
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Multi-Simulator Test Base Class
//
// Provides file-based synchronization between two simulators running
// coordinated E2E tests. Uses /tmp/peerdrop-test-sync/ for checkpoint
// signals and verification data.
//
// SYNCHRONIZATION FLOW:
//   Initiator                              Acceptor
//       |                                      |
//       | signal("initiator-ready")            |
//       |────────────────────────────────────▶|
//       |                     wait("initiator-ready")
//       |                                      |
//       |◀────────────────────────────────────|
//       | wait("acceptor-ready")  signal("acceptor-ready")
//
// ═══════════════════════════════════════════════════════════════════════════

// MARK: - Centralized Timeout Configuration

/// Centralized timeout configuration for E2E tests
/// All timeouts should be defined here for easy tuning
enum TestTimeouts {
    // Checkpoint synchronization
    static let checkpointDefault: TimeInterval = 30
    static let checkpointLong: TimeInterval = 60
    static let checkpointPoll: TimeInterval = 0.5

    // App launch and setup
    static let appLaunch: TimeInterval = 10
    static let tabBarReady: TimeInterval = 10

    // UI interactions
    static let buttonWait: TimeInterval = 5
    static let elementWait: TimeInterval = 3
    static let messageVerify: TimeInterval = 10
    static let consentWait: TimeInterval = 60
    static let peerDiscovery: TimeInterval = 30

    // Connection states
    static let connectionEstablish: TimeInterval = 30
    static let reconnect: TimeInterval = 15

    // Post-action stabilization (polling waits, not sleep)
    static let uiStabilize: TimeInterval = 2
    static let networkStabilize: TimeInterval = 3
}

/// Base class for multi-simulator E2E tests providing synchronization primitives
class MultiSimTestBase: XCTestCase {

    // MARK: - Configuration

    /// Sync directory shared between simulators (host filesystem)
    static let syncDirectory = "/tmp/peerdrop-test-sync"

    /// Unique run ID for test isolation (read from shared file or generated)
    static var runID: String {
        // First, try to read from shared file (set by shell script)
        let runIDPath = "\(syncDirectory)/run_id"
        if let sharedRunID = try? String(contentsOfFile: runIDPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !sharedRunID.isEmpty {
            return sharedRunID
        }
        // Fallback to environment variable
        if let envRunID = ProcessInfo.processInfo.environment["PEERDROP_TEST_RUN_ID"], !envRunID.isEmpty {
            return envRunID
        }
        // Last fallback: generate once per process using timestamp
        return _runID
    }
    private static let _runID = String(format: "%.0f", Date().timeIntervalSince1970 * 1000)

    /// Role of this test instance
    enum TestRole: String {
        case initiator
        case acceptor
    }

    /// Override in subclass to specify role
    var role: TestRole { fatalError("Subclass must override 'role'") }

    /// Test timeout for waiting operations
    var defaultTimeout: TimeInterval { TestTimeouts.checkpointDefault }

    /// XCUIApplication instance
    var app: XCUIApplication!

    /// Performance metrics collector
    lazy var metrics: PerformanceMetrics = {
        PerformanceMetrics(runID: Self.runID, role: role.rawValue)
    }()

    // MARK: - Setup & Teardown

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()

        // Wait for app to be ready
        XCTAssertTrue(
            app.tabBars.firstMatch.waitForExistence(timeout: 10),
            "App should launch with tab bar visible"
        )

        // Ensure sync directory exists and clean this test's directory
        ensureSyncDirectoryExists()
        cleanTestSyncDirectory()

        // Log role
        print("[\(role.rawValue.uppercased())] Test starting: \(name)")
    }

    /// Clean this test's sync directory to ensure fresh state
    private func cleanTestSyncDirectory() {
        let fileManager = FileManager.default
        let testDir = testSyncDirectory

        // Only clean if we're the initiator (to avoid race condition)
        if role == .initiator {
            try? fileManager.removeItem(atPath: testDir)
            try? fileManager.createDirectory(
                atPath: testDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o777]
            )
            print("[\(role.rawValue.uppercased())] Cleaned sync directory: \(testDir)")
        }
    }

    override func tearDownWithError() throws {
        // Take final screenshot
        screenshot("\(role.rawValue)-final")

        // Write performance metrics if any were collected
        writePerformanceMetrics()

        // Signal completion for this role
        signalCheckpoint("\(role.rawValue)-complete")

        print("[\(role.rawValue.uppercased())] Test finished: \(name)")
    }

    /// Write performance metrics to sync directory
    func writePerformanceMetrics() {
        let metricsPath = "\(testSyncDirectory)/metrics-\(role.rawValue).json"
        metrics.writeToFile(metricsPath)
    }

    // MARK: - Sync Directory Management

    private func ensureSyncDirectoryExists() {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: Self.syncDirectory) {
            try? fileManager.createDirectory(
                atPath: Self.syncDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o777]
            )
        }
    }

    /// Get the current test ID from the test name
    var testID: String {
        // Extract test ID from method name like "test_DISC_01"
        let methodName = name.components(separatedBy: " ").last ?? name
        return methodName
            .replacingOccurrences(of: "test_", with: "")
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "]", with: "")
    }

    /// Directory for this specific test run (includes run ID for isolation)
    var testSyncDirectory: String {
        "\(Self.syncDirectory)/\(Self.runID)/\(testID)"
    }

    // MARK: - Checkpoint Signals

    /// Signal that this side has reached a checkpoint
    /// - Parameter name: Checkpoint name (e.g., "ready", "connected", "message-sent")
    func signalCheckpoint(_ name: String) {
        let checkpointPath = "\(testSyncDirectory)/\(role.rawValue)-\(name)"
        try? FileManager.default.createDirectory(
            atPath: testSyncDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let timestamp = Date().timeIntervalSince1970
        try? "\(timestamp)".write(toFile: checkpointPath, atomically: true, encoding: .utf8)

        print("[\(role.rawValue.uppercased())] Signaled checkpoint: \(name)")
    }

    /// Wait for the other side to reach a checkpoint
    /// - Parameters:
    ///   - name: Checkpoint name to wait for
    ///   - timeout: Maximum time to wait
    /// - Returns: true if checkpoint was reached, false if timed out
    @discardableResult
    func waitForCheckpoint(_ name: String, timeout: TimeInterval? = nil) -> Bool {
        let effectiveTimeout = timeout ?? defaultTimeout
        let otherRole: TestRole = role == .initiator ? .acceptor : .initiator
        let checkpointPath = "\(testSyncDirectory)/\(otherRole.rawValue)-\(name)"

        print("[\(role.rawValue.uppercased())] Waiting for checkpoint: \(name) (timeout: \(effectiveTimeout)s)")

        let startTime = Date()
        while Date().timeIntervalSince(startTime) < effectiveTimeout {
            if FileManager.default.fileExists(atPath: checkpointPath) {
                print("[\(role.rawValue.uppercased())] Checkpoint reached: \(name)")
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        print("[\(role.rawValue.uppercased())] Checkpoint timeout: \(name)")
        return false
    }

    /// Wait for own checkpoint to be acknowledged by the other side
    /// Useful for two-way handshakes
    func syncWithPeer(localCheckpoint: String, peerCheckpoint: String, timeout: TimeInterval? = nil) -> Bool {
        signalCheckpoint(localCheckpoint)
        return waitForCheckpoint(peerCheckpoint, timeout: timeout)
    }

    // MARK: - Verification Data Exchange

    /// Write verification data that the other side can read
    /// - Parameters:
    ///   - key: Data key
    ///   - value: Data value
    func writeVerificationResult(_ key: String, value: String) {
        try? FileManager.default.createDirectory(
            atPath: testSyncDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let dataPath = "\(testSyncDirectory)/data-\(role.rawValue)-\(key)"
        try? value.write(toFile: dataPath, atomically: true, encoding: .utf8)

        print("[\(role.rawValue.uppercased())] Wrote verification data: \(key) = \(value)")
    }

    /// Read verification data written by the other side
    /// - Parameter key: Data key
    /// - Returns: Data value or nil if not found
    func readVerificationResult(_ key: String) -> String? {
        let otherRole: TestRole = role == .initiator ? .acceptor : .initiator
        let dataPath = "\(testSyncDirectory)/data-\(otherRole.rawValue)-\(key)"

        if let value = try? String(contentsOfFile: dataPath, encoding: .utf8) {
            print("[\(role.rawValue.uppercased())] Read verification data: \(key) = \(value)")
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Wait for verification data from the other side
    func waitForVerificationData(_ key: String, timeout: TimeInterval? = nil) -> String? {
        let effectiveTimeout = timeout ?? defaultTimeout
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < effectiveTimeout {
            if let value = readVerificationResult(key) {
                return value
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    // MARK: - Screenshot Helpers

    /// Take and attach a screenshot with a descriptive name
    func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(testID)-\(role.rawValue)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Common UI Helpers

    /// Poll until a condition is met or timeout
    /// - Parameters:
    ///   - timeout: Maximum time to wait
    ///   - interval: Polling interval (default 0.2s)
    ///   - condition: Condition to check
    /// - Returns: true if condition was met, false if timed out
    @discardableResult
    func waitUntil(timeout: TimeInterval, interval: TimeInterval = 0.2, condition: () -> Bool) -> Bool {
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            if condition() { return true }
            Thread.sleep(forTimeInterval: interval)
        }
        return condition()
    }

    /// Ensure the app is online (tap "Go online" if needed)
    func ensureOnline() {
        let goOnlineBtn = app.navigationBars.buttons["Go online"]
        if goOnlineBtn.waitForExistence(timeout: TestTimeouts.uiStabilize) {
            goOnlineBtn.tap()
            // Wait for online state to stabilize
            let goOfflineBtn = app.navigationBars.buttons["Go offline"]
            _ = goOfflineBtn.waitForExistence(timeout: TestTimeouts.networkStabilize)
        }
    }

    /// Go offline
    func goOffline() {
        let goOfflineBtn = app.navigationBars.buttons["Go offline"]
        if goOfflineBtn.waitForExistence(timeout: TestTimeouts.elementWait) {
            goOfflineBtn.tap()
            // Wait for offline state
            let goOnlineBtn = app.navigationBars.buttons["Go online"]
            _ = goOnlineBtn.waitForExistence(timeout: TestTimeouts.networkStabilize)
        }
    }

    /// Go back online
    func goOnline() {
        let goOnlineBtn = app.navigationBars.buttons["Go online"]
        if goOnlineBtn.waitForExistence(timeout: TestTimeouts.elementWait) {
            goOnlineBtn.tap()
            // Wait for online state
            let goOfflineBtn = app.navigationBars.buttons["Go offline"]
            _ = goOfflineBtn.waitForExistence(timeout: TestTimeouts.networkStabilize)
        }
    }

    /// Switch to a tab
    func switchToTab(_ name: String) {
        let tab = app.tabBars.buttons[name]
        tab.tap()
        // Wait for tab to be selected
        _ = waitUntil(timeout: TestTimeouts.uiStabilize) { tab.isSelected }
    }

    /// Find a peer device in the discovery list
    func findPeer(timeout: TimeInterval = 30) -> XCUIElement? {
        let peer = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'iPhone'")
        ).firstMatch
        if peer.waitForExistence(timeout: timeout) { return peer }

        let cell = app.cells.matching(
            NSPredicate(format: "label CONTAINS 'iPhone'")
        ).firstMatch
        if cell.waitForExistence(timeout: 3) { return cell }

        let text = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'iPhone'")
        ).firstMatch
        if text.waitForExistence(timeout: 3) { return text }

        return nil
    }

    /// Tap on a peer element
    func tapPeer(_ peer: XCUIElement) {
        if peer.elementType == .cell {
            peer.tap()
        } else {
            peer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    /// Wait for connection to be established (Connected tab selected)
    func waitForConnected(timeout: TimeInterval = TestTimeouts.connectionEstablish) -> Bool {
        let connectedTab = app.tabBars.buttons["Connected"]
        return waitUntil(timeout: timeout) { connectedTab.isSelected }
    }

    /// Wait for consent sheet and return the Accept button
    func waitForConsent(timeout: TimeInterval = TestTimeouts.consentWait) -> Bool {
        let accept = app.buttons["Accept"]
        return accept.waitForExistence(timeout: timeout)
    }

    /// Navigate to the ConnectionView for the active peer
    func navigateToConnectionView() {
        let peerRow = app.buttons["active-peer-row"]
        if peerRow.waitForExistence(timeout: TestTimeouts.buttonWait) {
            peerRow.tap()
            // Wait for navigation to complete
            _ = app.navigationBars.firstMatch.waitForExistence(timeout: TestTimeouts.uiStabilize)
        }
    }

    /// Navigate to Chat from ConnectionView
    func navigateToChat() {
        // Try accessibility identifier first
        let chatButton = app.buttons["chat-button"]
        if chatButton.waitForExistence(timeout: TestTimeouts.buttonWait) {
            chatButton.tap()
            // Wait for chat view to load
            let messageField = app.textFields["Message"]
            _ = messageField.waitForExistence(timeout: TestTimeouts.uiStabilize)
            return
        }
        // Fallback to label
        let chatLabel = app.staticTexts["Chat"]
        if chatLabel.waitForExistence(timeout: TestTimeouts.elementWait) {
            chatLabel.tap()
            let messageField = app.textFields["Message"]
            _ = messageField.waitForExistence(timeout: TestTimeouts.uiStabilize)
        }
    }

    /// Tap Send File button in ConnectionView
    func tapSendFile() {
        let sendFileButton = app.buttons["send-file-button"]
        if sendFileButton.waitForExistence(timeout: TestTimeouts.buttonWait) {
            sendFileButton.tap()
            // Wait for file picker to appear
            _ = waitUntil(timeout: TestTimeouts.uiStabilize) { self.app.sheets.count > 0 || self.app.otherElements["FilePicker"].exists }
            return
        }
        // Fallback to label
        let sendFileLabel = app.staticTexts["Send File"]
        if sendFileLabel.waitForExistence(timeout: TestTimeouts.elementWait) {
            sendFileLabel.tap()
            _ = waitUntil(timeout: TestTimeouts.uiStabilize) { self.app.sheets.count > 0 || self.app.otherElements["FilePicker"].exists }
        }
    }

    /// Check if Send File button exists
    func sendFileButtonExists(timeout: TimeInterval = 5) -> Bool {
        let sendFileButton = app.buttons["send-file-button"]
        if sendFileButton.waitForExistence(timeout: timeout) { return true }
        let sendFileLabel = app.staticTexts["Send File"]
        return sendFileLabel.waitForExistence(timeout: 2)
    }

    /// Check if Chat button exists
    func chatButtonExists(timeout: TimeInterval = 5) -> Bool {
        let chatButton = app.buttons["chat-button"]
        if chatButton.waitForExistence(timeout: timeout) { return true }
        let chatLabel = app.staticTexts["Chat"]
        return chatLabel.waitForExistence(timeout: 2)
    }

    /// Check if Voice Call button exists
    func voiceCallButtonExists(timeout: TimeInterval = 5) -> Bool {
        let voiceButton = app.buttons["voice-call-button"]
        if voiceButton.waitForExistence(timeout: timeout) { return true }
        let voiceLabel = app.staticTexts["Voice Call"]
        return voiceLabel.waitForExistence(timeout: 2)
    }

    /// Send a chat message
    func sendChatMessage(_ text: String) {
        let field = app.textFields["Message"]
        if field.waitForExistence(timeout: TestTimeouts.buttonWait) {
            field.tap()
            field.typeText(text)
            let send = app.buttons["Send"]
            if send.waitForExistence(timeout: TestTimeouts.uiStabilize) {
                send.tap()
                // Wait for message to appear in chat
                _ = verifyMessageExists(text, timeout: TestTimeouts.uiStabilize)
            }
        }
    }

    /// Verify a message exists in chat
    func verifyMessageExists(_ text: String, timeout: TimeInterval = TestTimeouts.messageVerify) -> Bool {
        let message = app.staticTexts[text]
        return message.waitForExistence(timeout: timeout)
    }

    /// Go back one screen
    func goBack() {
        let back = app.navigationBars.buttons.firstMatch
        if back.exists {
            back.tap()
            // Wait for navigation to complete
            _ = waitUntil(timeout: TestTimeouts.uiStabilize) { self.app.navigationBars.count >= 1 }
        }
    }

    /// Disconnect from the current peer
    func disconnectFromPeer() {
        let btn = app.buttons.matching(identifier: "Disconnect").firstMatch
        if btn.waitForExistence(timeout: TestTimeouts.buttonWait) {
            btn.tap()
            let sheet = app.sheets.firstMatch
            if sheet.waitForExistence(timeout: TestTimeouts.elementWait) {
                sheet.buttons["Disconnect"].tap()
                // Wait for disconnection to complete
                let discoverTab = app.tabBars.buttons["Discover"]
                _ = waitUntil(timeout: TestTimeouts.networkStabilize) { discoverTab.isSelected }
            }
        }
    }

    // MARK: - Assertions with Sync

    /// Assert with checkpoint synchronization
    func assertWithSync(
        _ condition: Bool,
        checkpoint: String,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if condition {
            signalCheckpoint("\(checkpoint)-passed")
        } else {
            signalCheckpoint("\(checkpoint)-failed")
            writeVerificationResult("\(checkpoint)-error", value: message)
        }
        XCTAssertTrue(condition, message, file: file, line: line)
    }
}

// MARK: - Initiator Base Class

/// Base class for initiator-side tests
class E2EInitiatorTestBase: MultiSimTestBase {
    override var role: TestRole { .initiator }

    /// Standard initiator setup: ensure online, wait for acceptor
    func standardInitiatorSetup() {
        ensureOnline()
        screenshot("online")

        // Signal ready and wait for acceptor
        signalCheckpoint("ready")
        XCTAssertTrue(
            waitForCheckpoint("ready", timeout: 60),
            "Acceptor should signal ready"
        )
    }
}

// MARK: - Acceptor Base Class

/// Base class for acceptor-side tests
class E2EAcceptorTestBase: MultiSimTestBase {
    override var role: TestRole { .acceptor }

    /// Standard acceptor setup: ensure online, signal ready, wait for initiator
    func standardAcceptorSetup() {
        ensureOnline()
        screenshot("online")

        // Wait for initiator, then signal ready
        XCTAssertTrue(
            waitForCheckpoint("ready", timeout: 60),
            "Initiator should signal ready"
        )
        signalCheckpoint("ready")
    }

    /// Accept incoming connection
    func acceptConnection() {
        XCTAssertTrue(waitForConsent(), "Should receive connection request")
        screenshot("consent-sheet")
        app.buttons["Accept"].tap()
        print("[ACCEPTOR] Accepted connection")
        // Wait for connection to establish
        _ = waitForConnected(timeout: TestTimeouts.networkStabilize)
    }

    /// Decline incoming connection
    func declineConnection() {
        XCTAssertTrue(waitForConsent(), "Should receive connection request")
        screenshot("consent-sheet")
        app.buttons["Decline"].tap()
        print("[ACCEPTOR] Declined connection")
        // Wait for consent sheet to dismiss
        _ = waitUntil(timeout: TestTimeouts.uiStabilize) { !self.app.buttons["Decline"].exists }
    }
}
