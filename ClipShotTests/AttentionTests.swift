import Foundation
import Testing
@testable import ClipShot

struct AttentionTests {
    private let folder = URL(fileURLWithPath: "/tmp/Shots")
    private let other = URL(fileURLWithPath: "/tmp/Other")

    private func from(
        destination: CaptureDestination = .file, watchError: WatchError? = nil,
        copyFailure: Date? = nil, refusal: Refusal? = nil
    ) -> [Attention] {
        Attention.from(destination: destination, watchError: watchError, copyFailure: copyFailure,
                       retentionRefusal: refusal, folder: folder)
    }

    @Test func nothingWhenAllIsWell() {
        #expect(from().isEmpty)
    }

    @Test func eachInputMapsToItsCase() {
        #expect(from(destination: .clipboard) == [.destinationNotFile])
        #expect(from(destination: .other("x")) == [.destinationNotFile])
        #expect(from(watchError: .folderMissing(other)) == [.folderMissing(other)])
        #expect(from(watchError: .folderRemoved(other)) == [.folderMissing(other)])
        #expect(from(watchError: .accessDenied(other)) == [.folderAccessDenied(other)])
        #expect(from(copyFailure: Date()) == [.couldNotCopy])
        #expect(from(refusal: .notConfirmed) == [.retentionFolderChanged(folder)])
        #expect(from(refusal: .noTrash) == [.noTrash(folder)])
    }

    @Test func systemOrBroadRaisesNothing() {
        #expect(from(refusal: .systemOrBroad).isEmpty)
    }

    @Test func orderedBySeverity() {
        let all = from(destination: .clipboard, watchError: .accessDenied(other),
                       copyFailure: Date(), refusal: .noTrash)
        #expect(all == [.destinationNotFile, .folderAccessDenied(other), .couldNotCopy, .noTrash(folder)])
        let missing = from(destination: .clipboard, watchError: .folderMissing(other),
                           copyFailure: Date(), refusal: .notConfirmed)
        #expect(missing == [.destinationNotFile, .folderMissing(other), .couldNotCopy,
                            .retentionFolderChanged(folder)])
    }

    @Test func idsAreStableAndDistinct() {
        let items: [Attention] = [.destinationNotFile, .folderMissing(folder), .folderAccessDenied(folder),
                                  .couldNotCopy, .retentionFolderChanged(folder), .noTrash(folder)]
        #expect(Set(items.map(\.id)).count == items.count)
        #expect(Attention.folderMissing(folder).id == Attention.folderMissing(folder).id)
        #expect(Attention.folderMissing(folder).id != Attention.folderMissing(other).id)
    }
}
