import XCTest
@testable import PiliSharedCore

final class SharedCoreTests: XCTestCase {
    func testBatchesAndETA() throws {
        let episodes = (1...24).map { Episode(id: "ep\($0)", index: $0, title: "第\($0)集", thumbnail: nil,
            url: URL(string: "https://www.bilibili.com/bangumi/play/ep\($0)")!, bvid: nil) }
        let groups = try EpisodeBatches.split(episodes, size: 10)
        XCTAssertEqual(groups.map { $0.first!.index }, [1,11,21])
        XCTAssertEqual(groups.map(\.count), [10,10,4])
        XCTAssertEqual(try EpisodeBatches.split(episodes, size: 20).map { $0.first!.index }, [1,21])
        let estimate = SeasonEstimate.calculate(total: 20, completed: 2, completedBytes: 2000,
            fallbackBytesPerEpisode: nil, activeDownloaded: 0, bytesPerSecond: 200)
        XCTAssertEqual(estimate.seconds, 90)
        XCTAssertNil(PiliSharedCore.remainingSeconds(total: 20, completed: 0, completedBytes: 0,
            estimatedBytesPerEpisode: nil, activeDownloaded: 0, bytesPerSecond: 200))
    }
    func testAdaptiveWindowContract() {
        XCTAssertEqual(PiliSharedCore.columnCount(availableWidth: 320), 1)
        XCTAssertEqual(PiliSharedCore.columnCount(availableWidth: 768), 2)
        XCTAssertEqual(PiliSharedCore.columnCount(availableWidth: 1366), 3)
        XCTAssertEqual(PiliSharedCore.columnCount(availableWidth: 1366, largerText: true), 2)
        // A folded window can switch width without changing its task model.
        XCTAssertEqual(PiliSharedCore.columnCount(availableWidth: 390), 1)
    }
}
