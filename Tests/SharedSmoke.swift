import Foundation

@main struct SharedSmoke {
    static func main() throws {
        let episodes = (1...24).map { Episode(id: "ep\($0)", index: $0, title: "测试\($0)", thumbnail: nil, url: URL(string: "https://www.bilibili.com/bangumi/play/ep\($0)")!, bvid: nil) }
        let batches = try EpisodeBatches.split(episodes, size: 10)
        precondition(batches.map { $0.first!.index } == [1,11,21] && batches.map(\.count) == [10,10,4])
        let larger = try EpisodeBatches.split(episodes, size: 20)
        precondition(larger.map { $0.first!.index } == [1,21])
        let estimate = PiliSharedCore.remainingSeconds(total: 20, completed: 2, completedBytes: 2000, estimatedBytesPerEpisode: nil, activeDownloaded: 0, bytesPerSecond: 200)
        precondition(estimate == 90)
        precondition(PiliSharedCore.columnCount(availableWidth: 320) == 1 && PiliSharedCore.columnCount(availableWidth: 768) == 2 && PiliSharedCore.columnCount(availableWidth: 1366) == 3)
        print("PASS shared core: 10/20 batches; 24-item tail; aggregate ETA; compact/tablet/wide and fold-width policy")
    }
}
