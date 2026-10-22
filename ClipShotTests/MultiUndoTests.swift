import Foundation
import Testing
@testable import ClipShot

/// Several moves to the Trash one after another (A6, 0.9.2, the owner's "Undo stays only at the
/// first one"): every move keeps its own strip in its own place and its own Undo, one shared
/// window ends them all 5 s after the latest move, ⌘Z puts back the latest first.
@MainActor
struct MultiUndoTests {
    /// Screenshots ClipShot saw being taken, `minutes` old each, in the ledger.
    @discardableResult
    private func tracked(_ h: ModelHarness, _ names: [(String, Double)]) async throws -> [CaptureFile] {
        let now = Date()
        var files: [CaptureFile] = []
        for (name, minutes) in names {
            let date = now.addingTimeInterval(-minutes * 60)
            let url = try Fixtures.write(named: name, in: h.folder, created: date, modified: date)
            files.append(try #require(CaptureFile.inspect(url)))
        }
        for file in files { await h.ledger.record(file) }
        return files
    }

    /// Seven screenshots, G the newest; the list shows G, F, E, D.
    private func sevenShots(_ h: ModelHarness) async throws -> [String: CaptureFile] {
        let files = try await tracked(h, [
            ("A.png", 70), ("B.png", 60), ("C.png", 50), ("D.png", 40), ("E.png", 30), ("F.png", 20), ("G.png", 10),
        ])
        #expect(await h.start())
        #expect(await eventually { await self.slots(h) == ["G.png", "F.png", "E.png", "D.png"] })
        return Dictionary(uniqueKeysWithValues: files.map { ($0.url.lastPathComponent, $0) })
    }

    /// The list as shown: names, an Undo strip as "undo:<name>".
    private func slots(_ h: ModelHarness) -> [String] {
        h.model.recentSlots.map { slot in
            if case .trashed(let file) = slot { "undo:" + file.url.lastPathComponent } else { slot.file.url.lastPathComponent }
        }
    }

    private func pending(_ h: ModelHarness) -> [String] {
        h.model.undoables.map(\.file.url.lastPathComponent)
    }

    // MARK: - Strips

    /// The owner's case: three rows moved to the Trash one after another, each from the list
    /// as it is then. Every one keeps a strip in its own place; the rows between stay; the
    /// older screenshots read in meanwhile wait for the window to end.
    @Test func everyMoveKeepsItsOwnStripInPlace() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let shots = try await sevenShots(h)

        await h.model.moveToTrash(try #require(shots["F.png"]))
        #expect(await h.recentSettled())
        #expect(slots(h) == ["G.png", "undo:F.png", "E.png", "D.png"])
        await h.model.moveToTrash(try #require(shots["G.png"]))
        #expect(await h.recentSettled())
        #expect(slots(h) == ["undo:G.png", "undo:F.png", "E.png", "D.png"], "the first strip stays; the top row's takes its place")
        await h.model.moveToTrash(try #require(shots["D.png"]))
        #expect(await h.recentSettled())
        #expect(slots(h) == ["undo:G.png", "undo:F.png", "E.png", "undo:D.png"], "the most places the list has: no growing")
        #expect(pending(h) == ["F.png", "G.png", "D.png"], "in the order they were moved")
        #expect(h.model.latestUndo?.file == shots["D.png"], "⌘Z is the latest move's")
        #expect(h.announced.filter { $0 == Copy.Recent.moved.key }.count == 3, "each move is announced")
        #expect(h.alerts == 0)
    }

    /// The top row three times over, as fast as the list lets the user click it: three strips
    /// on top, newest first, not one strip that keeps naming the latest.
    @Test func theTopRowThreeTimesGivesThreeStrips() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        _ = try await sevenShots(h)
        for _ in 1...3 {
            let top = try #require(h.model.recentSlots.compactMap { slot -> CaptureFile? in
                if case .screenshot(let file) = slot { file } else { nil }
            }.first)
            await h.model.moveToTrash(top)
        }
        #expect(await h.recentSettled())
        #expect(slots(h) == ["undo:G.png", "undo:F.png", "undo:E.png", "D.png"])
    }

    /// Clicks faster than a move takes: the moves overlap and may finish in any order, but ⌘Z
    /// follows the order of the clicks.
    @Test func overlappingMovesKeepTheOrderOfTheClicks() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let shots = try await sevenShots(h)
        let clicks = try ["G.png", "E.png", "F.png"].map { try #require(shots[$0]) }
        let moves = clicks.map { file in Task { await h.model.moveToTrash(file) } }
        for move in moves { await move.value }
        #expect(pending(h) == ["G.png", "E.png", "F.png"])
        await h.model.putBack()
        #expect(RT.exists(clicks[2].url), "⌘Z put back the last one clicked")
        #expect(!RT.exists(clicks[0].url) && !RT.exists(clicks[1].url))
    }

    // MARK: - Shared window

    /// Each move gives every Undo on offer 5 s from it; once that is over, all strips go
    /// together and the older screenshots fill the rows, in order.
    @Test func oneWindowEndsAllStripsTogether() async throws {
        let clock = ManualTimerClock()
        let h = try ModelHarness(timerClock: clock)
        defer { h.tearDown() }
        let shots = try await sevenShots(h)

        await h.model.moveToTrash(try #require(shots["F.png"]))
        clock.advance(by: .seconds(4))
        await h.model.moveToTrash(try #require(shots["E.png"]))
        clock.advance(by: .seconds(4))
        await h.model.moveToTrash(try #require(shots["G.png"]))
        #expect(await eventually { clock.registered == 3 })
        clock.advance(by: .milliseconds(4_999))
        #expect(await h.recentSettled())
        #expect(slots(h) == ["undo:G.png", "undo:F.png", "undo:E.png", "D.png"], "13 s after the first move, all still there")
        clock.advance(by: .milliseconds(1))
        #expect(await eventually { await h.model.undoables.isEmpty })
        #expect(slots(h) == ["D.png", "C.png", "B.png", "A.png"], "the older screenshots fill the rows")
        #expect(h.model.previews.visible.isEmpty)
        #expect(await h.model.undoTrash() == false)
    }

    // MARK: - Putting back

    /// ⌘Z puts back the latest move still offering Undo, then the one before, and so on; once
    /// none is left it says so, as before.
    @Test func commandZPutsBackTheLatestFirst() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let shots = try await sevenShots(h)
        for name in ["F.png", "D.png", "G.png"] { await h.model.moveToTrash(try #require(shots[name])) }
        #expect(await h.recentSettled())
        #expect(slots(h) == ["undo:G.png", "undo:F.png", "E.png", "undo:D.png"])

        await h.model.putBack()
        #expect(slots(h) == ["G.png", "undo:F.png", "E.png", "undo:D.png"], "G back in its place, the others stay")
        await h.model.putBack()
        #expect(slots(h) == ["G.png", "undo:F.png", "E.png", "D.png"])
        await h.model.putBack()
        #expect(slots(h) == ["G.png", "F.png", "E.png", "D.png"])
        #expect(h.announced.filter { $0 == Copy.Recent.putBack.key }.count == 3)
        #expect(h.alerts == 0)

        await h.model.putBack()
        #expect(h.model.actionNote?.failure == .undo, "nothing left to put back")
        #expect(h.alerts == 1)
    }

    /// The Undo pill of a strip in the middle puts back that screenshot only; the other strips
    /// and the window stay as they are (an Undo does not extend it).
    @Test func undoOfAMiddleOneLeavesTheOthersAndTheWindow() async throws {
        let clock = ManualTimerClock()
        let h = try ModelHarness(timerClock: clock)
        defer { h.tearDown() }
        let shots = try await sevenShots(h)
        let f = try #require(shots["F.png"])
        for name in ["G.png", "F.png", "E.png"] { await h.model.moveToTrash(try #require(shots[name])) }
        #expect(await eventually { clock.registered == 3 })
        clock.advance(by: .seconds(3))

        await h.model.putBack(f)
        #expect(RT.exists(f.url))
        #expect(slots(h) == ["undo:G.png", "F.png", "undo:E.png", "D.png"])
        #expect(pending(h) == ["G.png", "E.png"])
        #expect(h.model.latestUndo?.file == shots["E.png"])

        clock.advance(by: .milliseconds(1_999))
        #expect(pending(h) == ["G.png", "E.png"], "a moment before 5 s after the latest move")
        clock.advance(by: .milliseconds(1))
        #expect(await eventually { await h.model.undoables.isEmpty }, "the Undo did not extend the window")
        #expect(await h.recentSettled())
        #expect(slots(h) == ["F.png", "D.png", "C.png", "B.png"])
    }

    /// A put-back that fails (another file took the name) is said in the note above the list
    /// and ends only that Undo.
    @Test func aFailedPutBackEndsOnlyThatUndo() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let shots = try await sevenShots(h)
        let f = try #require(shots["F.png"])
        for name in ["G.png", "F.png", "E.png"] { await h.model.moveToTrash(try #require(shots[name])) }
        try Fixtures.write(named: "F.png", contents: Fixtures.pngImage(size: 30), in: h.folder)

        await h.model.putBack(f)
        #expect(h.model.actionNote?.failure == .undo)
        #expect(h.alerts == 1)
        #expect(h.announced.last == Copy.Failure.undoFailed.key)
        #expect(pending(h) == ["G.png", "E.png"], "the other Undos stay")
        #expect(!h.model.recentSlots.contains(.trashed(f)), "its strip goes")

        let e = try #require(shots["E.png"])
        await h.model.putBack()
        #expect(RT.exists(e.url), "⌘Z still puts back the latest")
    }

    /// Two quick ⌘Z: the second goes to the move before the one being put back, so both
    /// come back, and nothing is said to have failed.
    @Test func twoQuickCommandZPutBackTwo() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let shots = try await sevenShots(h)
        for name in ["G.png", "F.png"] { await h.model.moveToTrash(try #require(shots[name])) }
        let first = Task { await h.model.putBack() }
        let second = Task { await h.model.putBack() }
        await first.value
        await second.value
        let g = try #require(shots["G.png"]), f = try #require(shots["F.png"])
        #expect(RT.exists(g.url))
        #expect(RT.exists(f.url))
        #expect(h.model.undoables.isEmpty)
        #expect(h.alerts == 0)
        #expect(h.model.actionNote == nil)
    }

    // MARK: - Counters and Peg

    /// Each move counts and lets the picture go; each Undo takes one off and grips it again;
    /// the latest moment wins.
    @Test func totalsAndPegFollowEachMoveAndUndo() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let shots = try await sevenShots(h)
        let before = h.preferences.totals.trashed
        await h.model.moveToTrash(try #require(shots["G.png"]))
        #expect(h.model.flashMoment == .release && h.model.flashPhase == 1)
        h.timer?.fire(2)
        await h.model.moveToTrash(try #require(shots["F.png"]))
        #expect(h.model.flashMoment == .release && h.model.flashPhase == 1, "a second move plays its release from the start")
        await h.model.moveToTrash(try #require(shots["E.png"]))
        #expect(h.preferences.totals.trashed == before + 3)

        await h.model.putBack()
        #expect(h.model.flashMoment == .grip && h.model.flashPhase == 1, "the grip replaces the release")
        #expect(h.preferences.totals.trashed == before + 2)
        let g = try #require(shots["G.png"])
        await h.model.putBack(g)
        #expect(h.preferences.totals.trashed == before + 1)
        #expect(h.model.flashMoment == .grip)
    }

    // MARK: - Previews

    /// Moved from three floating previews: each preview keeps its Undo and each strip its
    /// place in the list; the window ends them all together.
    @Test func previewsEachKeepTheirUndoUntilTheWindowEnds() async throws {
        let clock = ManualTimerClock()
        let h = try ModelHarness(timerClock: clock)
        defer { h.tearDown() }
        h.prefs["show-thumbnail"] = false
        try await tracked(h, [("A.png", 70), ("B.png", 60)])
        #expect(await h.start())
        #expect(await eventually { await h.model.previewMode == .clipShot })
        let now = Date()
        for index in 1...3 {
            // Taken seconds apart, so none counts as another display of the one before.
            let taken = now.addingTimeInterval(Double(index - 4) * 3)
            let url = try Fixtures.write(named: "Shot \(index).png", in: h.folder, created: taken, modified: taken)
            #expect(await eventually { await h.model.previews.visible.contains { $0.file.url == url } })
        }
        await h.model.ledgerSettled()
        #expect(await eventually { await self.slots(h) == ["Shot 3.png", "Shot 2.png", "Shot 1.png", "B.png"] })

        for item in h.model.previews.visible {
            await h.model.moveToTrash(item.file, fromPreview: item.id)
        }
        #expect(await h.recentSettled())
        #expect(h.model.previews.visible.count == 3)
        #expect(h.model.previews.visible.allSatisfy { $0.trashed }, "every preview offers its own Undo")
        #expect(slots(h) == ["undo:Shot 3.png", "undo:Shot 2.png", "undo:Shot 1.png", "B.png"])

        let middle = try #require(h.model.previews.visible.first { $0.file.url.lastPathComponent == "Shot 2.png" })
        await h.model.putBack(middle.file, fromPreview: middle.id)
        #expect(RT.exists(middle.file.url))
        #expect(!h.model.previews.visible.contains { $0.id == middle.id }, "used: that preview leaves")
        #expect(h.model.previews.visible.filter { $0.trashed }.count == 2, "the others still offer Undo")
        #expect(slots(h) == ["undo:Shot 3.png", "Shot 2.png", "undo:Shot 1.png", "B.png"])

        clock.advance(by: AppModel.defaultUndoLifetime)
        #expect(await eventually { await h.model.undoables.isEmpty })
        #expect(await eventually { await h.model.previews.visible.isEmpty }, "the window ended both previews' Undo")
    }

    // MARK: - Places

    /// Where the strips go, as a pure function of the rows and the moves.
    @Test func stripPlaces() throws {
        let now = Date()
        func file(_ name: String, _ minutes: Double) -> CaptureFile {
            CaptureFile(
                url: URL(fileURLWithPath: "/S/\(name)"), created: now.addingTimeInterval(-minutes * 60),
                modified: now, size: 1, resourceID: Data(name.utf8), isScreenshot: true)
        }
        func names(_ slots: [RecentSlot]) -> [String] {
            slots.map { slot in
                if case .trashed(let f) = slot { "undo:" + f.url.lastPathComponent } else { slot.file.url.lastPathComponent }
            }
        }
        func moved(_ list: (String, Double, Bool)...) -> [RecentScreenshots.Moved] {
            list.map { RecentScreenshots.Moved(file: file($0.0, $0.1), listed: $0.2) }
        }
        // The rows after G, F and D left the folder: the older ones read in meanwhile wait.
        let rest = [file("E", 30), file("C", 50), file("B", 60), file("A", 70)]
        #expect(names(RecentScreenshots.slots(files: rest, trashed: moved(("F", 20, true), ("G", 10, true), ("D", 40, true))))
                == ["undo:G", "undo:F", "E", "undo:D"])
        // A new screenshot meanwhile: it takes the top, the strips keep the last places, the
        // lowest row leaves.
        let withNew = [file("New", 1), file("E", 30), file("C", 50), file("B", 60)]
        #expect(names(RecentScreenshots.slots(files: withNew, trashed: moved(("D", 40, true), ("C2", 45, true))))
                == ["New", "E", "undo:D", "undo:C2"])
        // From a preview, not among the rows: on top, above a strip in its place.
        #expect(names(RecentScreenshots.slots(files: rest, trashed: moved(("Old", 90, false), ("D", 40, true))))
                == ["undo:Old", "E", "undo:D", "C"])
        // More moves than places: the latest keep theirs.
        #expect(names(RecentScreenshots.slots(files: [], trashed: moved(
            ("A", 70, true), ("B", 60, true), ("C", 50, true), ("D", 40, true), ("E", 30, false))))
                == ["undo:E", "undo:D", "undo:C", "undo:B"])
        // Fewer rows than places: no older screenshot to wait, the strips stay in time order.
        #expect(names(RecentScreenshots.slots(files: [file("B", 60)], trashed: moved(("A", 70, true), ("C", 50, true))))
                == ["undo:C", "B", "undo:A"])
    }
}
