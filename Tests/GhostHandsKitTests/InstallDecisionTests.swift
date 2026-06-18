import Foundation
import XCTest
@testable import GhostHandsKit

/// Hermetic — the PURE `install` decisions on FABRICATED inputs. NEVER mounts a
/// DMG, runs hdiutil, or writes /Applications: every input is a hand-built plist
/// `Data`, a fabricated array of entry names, or a pair of booleans. Mirrors
/// PixelVerdictTests / ShotDecisionTests (drive the pure `decide`-style funcs,
/// assert enum equality).
final class InstallDecisionTests: XCTestCase {

    // MARK: helper — fabricate a plist Data with no real mount

    private func plistData(_ obj: Any) -> Data {
        // .xml so it round-trips through PropertyListSerialization like hdiutil's.
        try! PropertyListSerialization.data(
            fromPropertyList: obj, format: .xml, options: 0)
    }

    // MARK: 1. mount-plist → mount-point parse

    func testMountPointPicksTheEntityWithAMountPoint() {
        // Several system-entities (whole disk + slices); only one has mount-point.
        let data = plistData([
            "system-entities": [
                ["content-hint": "GUID_partition_scheme", "dev-entry": "/dev/disk4"],
                ["mount-point": "/Volumes/MyApp", "dev-entry": "/dev/disk4s1"],
            ],
        ])
        XCTAssertEqual(Install.mountPoint(fromAttachPlist: data), "/Volumes/MyApp")
    }

    func testMountPointSkipsEmptyMountPointStrings() {
        // An empty mount-point string is NOT a real mount → keep scanning.
        let data = plistData([
            "system-entities": [
                ["mount-point": "", "dev-entry": "/dev/disk4"],
                ["mount-point": "/Volumes/Real", "dev-entry": "/dev/disk4s1"],
            ],
        ])
        XCTAssertEqual(Install.mountPoint(fromAttachPlist: data), "/Volumes/Real")
    }

    func testNoMountPointEntityYieldsNil() {
        // hdiutil listed entities but none mounted ⇒ honest no-evidence (nil).
        let data = plistData([
            "system-entities": [
                ["content-hint": "GUID_partition_scheme", "dev-entry": "/dev/disk4"],
                ["dev-entry": "/dev/disk4s1"],
            ],
        ])
        XCTAssertNil(Install.mountPoint(fromAttachPlist: data))
    }

    func testMalformedOrEmptyDataYieldsNil() {
        XCTAssertNil(Install.mountPoint(fromAttachPlist: Data()))
        XCTAssertNil(Install.mountPoint(fromAttachPlist: Data("not a plist".utf8)))
        // A plist whose root isn't a dict ⇒ nil.
        XCTAssertNil(Install.mountPoint(fromAttachPlist: plistData(["a", "b"])))
        // Right shape but system-entities missing ⇒ nil.
        XCTAssertNil(Install.mountPoint(fromAttachPlist: plistData(["other": 1])))
    }

    // MARK: 2. listing → chosen .app

    func testExactlyOneAppIsChosen() {
        XCTAssertEqual(
            Install.chooseApp(in: ["Foo.app", "Applications", ".background", "README"]),
            .one("Foo.app"))
    }

    func testZeroAppsIsNone() {
        XCTAssertEqual(
            Install.chooseApp(in: ["README", ".DS_Store", "Applications"]),
            .none)
    }

    func testEmptyListingIsNone() {
        XCTAssertEqual(Install.chooseApp(in: []), .none)
    }

    func testTwoAppsAreAmbiguous() {
        XCTAssertEqual(
            Install.chooseApp(in: ["B.app", "A.app"]),
            .ambiguous(["A.app", "B.app"]))   // sorted for a stable message
    }

    func testAppSuffixIsCaseInsensitive() {
        // A .App / .APP spelling still counts as an app bundle.
        XCTAssertEqual(Install.chooseApp(in: ["Foo.App"]), .one("Foo.App"))
    }

    // MARK: 3. overwrite / --force gate — four arms

    func testGateDestFreeAllows() {
        XCTAssertEqual(Install.overwriteDecision(destExists: false, force: false), .allow)
    }

    func testGateDestExistsNoForceRefuses() {
        // The don't-clobber refuse — the core safety gate.
        XCTAssertEqual(Install.overwriteDecision(destExists: true, force: false), .refuseExists)
    }

    func testGateDestExistsWithForceOverwrites() {
        XCTAssertEqual(Install.overwriteDecision(destExists: true, force: true), .allowOverwrite)
    }

    func testGateDestFreeWithForceStillAllows() {
        // --force with nothing in the way is a plain allow (no overwrite needed).
        XCTAssertEqual(Install.overwriteDecision(destExists: false, force: true), .allow)
    }

    // MARK: 4. verify decision — the honesty core

    func testVerifiedNeedsBundleAndNonEmptyId() {
        XCTAssertEqual(
            Install.verifyDecision(bundleExists: true, bundleIdentifier: "com.x.app"),
            .verified(id: "com.x.app"))
    }

    func testNilIdIsDispatchedUnverified() {
        XCTAssertEqual(
            Install.verifyDecision(bundleExists: true, bundleIdentifier: nil),
            .dispatchedUnverified)
    }

    func testEmptyIdIsDispatchedUnverified() {
        // An empty CFBundleIdentifier is NOT proof of a valid bundle.
        XCTAssertEqual(
            Install.verifyDecision(bundleExists: true, bundleIdentifier: ""),
            .dispatchedUnverified)
    }

    func testNoBundleIsDispatchedUnverifiedEvenWithId() {
        // No bundle at the destination ⇒ can't be verified even with an id string:
        // a 0-status cp NEVER auto-upgrades to verified.
        XCTAssertEqual(
            Install.verifyDecision(bundleExists: false, bundleIdentifier: "com.x.app"),
            .dispatchedUnverified)
    }

    // MARK: Info.plist → CFBundleIdentifier (pure, same machinery as the verify)

    func testBundleIdentifierFromInfoPlist() {
        let data = plistData(["CFBundleIdentifier": "com.example.Foo", "CFBundleName": "Foo"])
        XCTAssertEqual(Install.bundleIdentifier(fromInfoPlist: data), "com.example.Foo")
    }

    func testBundleIdentifierMissingOrEmptyIsNil() {
        XCTAssertNil(Install.bundleIdentifier(fromInfoPlist: plistData(["CFBundleName": "Foo"])))
        XCTAssertNil(Install.bundleIdentifier(fromInfoPlist: plistData(["CFBundleIdentifier": ""])))
        XCTAssertNil(Install.bundleIdentifier(fromInfoPlist: Data()))
    }

    // MARK: pure path/string logic — default dest + dest/<App>.app join

    func testDefaultDestIsApplications() {
        XCTAssertEqual(Install.defaultDest, "/Applications")
    }

    func testDestinationPathJoin() {
        XCTAssertEqual(
            Install.destinationPath(dest: "/Applications", appName: "Foo.app"),
            "/Applications/Foo.app")
        // Trailing slash on dest is normalized by appendingPathComponent.
        XCTAssertEqual(
            Install.destinationPath(dest: "/Applications/", appName: "Foo.app"),
            "/Applications/Foo.app")
    }
}
