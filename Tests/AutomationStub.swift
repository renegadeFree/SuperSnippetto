import Foundation
final class DesktopController {
    static weak var current: DesktopController?
    let store: LibraryStore
    let engine: ExpansionEngine
    init(store: LibraryStore, engine: ExpansionEngine) { self.store = store; self.engine = engine; Self.current = self }
}
