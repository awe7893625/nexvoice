import XCTest
@testable import NexVoice

/// 票E（2026-08-30）回歸鎖：三個模式熱鍵以 ProductPreferences 為唯一來源（SSOT），
/// 舊 HotkeyProfileStore 值一次性遷移；偏好 blob 對 String/Data 雙型別防禦。
final class HotkeySSOTTests: XCTestCase {
    private func makeSuite(_ name: String) -> UserDefaults {
        let suite = UserDefaults(suiteName: "test.\(name).\(UUID().uuidString)")!
        suite.removePersistentDomain(forName: "test.\(name).\(UUID().uuidString)")
        return suite
    }

    // MARK: - load 型別防禦（真實事故：blob 被寫成 String → data(forKey:) nil →
    // 靜默回落預設，使用者設定無聲消失）

    func testLoadAcceptsDataBlob() throws {
        let defaults = makeSuite("data-blob")
        var prefs = ProductPreferences()
        prefs.translate = HotkeyProfile(trigger: .rightCommand, behavior: .toggle)
        ProductPreferencesStore.save(prefs, defaults)

        XCTAssertEqual(ProductPreferencesStore.load(defaults).translate.trigger, .rightCommand)
    }

    func testLoadAcceptsStringBlobInsteadOfSilentlyDroppingSettings() throws {
        let defaults = makeSuite("string-blob")
        var prefs = ProductPreferences()
        prefs.translate = HotkeyProfile(trigger: .rightCommand, behavior: .toggle)
        prefs.dictate = HotkeyProfile(trigger: .rightOption, behavior: .toggle)
        let data = try JSONEncoder().encode(prefs)
        let json = String(decoding: data, as: UTF8.self)
        defaults.set(json, forKey: "nexvoice.product.preferences")

        let loaded = ProductPreferencesStore.load(defaults)
        XCTAssertEqual(loaded.translate.trigger, .rightCommand)
        XCTAssertEqual(loaded.dictate.trigger, .rightOption)
    }

    func testLoadFallsBackToDefaultsOnCorruptBlob() {
        let defaults = makeSuite("corrupt-blob")
        defaults.set("not-json{", forKey: "nexvoice.product.preferences")

        let loaded = ProductPreferencesStore.load(defaults)
        XCTAssertEqual(loaded.dictate, .defaultProfile)
        XCTAssertEqual(loaded.translate, HotkeyProfile(trigger: .leftCommand, behavior: .toggle))
        XCTAssertEqual(loaded.ask, HotkeyProfile(trigger: .function, behavior: .toggle))
    }

    // MARK: - 舊主要觸發鍵遷移（SSOT）

    func testLegacyRecordKeyMigratesIntoProductPreferences() throws {
        let defaults = makeSuite("migrate")
        let store = HotkeyProfileStore(defaults: defaults)
        try store.save(HotkeyProfile(trigger: .rightOption, behavior: .toggle))
        // blob 的 dictate 值是歷史上死了的設定列殘留，必須被引擎真正用過的舊值覆蓋。
        var blob = ProductPreferences()
        blob.dictate = HotkeyProfile(trigger: .leftOption, behavior: .pushToTalk)
        ProductPreferencesStore.save(blob, defaults)

        let resolved = ProductPreferencesStore.resolvingLegacyRecordKey(defaults)
        XCTAssertEqual(resolved.dictate.trigger, .rightOption)
        XCTAssertEqual(resolved.dictate.behavior, .toggle)
        // 遷移立即落盤，重載不回頭。
        XCTAssertEqual(ProductPreferencesStore.load(defaults).dictate.trigger, .rightOption)
    }

    func testResolutionKeepsBlobDictateWhenNoLegacyProfileExists() {
        let defaults = makeSuite("no-legacy")
        var prefs = ProductPreferences()
        prefs.dictate = HotkeyProfile(trigger: .rightOption, behavior: .toggle)
        ProductPreferencesStore.save(prefs, defaults)
        // 沒存過舊 key：不得用 .defaultProfile（任意 Option）蓋掉 blob 值。
        XCTAssertEqual(ProductPreferencesStore.resolvingLegacyRecordKey(defaults).dictate.trigger, .rightOption)
    }

    func testLegacyMigrationIsOneShot() throws {
        let defaults = makeSuite("one-shot")
        try HotkeyProfileStore(defaults: defaults).save(HotkeyProfile(trigger: .rightOption, behavior: .toggle))
        _ = ProductPreferencesStore.resolvingLegacyRecordKey(defaults)

        // 遷移後使用者在 UI 把聽寫改成左 Control：舊 key 不得再蓋回來。
        var prefs = ProductPreferencesStore.load(defaults)
        prefs.dictate = HotkeyProfile(trigger: .leftControl, behavior: .toggle)
        ProductPreferencesStore.save(prefs, defaults)

        XCTAssertEqual(ProductPreferencesStore.resolvingLegacyRecordKey(defaults).dictate.trigger, .leftControl)
    }

    func testHasStoredProfileDistinguishesStoredFromDefault() throws {
        let defaults = makeSuite("has-stored")
        let store = HotkeyProfileStore(defaults: defaults)
        XCTAssertFalse(store.hasStoredProfile())
        try store.save(HotkeyProfile(trigger: .rightOption, behavior: .toggle))
        XCTAssertTrue(store.hasStoredProfile())
    }

    // MARK: - 三引擎 accept/reject 矩陣（預設 trigger × 修飾鍵掃描碼）

    func testDefaultModeTriggersRouteEventsToAtMostOneEngine() {
        // 引擎預設：dictate=任一Option、translate=左Cmd、ask=Fn。
        // Control 鍵（59/62）預設無人認領是合法狀態；重點是任何掃描碼
        // 不得被兩個引擎同時認領（事件互搶）。
        let engines: [(String, TriggerKey)] = [
            ("dictate", .option), ("translate", .leftCommand), ("ask", .function),
        ]
        let keyCodes: [(UInt16, String)] = [
            (58, "左Option"), (61, "右Option"), (55, "左Cmd"),
            (54, "右Cmd"), (59, "左Ctrl"), (62, "右Ctrl"), (63, "Fn"),
        ]

        for (keyCode, keyName) in keyCodes {
            let claimers = engines.filter { $0.1.accepts(keyCode: keyCode) }
            XCTAssertLessThanOrEqual(
                claimers.count, 1,
                "\(keyName) (kc=\(keyCode)) 被多個引擎搶：\(claimers.map(\.0))"
            )
        }
        // 三個預設觸發鍵各自被自己的引擎認領。
        XCTAssertEqual(engines.filter { $0.1.accepts(keyCode: 61) }.map(\.0), ["dictate"])
        XCTAssertEqual(engines.filter { $0.1.accepts(keyCode: 55) }.map(\.0), ["translate"])
        XCTAssertEqual(engines.filter { $0.1.accepts(keyCode: 63) }.map(\.0), ["ask"])
    }

    func testAskEngineToggleSequenceViaProfileTrigger() {
        // Fn（kc=63）按一下開始、再按一下結束（toggle 語意走 pressed→released 邊）。
        var engine = HotkeyGestureEngine(
            profile: HotkeyProfile(trigger: .function, behavior: .toggle)
        )
        XCTAssertEqual(engine.handle(.pressed, isRecording: false, canStart: true), .none)
        XCTAssertEqual(engine.handle(.released, isRecording: false, canStart: true), .startRecording)
        XCTAssertEqual(engine.handle(.pressed, isRecording: true, canStart: false), .none)
        XCTAssertEqual(engine.handle(.released, isRecording: true, canStart: false), .finishRecording)
    }

    func testSetProfileResetsStuckTriggerState() {
        var engine = HotkeyGestureEngine(
            profile: HotkeyProfile(trigger: .function, behavior: .toggle)
        )
        _ = engine.handle(.pressed, isRecording: false, canStart: true)
        engine.setProfile(HotkeyProfile(trigger: .function, behavior: .pushToTalk))
        // setProfile 必須清掉卡住的 triggerIsDown，否則下一次按下被當成 chord 吞掉。
        XCTAssertEqual(engine.handle(.pressed, isRecording: false, canStart: true), .startRecording)
    }

    // MARK: - 三模式 profile 在偏好 blob 中各自獨立往返

    func testAllThreeModeProfilesRoundTripThroughBlob() throws {
        let defaults = makeSuite("round-trip")
        var prefs = ProductPreferences()
        prefs.dictate = HotkeyProfile(trigger: .rightOption, behavior: .toggle)
        prefs.translate = HotkeyProfile(trigger: .rightCommand, behavior: .pushToTalk)
        prefs.ask = HotkeyProfile(trigger: .function, behavior: .toggle)
        ProductPreferencesStore.save(prefs, defaults)

        let loaded = ProductPreferencesStore.load(defaults)
        XCTAssertEqual(loaded.dictate.trigger, .rightOption)
        XCTAssertEqual(loaded.translate.trigger, .rightCommand)
        XCTAssertEqual(loaded.translate.behavior, .pushToTalk)
        XCTAssertEqual(loaded.ask.trigger, .function)
        XCTAssertEqual(loaded.ask.behavior, .toggle)
    }
}
