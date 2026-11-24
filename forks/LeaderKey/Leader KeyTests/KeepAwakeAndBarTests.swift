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
      availablePercent: 44, pressureLevel: .normal, temperature: .value(64),
      awake: true, dark: true, scale: 2, height: 24)
  }

  func testMenuBarWidthIsStableAcrossValuesAvailabilityAndAwakeState() {
    let baseline = barState
    XCTAssertEqual(StatusItem.barSegments, ["Skull", "T3", "CPU", "GPU", "Memory", "Temperature", "Disks", "Awake"])
    XCTAssertEqual(CompactBar.cells(for: baseline).map(\.label), ["T3", "CPU", "GPU", "RAM", "MPRS", "TEMP"])
    let width = CompactBar.image(baseline).size.width

    var expanded = baseline
    expanded.t3 = .counts(working: 102, open: 462)
    expanded.cpu = .value(100)
    expanded.gpu = .value(100)
    expanded.memory = .value(100)
    expanded.pressureLevel = .critical
    expanded.temperature = .value(100)
    expanded.awake = false
    XCTAssertEqual(CompactBar.cells(for: expanded).map(\.value), ["99+/99+", "100%", "100%", "100%", "3/3", "100°"])
    XCTAssertEqual(CompactBar.image(expanded).size.width, width)
    XCTAssertEqual(CompactBar.countsValue(462), "99+")
    XCTAssertEqual(CompactBar.countsValue(99), "99")

    var unavailable = expanded
    unavailable.t3 = .unavailable
    unavailable.cpu = .unavailable
    unavailable.gpu = .unavailable
    unavailable.memory = .unavailable
    unavailable.availablePercent = nil
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

  func testAwakeMoleculeIsUprightAndCompact() throws {
    var state = barState
    state.skull = false
    state.t3 = .hidden
    state.cpu = .hidden
    state.gpu = .hidden
    state.memory = .hidden
    state.temperature = .hidden
    let image = CompactBar.image(state)
    XCTAssertLessThanOrEqual(image.size.width, 14)
    let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
    var ink = CGRect.null
    for y in 0..<rep.pixelsHigh {
      for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.25 {
        ink = ink.union(CGRect(x: x, y: y, width: 1, height: 1))
      }
    }
    XCTAssertFalse(ink.isNull)
    XCTAssertGreaterThan(ink.height, ink.width * 1.5)
  }

  func testPressureHasItsOwnLevelAndAccessibleDescription() {
    var state = barState
    state.memory = .value(100)
    XCTAssertEqual(CompactBar.cells(for: state).first { $0.label == "MPRS" }?.value, "1/3")
    XCTAssertTrue(state.descriptions(awakeStatus: "indefinitely").contains("RAM used 100%"))
    XCTAssertTrue(state.descriptions(awakeStatus: "indefinitely").contains("Memory pressure normal"))

    state.memory = .value(35)
    state.pressureLevel = .warning
    XCTAssertEqual(CompactBar.cells(for: state).first { $0.label == "MPRS" }?.value, "2/3")
    XCTAssertTrue(state.descriptions(awakeStatus: "off").contains("Memory pressure warning"))

    state.pressureLevel = .critical
    XCTAssertEqual(CompactBar.cells(for: state).first { $0.label == "MPRS" }?.value, "3/3")
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

extension KeepAwakeAndBarTests {
  @MainActor
  func testInlineAudioRowsStayBetweenBrightnessAndKeepAwakeWhenMembershipChanges() async throws {
    guard #available(macOS 14.4, *) else { throw XCTSkip("Process taps require macOS 14.4") }
    let status = StatusItem()
    let menu = NSMenu()
    let audio = status.nowPlaying
    var sample = 0
    audio.enumerate = {
      sample += 1
      if sample == 1 {
        return [NowPlayingProcess(object: 101, pid: 999901), NowPlayingProcess(object: 102, pid: 999902)]
      }
      return []
    }
    audio.makeTap = { _ in throw NSError(domain: "AudioLayoutFixture", code: 1) }
    status.buildMenu(menu)
    let header = try XCTUnwrap(menu.items.first { $0.title.lowercased() == "now playing" },
                               String(describing: menu.items.map(\.title)))
    let brightness = try XCTUnwrap(menu.item(withTitle: "Brightness"))
    let awake = try XCTUnwrap(menu.items.first { $0.title.hasPrefix("Keep awake") })
    let index = menu.index(of: brightness)
    XCTAssertNil(header.submenu)
    XCTAssertEqual(menu.index(of: header), index + 1)
    XCTAssertEqual(menu.item(at: index + 2)?.title, "Checking audio…")
    XCTAssertEqual(menu.index(of: awake), index + 3)
    XCTAssertFalse(audio.isOpen)
    audio.open()
    defer { audio.close() }
    func waitForSample(_ count: Int) async throws {
      let deadline = ContinuousClock.now + .seconds(4)
      while audio.sampleCount < count && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertGreaterThanOrEqual(audio.sampleCount, count)
    }
    try await waitForSample(1)
    XCTAssertEqual(menu.item(at: index + 2)?.title, "Process 999901")
    XCTAssertEqual(menu.item(at: index + 3)?.title, "Process 999902")
    XCTAssertGreaterThan(menu.index(of: awake), index + 3)
    try await waitForSample(2)
    XCTAssertEqual(menu.item(at: index + 2)?.title, "silence")
    XCTAssertEqual(menu.index(of: awake), index + 3)
    XCTAssertEqual(menu.index(of: header), index + 1)
    audio.close()
    XCTAssertTrue(audio.timersAreNil && audio.sessionIsNil)
  }
}

extension KeepAwakeAndBarTests {
  func testDiskCellsUseDriveKindLabelsTimeMachineGroupingAndSeparators() throws {
    let disks = [
      UserDiskVolume(
        path: "/Volumes/Backups", freeBytes: 3_127_000_000_000, totalBytes: 5_000_000_000_000,
        kind: .hdd, isTimeMachine: true, isInternal: false),
      UserDiskVolume(
        path: "/Volumes/Archive HDD", freeBytes: 999_999_999_999, totalBytes: nil,
        kind: .hdd, isTimeMachine: false, isInternal: false),
      UserDiskVolume(
        path: "/Volumes/TTH Work", freeBytes: 101_200_000_000, totalBytes: nil,
        kind: .ssd, isTimeMachine: false, isInternal: false),
      UserDiskVolume(
        path: "/Volumes/New Volume", freeBytes: 87_800_000_000, totalBytes: nil,
        kind: .ssd, isTimeMachine: false, isInternal: false),
      UserDiskVolume(
        path: UserDiskVolume.dataPath, freeBytes: 6_800_000_000, totalBytes: nil,
        kind: .ssd, isTimeMachine: false, isInternal: true),
    ]
    var state = barState
    state.disks = disks
    let cells = CompactBar.cells(for: state)
    let diskCells = cells.suffix(5)
    XCTAssertEqual(diskCells.map(\.label), ["SSD1", "SSD2", "SSD3", "HDD1", "TM"])
    XCTAssertEqual(diskCells.map(\.value), ["6.8G", "87G", "101G", "999G", "3.1T"])
    XCTAssertEqual(
      diskCells.map(\.group), [.disks, .disks, .disks, .disks, .timeMachine])

    // Expect 3 vertical separator lines: after T3, after TEMP, and before TM.
    let separatorXs = CompactBar.separatorXPositions(for: state)
    XCTAssertEqual(separatorXs.count, 3)

    let image = CompactBar.image(state)
    let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
    let midY = rep.pixelsHigh / 2
    for sepX in separatorXs {
      let px = Int(sepX * state.scale)
      let alpha = rep.colorAt(x: px, y: midY)?.alphaComponent ?? 0
      XCTAssertGreaterThan(alpha, 0.15, "Expected visible separator ink at x=\(sepX)")
    }

    // Tooltip includes both the concise label and the full mount path.
    let descriptions = state.descriptions(awakeStatus: "off")
    XCTAssertTrue(descriptions.contains { $0.hasPrefix("SSD1 (Data) · /System/Volumes/Data · ") })
    XCTAssertTrue(descriptions.contains { $0.hasPrefix("TM (Backups) · /Volumes/Backups · ") })

    // Width stays fixed when values become unavailable, and grows dynamically when a new disk mounts.
    let width = image.size.width
    state.disks = disks.map {
      UserDiskVolume(
        path: $0.path, freeBytes: nil, totalBytes: nil,
        kind: $0.kind, isTimeMachine: $0.isTimeMachine, isInternal: $0.isInternal)
    }
    XCTAssertEqual(CompactBar.cells(for: state).suffix(5).map(\.value), Array(repeating: "—", count: 5))
    XCTAssertEqual(CompactBar.image(state).size.width, width)

    state.disks.append(
      UserDiskVolume(
        path: "/Volumes/Extra SSD", freeBytes: 500_000_000_000, totalBytes: nil,
        kind: .ssd, isTimeMachine: false, isInternal: false))
    XCTAssertTrue(CompactBar.cells(for: state).map(\.label).contains("SSD4"))
    XCTAssertGreaterThan(CompactBar.image(state).size.width, width)

    // Multiple Time Machine drives number TM1, TM2.
    state.disks.append(
      UserDiskVolume(
        path: "/Volumes/Backups 2", freeBytes: 2_000_000_000_000, totalBytes: nil,
        kind: .hdd, isTimeMachine: true, isInternal: false))
    XCTAssertEqual(CompactBar.cells(for: state).suffix(2).map(\.label), ["TM1", "TM2"])
  }

  func testDiskClassificationAndDiskImageFiltering() {
    XCTAssertEqual(
      UserDiskVolume.classifyKind(
        mediumType: "Solid State", interconnect: "USB", modelNames: ["Extreme 55DD"], isStartup: false),
      .ssd)
    XCTAssertEqual(
      UserDiskVolume.classifyKind(
        mediumType: nil, interconnect: "USB", modelNames: ["PSSD T7"], isStartup: false),
      .ssd)
    XCTAssertEqual(
      UserDiskVolume.classifyKind(
        mediumType: nil, interconnect: "USB", modelNames: ["Elements 2667"], isStartup: false),
      .hdd)
    XCTAssertEqual(
      UserDiskVolume.classifyKind(
        mediumType: "Rotational", interconnect: "SATA", modelNames: ["SSD-looking"], isStartup: false),
      .hdd)
    XCTAssertTrue(UserDiskVolume.isDiskImage(protocolName: "Virtual Interface", modelName: "Disk Image"))
    XCTAssertFalse(UserDiskVolume.isDiskImage(protocolName: "USB", modelName: "PSSD T7"))
  }

  func testDiskCellsExcludeSystemMountsAndNestedSnapshots() {
    for path in ["/", UserDiskVolume.dataPath, "/Volumes/Backups", "/Volumes/TTH Work"] {
      XCTAssertTrue(UserDiskVolume.isUserMount(path))
    }
    for path in ["/Volumes/", "/Volumes/.hidden", "/Volumes/.timemachine/id/snapshot",
                 "/Volumes/Backups/snapshot", "/System/Volumes/Preboot", "/dev"] {
      XCTAssertFalse(UserDiskVolume.isUserMount(path))
    }
  }

  func testSafariSoundMenuListsOnlyPages() {
    XCTAssertEqual(NowPlayingBrowserFocus.soundTitles(from: ["Mute This Tab", "", "Tab With Sound", "A", ""]), ["A"])
    XCTAssertEqual(NowPlayingBrowserFocus.soundTitles(from: ["Tabs With Sound", "A", "B", "", "Other"]), ["A", "B"])
    XCTAssertEqual(NowPlayingBrowserFocus.soundTitleCounts(from: ["Tabs With Sound", "YouTube", "YouTube", ""]), ["YouTube": 2])
    XCTAssertTrue(NowPlayingBrowserFocus.soundTitles(from: ["Mute All Tabs"]).isEmpty)
  }

  func testDuplicateAndStaleSafariSoundCandidateSelection() {
    let tabA = NowPlayingBrowserFocus.CandidateTab(windowIndex: 0, tabIndex: 0, rawTitle: "YouTube - Audio playing", hasDirectAudioSignal: true)
    let silentTwin = NowPlayingBrowserFocus.CandidateTab(windowIndex: 1, tabIndex: 0, rawTitle: "YouTube", hasDirectAudioSignal: false)
    // Direct AX match (even with AX audio suffix) satisfies count=1; silent twin must NOT be promoted.
    XCTAssertEqual(
      NowPlayingBrowserFocus.selectAudibleCandidates(allTabs: [tabA, silentTwin], soundTitleCounts: ["YouTube": 1]),
      [tabA])

    // Both narrow twins audible (count=2, pool=2) -> both promoted.
    let narrowA = NowPlayingBrowserFocus.CandidateTab(windowIndex: 0, tabIndex: 0, rawTitle: "YouTube", hasDirectAudioSignal: false)
    let narrowB = NowPlayingBrowserFocus.CandidateTab(windowIndex: 1, tabIndex: 2, rawTitle: "YouTube", hasDirectAudioSignal: false)
    XCTAssertEqual(
      NowPlayingBrowserFocus.selectAudibleCandidates(allTabs: [narrowA, narrowB], soundTitleCounts: ["YouTube": 2]),
      [narrowA, narrowB])

    // Ambiguous (count=1, pool=2) -> neither guessed.
    XCTAssertEqual(
      NowPlayingBrowserFocus.selectAudibleCandidates(allTabs: [narrowA, narrowB], soundTitleCounts: ["YouTube": 1]),
      [])
  }

  @MainActor
  func testSafariSoundCountsClearOnCloseAndDirectOpenWithoutPrepare() {
    guard #available(macOS 14.4, *) else { return }
    let section = NowPlayingMenuSection()
    section.enumerate = { [] }
    section.prepareForMenu(soundCounts: ["Dopethrone": 1])
    XCTAssertEqual(section.safariSoundCounts, ["Dopethrone": 1])
    section.open()
    XCTAssertEqual(section.safariSoundCounts, ["Dopethrone": 1])
    section.close()
    XCTAssertTrue(section.safariSoundCounts.isEmpty)

    // Opening directly without prepareForMenu never retains previous sound counts.
    section.open()
    XCTAssertTrue(section.safariSoundCounts.isEmpty)
    section.close()
  }

  func testFaviconHostGuardAndAutomationDenialCooldown() {
    let row = NowPlayingMenuSection.AppRow(
      app: nil, pid: 42, name: "Home", levels: [], url: "https://new.example.com/watch")
    XCTAssertTrue(
      NowPlayingMenuSection.shouldApplyFavicon(
        rowKey: row.key, expectedHost: "new.example.com", currentRow: row))
    XCTAssertFalse(
      NowPlayingMenuSection.shouldApplyFavicon(
        rowKey: row.key, expectedHost: "old.example.com", currentRow: row))

    NowPlayingBrowserFocus.resetAutomationDenials()
    NowPlayingBrowserFocus.recordAutomationDenial("com.apple.Safari", now: 100)
    XCTAssertTrue(NowPlayingBrowserFocus.isAutomationDenied("com.apple.Safari", now: 110))
    XCTAssertFalse(
      NowPlayingBrowserFocus.isAutomationDenied(
        "com.apple.Safari", now: 100 + NowPlayingBrowserFocus.automationDenialCooldown))
    NowPlayingBrowserFocus.resetAutomationDenials()
  }

  func testNowPlayingFaviconRequestsAndBrowserTabMatching() {
    let rawURL = "https://user:pass@www.youtube.com:443/watch?v=eaMbKZPBruU&t=779s#top"
    XCTAssertEqual(
      NowPlayingFaviconCache.requestURL(for: rawURL)?.absoluteString,
      "https://www.google.com/s2/favicons?sz=128&domain=www.youtube.com")
    XCTAssertNil(NowPlayingFaviconCache.requestURL(for: "file:///tmp/local.html"))
    XCTAssertNil(NowPlayingFaviconCache.requestURL(for: "safari-extension://abc"))

    XCTAssertEqual(
      NowPlayingBrowserFocus.cleanTabTitle(
        "Dopethrone - YouTube - Part of group Music - Memory usage - 429 MB - Audio playing"),
      "Dopethrone - YouTube")

    let scriptTabs = [
      NowPlayingBrowserFocus.ScriptTab(
        windowIndex: 1, tabIndex: 1, title: "ReVanced", url: "https://revanced.app/"),
      NowPlayingBrowserFocus.ScriptTab(
        windowIndex: 2, tabIndex: 1,
        title: "Electric Wizard - Dopethrone (2000) full album - YouTube",
        url: "https://www.youtube.com/watch?v=eaMbKZPBruU"),
    ]
    let matched = NowPlayingBrowserFocus.matchScriptTab(
      axTitle: "Electric Wizard - Dopethrone (2000) full album - YouTube - Audio playing",
      windowIndex: 1, tabIndex: 0, scriptTabs: scriptTabs)
    XCTAssertEqual(matched?.windowIndex, 2)
    XCTAssertEqual(matched?.tabIndex, 1)
    XCTAssertEqual(matched?.url, "https://www.youtube.com/watch?v=eaMbKZPBruU")

    // Duplicate titles in equal-count windows with identical tab strips must return nil rather than cross tabs.
    let identicalDupTabs = [
      NowPlayingBrowserFocus.ScriptTab(windowIndex: 1, tabIndex: 1, title: "YouTube", url: "https://a.example/"),
      NowPlayingBrowserFocus.ScriptTab(windowIndex: 2, tabIndex: 1, title: "YouTube", url: "https://b.example/"),
    ]
    XCTAssertNil(
      NowPlayingBrowserFocus.matchScriptTab(
        axTitle: "YouTube", windowIndex: 0, tabIndex: 0, scriptTabs: identicalDupTabs,
        axWindowTabTitles: ["YouTube"]))

    // Distinct window tab strips independently verify window pairing even when AX/AppleScript window orders differ.
    let distinctWindowTabs = [
      NowPlayingBrowserFocus.ScriptTab(windowIndex: 1, tabIndex: 1, title: "Docs", url: "https://docs.example/"),
      NowPlayingBrowserFocus.ScriptTab(windowIndex: 1, tabIndex: 2, title: "YouTube", url: "https://a.example/"),
      NowPlayingBrowserFocus.ScriptTab(windowIndex: 2, tabIndex: 1, title: "Mail", url: "https://mail.example/"),
      NowPlayingBrowserFocus.ScriptTab(windowIndex: 2, tabIndex: 2, title: "YouTube", url: "https://b.example/"),
    ]
    XCTAssertEqual(
      NowPlayingBrowserFocus.matchScriptTab(
        axTitle: "YouTube", windowIndex: 0, tabIndex: 1, scriptTabs: distinctWindowTabs,
        axWindowTabTitles: ["Mail", "YouTube"])?.url,
      "https://b.example/")
  }
}
