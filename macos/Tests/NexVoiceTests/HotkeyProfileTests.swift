import Foundation
import XCTest
@testable import NexVoice

final class HotkeyProfileTests: XCTestCase {
    private func withIsolatedStore(_ body: (UserDefaults, HotkeyProfileStore) throws -> Void) rethrows {
        let suiteName = "NexVoiceTests.HotkeyProfile.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            // removePersistentDomain only clears cfprefsd's in-memory cache; it
            // does not reliably delete the backing plist cfprefsd already wrote
            // to ~/Library/Preferences, so every run leaked one file per test.
            let plistURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suiteName).plist")
            try? FileManager.default.removeItem(at: plistURL)
        }
        try body(defaults, HotkeyProfileStore(defaults: defaults))
    }

    func testDefaultIsSingleOptionToggle() {
        XCTAssertEqual(HotkeyProfile.defaultProfile.trigger, .option)
        XCTAssertEqual(HotkeyProfile.defaultProfile.behavior, .toggle)
        XCTAssertEqual(
            HotkeyProfile.defaultProfile.schemaVersion,
            HotkeyProfile.currentSchemaVersion
        )
    }

    func testAllSupportedProfilesRoundTripThroughCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for trigger in TriggerKey.allCases {
            for behavior in TriggerBehavior.allCases {
                let profile = HotkeyProfile(trigger: trigger, behavior: behavior)
                let decoded = try decoder.decode(
                    HotkeyProfile.self,
                    from: encoder.encode(profile)
                )
                XCTAssertEqual(decoded, profile)
            }
        }
    }

    func testCustomPhysicalKeyCodeRoundTrips() throws {
        let profile = HotkeyProfile(trigger: .option, behavior: .pushToTalk, keyCode: 49)
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(HotkeyProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
        XCTAssertEqual(decoded.keyCode, 49)
    }

    func testStorePersistsInInjectedSuite() throws {
        try withIsolatedStore { defaults, store in
            let profile = HotkeyProfile(trigger: .rightOption, behavior: .pushToTalk)

            try store.save(profile)

            XCTAssertEqual(store.load(), profile)
            XCTAssertNotNil(defaults.data(forKey: HotkeyProfileStore.profileKey))
        }
    }

    func testMissingOrCorruptProfileFallsBackToDefault() {
        withIsolatedStore { defaults, store in
            XCTAssertEqual(store.load(), .defaultProfile)

            defaults.set(Data("not-json".utf8), forKey: HotkeyProfileStore.profileKey)
            XCTAssertEqual(store.load(), .defaultProfile)
        }
    }

    func testMigratesLegacyScalarKeysAndBehaviorAlias() {
        withIsolatedStore { defaults, store in
            defaults.set("left_option", forKey: "nexvoice.hotkey.trigger")
            defaults.set("hold", forKey: "nexvoice.hotkey.behavior")

            let profile = store.load()

            XCTAssertEqual(profile.trigger, .leftOption)
            XCTAssertEqual(profile.behavior, .pushToTalk)
            XCTAssertNotNil(defaults.data(forKey: HotkeyProfileStore.profileKey))
        }
    }

    func testDecodesUnversionedLegacyProfileObject() throws {
        let data = Data(#"{"triggerKey":"right-option","behavior":"push-to-talk"}"#.utf8)

        let profile = try JSONDecoder().decode(HotkeyProfile.self, from: data)

        XCTAssertEqual(profile.schemaVersion, HotkeyProfile.currentSchemaVersion)
        XCTAssertEqual(profile.trigger, .rightOption)
        XCTAssertEqual(profile.behavior, .pushToTalk)
    }

    func testFutureSchemaDoesNotOverrideSafeDefault() {
        withIsolatedStore { defaults, store in
            let future = Data(#"{"schemaVersion":999,"trigger":"rightCommand","behavior":"pushToTalk"}"#.utf8)
            defaults.set(future, forKey: HotkeyProfileStore.profileKey)

            XCTAssertEqual(store.load(), .defaultProfile)
        }
    }
}
