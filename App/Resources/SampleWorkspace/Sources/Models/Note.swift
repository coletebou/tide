import Foundation
import Observation

struct Note: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var body: String
    var created = Date()

    // TODO: support tags and pinning
    var isEmpty: Bool { title.isEmpty && body.isEmpty }
}

@Observable
final class NoteStore {
    private(set) var notes: [Note] = [
        Note(title: "Groceries", body: "Oat milk, coffee, limes"),
        Note(title: "Ideas", body: "A native code editor for iPad 🌊"),
    ]

    func add(_ note: Note) {
        notes.insert(note, at: 0)
    }

    func remove(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            notes.remove(at: index)
        }
    }

    /// Notes created within the last `days` days.
    func recent(days: Int = 7) -> [Note] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .distantPast
        return notes.filter { $0.created >= cutoff }
    }
}
