import IOKit.pwr_mgt
import SQLite3
import XCTest

@testable import Leader_Key

final class KeepAwakeAndBarTests: XCTestCase {
  private var suiteName: String!
  private var suite: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "com.machinespirit.KeepAwakeAndBarTests.\(UUID().uuidString)"
    suite = UserDefaults(suiteName: suiteName)!
  }

  override func tearDown() {
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
    suite = nil
    suiteName = nil
    super.tearDown()
  }

  func testFaviconRequestsOnlySendWebHosts() {
    let input = "https://name:pass@example.com:8443/private?draft=secret#fragment"
    XCTAssertEqual(FavIconImage.requestURL(for: input)?.absoluteString,
                   "https://www.google.com/s2/favicons?sz=128&domain=example.com")
    XCTAssertNil(FavIconImage.requestURL(for: "rectangle://execute-action?name=maximize"))
    XCTAssertNil(FavIconImage.requestURL(for: "file:///tmp/private"))
    XCTAssertNil(FavIconImage.requestURL(for: ""))
  }

  private final class FakeAssertions {
    var nextID: IOPMAssertionID = 100
    var created: [(id: IOPMAssertionID, type: String, name: String)] = []
    var released: [IOPMAssertionID] = []
    var shouldFail = false

    func create(_ type: String, _ name: String) -> IOPMAssertionID? {
      guard !shouldFail else { return nil }
      let id = nextID
      nextID += 1
      created.append((id, type, name))
      return id
    }

    func release(_ id: IOPMAssertionID) {
      released.append(id)
    }

    var activeIDs: [IOPMAssertionID] {
      let releasedSet = Set(released)
      return created.map(\.id).filter { !releasedSet.contains($0) }
    }
  }

  func testIndefiniteSessionPersistsAcrossRelaunchAndDisplaySetting() {
    let assertions = FakeAssertions()
    let clock = Date(timeIntervalSince1970: 1_700_000_000)

    let first = KeepAwake(
      defaults: suite, now: { clock },
      createAssertion: assertions.create, releaseAssertion: assertions.release)
    first.start(minutes: -1)
    XCTAssertTrue(first.isActive)
    XCTAssertEqual(first.minutes, -1)
    XCTAssertNil(first.deadline)
    XCTAssertEqual(assertions.created.last?.type, kIOPMAssertionTypePreventUserIdleDisplaySleep)

    first.keepsDisplayOn = false
    XCTAssertEqual(assertions.created.last?.type, kIOPMAssertionTypePreventUserIdleSystemSleep)
    XCTAssertEqual(assertions.activeIDs.count, 1)

    // Simulate graceful termination.
    first.suspend()
    XCTAssertFalse(first.isActive)
    XCTAssertTrue(assertions.activeIDs.isEmpty)

    // Simulate relaunch.
    let second = KeepAwake(
      defaults: suite, now: { clock.addingTimeInterval(300) },
      createAssertion: assertions.create, releaseAssertion: assertions.release)
    XCTAssertTrue(second.restore())
    XCTAssertTrue(second.isActive)
    XCTAssertEqual(second.minutes, -1)
    XCTAssertNil(second.deadline)
    XCTAssertFalse(second.keepsDisplayOn)
    XCTAssertEqual(assertions.created.last?.type, kIOPMAssertionTypePreventUserIdleSystemSleep)
    XCTAssertEqual(assertions.activeIDs.count, 1)

    // Explicit stop clears persistence.
    second.stop()
    XCTAssertFalse(second.isActive)
    XCTAssertTrue(assertions.activeIDs.isEmpty)

    let third = KeepAwake(
      defaults: suite, now: { clock.addingTimeInterval(600) },
      createAssertion: assertions.create, releaseAssertion: assertions.release)
    XCTAssertFalse(third.restore())
    XCTAssertFalse(third.isActive)
    XCTAssertTrue(assertions.activeIDs.isEmpty)
  }

  func testTimedSessionRestoresRemainingDeadlineBeforeExpiry() {
    let assertions = FakeAssertions()
    var current = Date(timeIntervalSince1970: 1_700_000_000)

    let first = KeepAwake(
      defaults: suite, now: { current },
      createAssertion: assertions.create, releaseAssertion: assertions.release)
    first.start(minutes: 120)
    XCTAssertEqual(first.minutes, 120)
    XCTAssertEqual(first.statusSummary(), "2h left")

    // Simulate relaunch 45 minutes later.
    first.suspend()
    current = current.addingTimeInterval(45 * 60)

    let second = KeepAwake(
      defaults: suite, now: { current },
      createAssertion: assertions.create, releaseAssertion: assertions.release)
    XCTAssertTrue(second.restore())
    XCTAssertEqual(second.minutes, 120)
    XCTAssertEqual(second.remainingMinutes(), 75)
    XCTAssertEqual(second.statusSummary(), "1h 15m left")
    XCTAssertEqual(assertions.activeIDs.count, 1)

    // Advance past deadline -> checkExpiry stops and clears persistence.
    current = current.addingTimeInterval(76 * 60)
    second.checkExpiry()
    XCTAssertFalse(second.isActive)
    XCTAssertTrue(assertions.activeIDs.isEmpty)

    let third = KeepAwake(
      defaults: suite, now: { current },
      createAssertion: assertions.create, releaseAssertion: assertions.release)
    XCTAssertFalse(third.restore())
  }

  func testExpiredTimedSessionDoesNotRestoreAfterRelaunch() {
    let assertions = FakeAssertions()
    var current = Date(timeIntervalSince1970: 1_700_000_000)

    let first = KeepAwake(
      defaults: suite, now: { current },
      createAssertion: assertions.create, releaseAssertion: assertions.release)
    first.start(minutes: 15)
    first.suspend()

    // Relaunch after 20 minutes (expired while app was down).
    current = current.addingTimeInterval(20 * 60)
    let second = KeepAwake(
      defaults: suite, now: { current },
      createAssertion: assertions.create, releaseAssertion: assertions.release)
    XCTAssertFalse(second.restore())
    XCTAssertFalse(second.isActive)
    XCTAssertTrue(assertions.activeIDs.isEmpty)
    XCTAssertNil(suite.object(forKey: KeepAwake.DefaultsKey.sessionMinutes))
    XCTAssertNil(suite.object(forKey: KeepAwake.DefaultsKey.sessionDeadline))
  }

  func testCorruptPersistedStateFailsSafeAndClearsKeys() {
    let assertions = FakeAssertions()
    suite.set(60, forKey: KeepAwake.DefaultsKey.sessionMinutes)
    // Missing deadline for timed session.
    let awake = KeepAwake(
      defaults: suite, createAssertion: assertions.create, releaseAssertion: assertions.release)
    XCTAssertFalse(awake.restore())
    XCTAssertNil(suite.object(forKey: KeepAwake.DefaultsKey.sessionMinutes))

    suite.set(-42, forKey: KeepAwake.DefaultsKey.sessionMinutes)
    XCTAssertFalse(awake.restore())
    XCTAssertNil(suite.object(forKey: KeepAwake.DefaultsKey.sessionMinutes))
    XCTAssertTrue(assertions.created.isEmpty)
  }

  func testSystemMenuSectionPrefersPersistedSessionOverLaunchFallback() {
    let assertions = FakeAssertions()
    var current = Date(timeIntervalSince1970: 1_700_000_000)
    SystemMenuSection.registerDefaults(in: suite)
    suite.set(true, forKey: "msKeepAwakeAtLaunch")

    // Save an active timed session, then suspend.
    let awake1 = KeepAwake(
      defaults: suite, now: { current },
      createAssertion: assertions.create, releaseAssertion: assertions.release)
    awake1.start(minutes: 60)
    awake1.suspend()

    // Relaunch 10 minutes later with msKeepAwakeAtLaunch = true: timed session survives.
    current = current.addingTimeInterval(10 * 60)
    let awake2 = KeepAwake(
      defaults: suite, now: { current },
      createAssertion: assertions.create, releaseAssertion: assertions.release)
    let section = SystemMenuSection(awake: awake2, defaults: suite)
    section.restoreAwakeSession()
    XCTAssertTrue(section.isAwake)
    XCTAssertEqual(awake2.minutes, 60)
    XCTAssertEqual(section.awakeStatusText, "50m left")

    // Explicitly stop, then relaunch with msKeepAwakeAtLaunch = true: falls back to indefinite.
    awake2.stop()
    let awake3 = KeepAwake(
      defaults: suite, now: { current },
      createAssertion: assertions.create, releaseAssertion: assertions.release)
    let section2 = SystemMenuSection(awake: awake3, defaults: suite)
    section2.restoreAwakeSession()
    XCTAssertTrue(section2.isAwake)
    XCTAssertEqual(awake3.minutes, -1)
    XCTAssertEqual(section2.awakeStatusText, "indefinitely")
    awake3.suspend()
  }

  private var barState: CompactBarState {
    CompactBarState(
      skull: true, t3: .counts(working: 1, open: 4),
      cpu: .value(49), gpu: .value(23), memory: .value(55),
      pressureLevel: .normal, temperature: .value(64),
      awake: true, dark: true, scale: 2, height: 24)
  }

  func testMenuBarWidthIsStableAcrossValuesAvailabilityAndAwakeState() {
    let baseline = barState
    XCTAssertEqual(StatusItem.barSegments, ["Skull", "T3", "CPU", "GPU", "Memory", "Temperature", "Awake"])
    XCTAssertEqual(CompactBar.cells(for: baseline).map(\.label), ["T3", "CPU%", "GPU%", "RAM%", "MPRS", "TEMP"])
    let width = CompactBar.image(baseline).size.width

    var expanded = baseline
    expanded.t3 = .counts(working: 102, open: 462)
    expanded.cpu = .value(100)
    expanded.gpu = .value(100)
    expanded.memory = .value(100)
    expanded.pressureLevel = .critical
    expanded.temperature = .value(100)
    expanded.awake = false
    XCTAssertEqual(CompactBar.cells(for: expanded).map(\.value), ["99+/99+", "100", "100", "100", "CRIT", "100°"])
    XCTAssertEqual(CompactBar.image(expanded).size.width, width)
    XCTAssertEqual(CompactBar.countsValue(462), "99+")
    XCTAssertEqual(CompactBar.countsValue(99), "99")

    var unavailable = expanded
    unavailable.t3 = .unavailable
    unavailable.cpu = .unavailable
    unavailable.gpu = .unavailable
    unavailable.memory = .unavailable
    unavailable.pressureLevel = nil
    unavailable.temperature = .unavailable
    XCTAssertEqual(CompactBar.cells(for: unavailable).map(\.value), Array(repeating: "—", count: 6))
    XCTAssertEqual(CompactBar.image(unavailable).size.width, width)

    unavailable.gpu = .hidden
    unavailable.awake = nil
    XCTAssertLessThan(CompactBar.image(unavailable).size.width, width)
  }

  func testLocalTaskCountsUseLatestRunAndOpenRoots() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    XCTAssertEqual(sqlite3_exec(db, """
      CREATE TABLE orchestration_v2_projection_threads(thread_id,title,archived_at,deleted_at,payload_json,updated_at);
      CREATE TABLE orchestration_v2_projection_runs(run_id,thread_id,ordinal,status,completed_at);
      CREATE TABLE orchestration_v2_projection_runtime_requests(thread_id,status,resolved_at);
      CREATE TABLE orchestration_v2_projection_subagents(thread_id,run_id,child_thread_id,completed_at);
      INSERT INTO orchestration_v2_projection_threads VALUES
        ('a-b_1:1','running',NULL,NULL,'{}',1),
        ('b','old run',NULL,NULL,'{}',1),
        ('c','asking',NULL,NULL,'{}',1),
        ('d','archived',1,NULL,'{}',1),
        ('e','deleted',NULL,1,'{}',1),
        ('f','settled',NULL,NULL,'{"settledOverride":"settled"}',1),
        ('g','auto settled',NULL,NULL,'{"settledAt":"2024-01-01"}',1),
        ('h','reopened',NULL,NULL,'{"settledAt":"2024-01-01","settledOverride":"active"}',1),
        ('i','snoozed',NULL,NULL,'{"snoozedUntil":"2999-01-01"}',1),
        ('j','child',NULL,NULL,'{"lineage":{"parentThreadId":"a-b_1:1"}}',1),
        ('k','child asking',NULL,NULL,'{}',1);
      INSERT INTO orchestration_v2_projection_runs VALUES
        ('ra','a-b_1:1',1,'running',NULL), ('rb1','b',1,'running',NULL), ('rb2','b',2,'completed',1),
        ('rc','c',1,'running',NULL), ('rk','k',1,'running',NULL);
      INSERT INTO orchestration_v2_projection_runtime_requests VALUES ('c','pending',NULL), ('child','pending',NULL);
      INSERT INTO orchestration_v2_projection_subagents VALUES ('k','rk','child',NULL);
      """, nil, nil, nil), SQLITE_OK)
    let environment = UUID()
    let entries = try XCTUnwrap(T3TaskRegistry.read(file: file, environment: environment))
    XCTAssertEqual(entries.count, 5)
    XCTAssertEqual(entries.filter(\.working).map(\.title), ["running"])
    XCTAssertEqual(entries.first?.url.absoluteString, "t3code://threads/\(environment.uuidString.lowercased())/a-b_1%3A1")
    XCTAssertEqual(sqlite3_exec(db, "DROP TABLE orchestration_v2_projection_runs", nil, nil, nil), SQLITE_OK)
    XCTAssertNil(T3TaskRegistry.read(file: file, environment: environment))
  }

  func testPressureHasItsOwnLevelAndAccessibleDescription() {
    var state = barState
    state.memory = .value(100)
    XCTAssertEqual(CompactBar.cells(for: state).first { $0.label == "MPRS" }?.value, "OK")
    XCTAssertTrue(state.descriptions(awakeStatus: "indefinitely").contains("RAM used 100%"))
    XCTAssertTrue(state.descriptions(awakeStatus: "indefinitely").contains("Memory pressure normal"))

    state.memory = .value(35)
    state.pressureLevel = .warning
    XCTAssertEqual(CompactBar.cells(for: state).first { $0.label == "MPRS" }?.value, "WARN")
    XCTAssertTrue(state.descriptions(awakeStatus: "off").contains("Memory pressure warning"))

    state.pressureLevel = .critical
    XCTAssertEqual(CompactBar.cells(for: state).first { $0.label == "MPRS" }?.value, "CRIT")
    XCTAssertTrue(state.descriptions(awakeStatus: "off").contains("Memory pressure critical"))
  }

  func testOnDemandStatsSummaryPreservesDiskAndNetwork() {
    let diskRow = SystemStats.Row(
      name: "Disk", summary: "120 GB free", details: ["Data volume: 120 GB free / 1 TB"],
      compact: "FREE 120 GB")
    XCTAssertEqual(diskRow.compactSummary, "FREE 120 GB")

    let fallbackDisk = SystemStats.Row(name: "Disk", summary: "Unavailable", details: [])
    XCTAssertEqual(fallbackDisk.compactSummary, "FREE —")

    let netRow = SystemStats.Row(
      name: "Network ↓/↑", summary: "1.2 MB/s / 300 KB/s", details: [],
      compact: "↓1.2 ↑0.3 MB/s")
    XCTAssertEqual(netRow.compactSummary, "↓1.2 ↑0.3 MB/s")
  }
}
