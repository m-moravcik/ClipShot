import Foundation
import Testing
@testable import ClipShot

struct CaptureMarkerTests {
    private func check(_ build: (URL) throws -> URL) throws -> Bool {
        let dir = try Fixtures.makeDir()
        return CaptureMarker.isScreenshot(try build(dir))
    }

    @Test func markedFileIsScreenshot() throws {
        #expect(try check { try Fixtures.write(named: "a.png", in: $0) })
    }
    @Test func markerFalseIsNotScreenshot() throws {
        #expect(try !check { try Fixtures.write(named: "a.png", in: $0, marker: .false) })
    }
    @Test func markerWithoutCaptureTypeIsNotScreenshot() throws {
        #expect(try !check { try Fixtures.write(named: "a.png", in: $0, captureType: false) })
    }
    @Test func unmarkedFileIsNotScreenshot() throws {
        #expect(try !check { try Fixtures.write(named: "a.png", in: $0, marker: .none) })
    }
    @Test func quarantinedFileIsNotScreenshot() throws {
        #expect(try !check { try Fixtures.write(named: "a.png", in: $0, quarantine: true) })
    }
    @Test func whereFromsFileIsNotScreenshot() throws {
        #expect(try !check { try Fixtures.write(named: "a.png", in: $0, whereFroms: true) })
    }
    @Test func integerOneMarkerCounts() throws {
        let dir = try Fixtures.makeDir()
        let url = try Fixtures.write(named: "a.png", in: dir, marker: .none)
        Fixtures.setxattr(CaptureMarker.captureFlag, Fixtures.bplist(1), on: url)
        Fixtures.setxattr(CaptureMarker.captureType, Fixtures.bplist("display"), on: url)
        #expect(CaptureMarker.isScreenshot(url))
    }
    @Test func exactBplistTrueBytes() throws {
        let dir = try Fixtures.makeDir()
        let url = try Fixtures.write(named: "a.png", in: dir, marker: .none)
        Fixtures.setxattr(CaptureMarker.captureFlag, Data([0x62,0x70,0x6C,0x69,0x73,0x74,0x30,0x30,0x09,0x08,0,0,0,0,0,0,1,1,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0x09]), on: url)
        Fixtures.setxattr(CaptureMarker.captureType, Fixtures.bplist("display"), on: url)
        #expect(CaptureMarker.isScreenshot(url))
    }
}
