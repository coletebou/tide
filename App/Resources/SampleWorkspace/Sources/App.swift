import SwiftUI

/// The entry point of a tiny notes app, used to show off Tide's Swift support.
@main
struct NotesApp: App {
    @State private var store = NoteStore()

    var body: some Scene {
        WindowGroup {
            NoteList(store: store)
        }
    }
}

struct NoteList: View {
    @Bindable var store: NoteStore
    @State private var query = ""

    private var filtered: [Note] {
        guard !query.isEmpty else { return store.notes }
        return store.notes.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { note in
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.title).font(.headline)
                    Text(note.body).lineLimit(2).foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query)
            .navigationTitle("Notes (\(store.notes.count))")
            .toolbar {
                Button("Add", systemImage: "plus") {
                    store.add(Note(title: "Untitled", body: ""))
                }
            }
        }
    }
}
