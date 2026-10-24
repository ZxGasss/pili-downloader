import Foundation
struct Episode { let id: String; let index: Int }
enum AppFailure: Error { case message(String) }
@main struct BatchRangeTest {
    static func main() throws {
        let episodes = (1...403).map { Episode(id: String($0), index: $0) }
        for size in [1, 7, 10, 20, 199, 200] {
            let groups = try EpisodeBatches.split(episodes, size: size)
            precondition(groups.flatMap { $0 }.map(\.id) == episodes.map(\.id))
            precondition(groups.allSatisfy { !$0.isEmpty && $0.count <= size })
            precondition(groups.count == (403 + size - 1) / size)
        }
        for size in [0, -1, 201] {
            var rejected = false
            do { _ = try EpisodeBatches.split(episodes, size: size) } catch { rejected = true }
            precondition(rejected)
        }
        print("BATCH_RANGE_PASS: 1/7/10/20/199/200; rejects -1/0/201; no missing or duplicated episodes")
    }
}
