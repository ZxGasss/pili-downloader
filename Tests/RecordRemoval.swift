import AppKit
import Foundation

@main struct RecordRemovalTests {
    @MainActor static func main() throws {
        precondition(Bundle.main.bundleIdentifier?.contains(".preview") == true)
        let base = TaskHistory.base
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let media = base.appendingPathComponent("owned-fixture.mp4")
        let partial = base.appendingPathComponent("owned-fixture.part")
        let bytes = Data("owned test fixture".utf8)
        try bytes.write(to: media); try bytes.write(to: partial)
        let parent = AppModel(), child = AppModel(), grandchild = AppModel(), other = AppModel()
        child.parentID = parent.id; grandchild.parentID = child.id
        parent.phase = "下载完成"
        parent.completedItems = [CompletedDownload(path: media.path, title: "自有夹具", source: "https://example.invalid/owned", identifier: "owned", finishedAt: Date())]
        let store = TaskStore.shared
        child.busy = true
        precondition(!store.archive(parent.id) && !parent.archived)
        child.busy = false; other.busy = true
        precondition(store.archive(parent.id))
        precondition(parent.archived && child.archived && grandchild.archived && !other.archived)
        let records = try TaskHistory.read()
        let restored = AppModel(record: records.first { $0.id == parent.id }!, register: false)
        precondition(restored.archived && restored.completedItems.first?.path == media.path)
        let mediaAfter = try Data(contentsOf: media), partialAfter = try Data(contentsOf: partial)
        precondition(mediaAfter == bytes && partialAfter == bytes)
        precondition(store.restore(parent.id))
        precondition(!parent.archived && !child.archived && !grandchild.archived)
        let persisted = try TaskHistory.read()
        precondition(persisted.first { $0.id == parent.id }?.archived == false)
        let old = try JSONEncoder().encode(parent.record)
        var object = try JSONSerialization.jsonObject(with: old) as! [String: Any]
        object.removeValue(forKey: "archived")
        let legacy = try JSONDecoder().decode(TaskRecord.self, from: JSONSerialization.data(withJSONObject: object))
        precondition(!AppModel(record: legacy, register: false).archived)
        precondition(store.archive(parent.id))
        precondition(store.deleteArchived(parent.id))
        let afterDelete = try TaskHistory.read()
        precondition(!afterDelete.contains { [parent.id, child.id, grandchild.id].contains($0.id) })
        precondition(FileManager.default.fileExists(atPath: media.path) && FileManager.default.fileExists(atPath: partial.path))
        print("RECORD_REMOVAL_PASS: active child protected; descendants persisted; unrelated task untouched; files/parts retained; restored; archived record permanently removed; old history compatible")
    }
}
