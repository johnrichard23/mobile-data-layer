import DataLayer
import XCTest

final class ConflictResolverTests: XCTestCase {
    private struct Record: Syncable {
        var modifiedDate: Date?
        var deletionDate: Date?
    }

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }
    private func record(modified: TimeInterval? = nil, deleted: TimeInterval? = nil) -> Record {
        Record(modifiedDate: modified.map(date), deletionDate: deleted.map(date))
    }

    // MARK: - Neither deleted

    func testRemoteChangedMoreRecentlyIsTaken() {
        XCTAssertEqual(ConflictResolver.resolve(local: record(modified: 100), remote: record(modified: 200)), .takeRemote)
    }

    func testLocalChangedMoreRecentlyIsKept() {
        XCTAssertEqual(ConflictResolver.resolve(local: record(modified: 300), remote: record(modified: 200)), .keepLocal)
    }

    func testSameModifiedDateMeansNoChange() {
        XCTAssertEqual(ConflictResolver.resolve(local: record(modified: 200), remote: record(modified: 200)), .noChange)
    }

    func testMissingDatesFavourTheSideThatHasOne() {
        XCTAssertEqual(ConflictResolver.resolve(local: record(), remote: record(modified: 1)), .takeRemote)
        XCTAssertEqual(ConflictResolver.resolve(local: record(modified: 1), remote: record()), .keepLocal)
    }

    // MARK: - Deleted

    func testOnlyTheServerDeletedIt() {
        XCTAssertEqual(
            ConflictResolver.resolve(local: record(modified: 100), remote: record(modified: 50, deleted: 60)),
            .takeRemote
        )
    }

    func testOnlyTheDeviceDeletedIt() {
        XCTAssertEqual(
            ConflictResolver.resolve(local: record(modified: 100, deleted: 100), remote: record(modified: 50)),
            .keepLocal
        )
    }

    func testBothDeletedAndDeviceDeletedAfterTheServersLastChange() {
        XCTAssertEqual(
            ConflictResolver.resolve(
                local: record(modified: 100, deleted: 300),
                remote: record(modified: 200, deleted: 250)
            ),
            .keepLocal
        )
    }

    func testBothDeletedAndServerDeletedAfterTheDevicesLastChange() {
        XCTAssertEqual(
            ConflictResolver.resolve(
                local: record(modified: 100, deleted: 150),
                remote: record(modified: 400, deleted: 500)
            ),
            .takeRemote
        )
    }

    func testBothDeletedWithoutDatesToCompareChangesNothing() {
        XCTAssertEqual(
            ConflictResolver.resolve(local: record(deleted: 1), remote: record(deleted: 2)),
            .noChange
        )
    }
}
