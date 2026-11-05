import Foundation

/// A bounded heap: the smallest retained allocation (then lexically last path)
/// is at the root. Rejected entries don't allocate paths, and accepted entries
/// cost O(log limit), not a full sort for every file in a large dependency tree.
struct StorageFileSample {
    private var heap: [StorageFile] = []
    var sorted: [StorageFile] { heap.sorted { Self.worse($1, than: $0) } }

    mutating func consider(bytes: Int64, logicalBytes: Int64, shared: Bool, path: @autoclosure () -> String) {
        if heap.count == StorageFile.sampleLimit, bytes < heap[0].bytes { return }
        let file = StorageFile(path: path(), bytes: bytes, logicalBytes: logicalBytes, shared: shared)
        if heap.count < StorageFile.sampleLimit {
            heap.append(file)
            var index = heap.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard Self.worse(heap[index], than: heap[parent]) else { break }
                heap.swapAt(index, parent); index = parent
            }
        } else {
            guard Self.worse(heap[0], than: file) else { return }
            heap[0] = file
            var index = 0
            while index * 2 + 1 < heap.count {
                var child = index * 2 + 1
                if child + 1 < heap.count, Self.worse(heap[child + 1], than: heap[child]) { child += 1 }
                guard Self.worse(heap[child], than: heap[index]) else { break }
                heap.swapAt(index, child); index = child
            }
        }
    }

    private static func worse(_ left: StorageFile, than right: StorageFile) -> Bool {
        left.bytes == right.bytes ? left.path > right.path : left.bytes < right.bytes
    }
}
