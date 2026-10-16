import SwiftUI
import AppKit

@main
enum QuickSearchTests {
    static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool) { precondition(value()); checks += 1 }
        let a = Snippet(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "Firma", abbreviation: ";sig", content: "Cordiali saluti", aliases: [";signature"])
        var b = Snippet(title: "Data", abbreviation: ";oggi", content: "Oggi è {{date}}", useCount: 4)
        check(SnippetSearch.results([a, b], query: "SALUTI").map(\.id) == [a.id])
        check(SnippetSearch.results([a, b], query: ";signature").map(\.id) == [a.id])
        check(SnippetSearch.results([a, b], query: "firma").map(\.id) == [a.id])
        check(SnippetSearch.results([a, b], query: "").map(\.id) == [b.id, a.id])
        b.enabled = false
        check(SnippetSearch.results([a, b], query: "oggi").isEmpty)
        let c = Snippet(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "Firma", content: "Seconda firma")
        check(SnippetSearch.results([c, a], query: "").map(\.id) == [a.id, c.id])
        check(SnippetSearch.moving(a.id, by: 1, in: [a, c]) == c.id)
        check(SnippetSearch.moving(c.id, by: -1, in: [a, c]) == a.id)
        check(SnippetSearch.moving(a.id, by: -1, in: [a, c]) == a.id)
        check(SnippetSearch.moving(c.id, by: 1, in: [a, c]) == c.id)
        check(SnippetSearch.moving(nil, by: 1, in: [a, c]) == a.id)
        check(SnippetSearch.moving(nil, by: -1, in: [a, c]) == c.id)
        check(SnippetSearch.moving(a.id, by: 1, in: []) == nil)
        check(SnippetPreview.text(a) == "Cordiali saluti")
        check(SnippetPreview.text(Snippet(content: "Prima\n  seconda\t terza")) == "Prima seconda terza")
        check(SnippetPreview.text(Snippet(content: String(repeating: "x", count: 500))).count == 240)
        let html = Snippet(content: "<html><head><style>hidden</style></head><body><p>Ciao &amp; benvenuto</p><p>&#x1F642; &#232;</p><img src='https://example.invalid/private'></body></html>", kind: .html)
        check(SnippetPreview.text(html) == "Ciao & benvenuto 🙂 è")
        check(SnippetPreview.text(Snippet(content: "<script>not executed</script>Visibile", kind: .rich)) == "Visibile")
        check(SnippetPreview.text(Snippet(content: "&amp;lt;", kind: .html)) == "&lt;")
        check(SnippetPreview.text(Snippet(content: "/tmp/picture.png", kind: .image)) == "Immagine: picture.png")
        check(SnippetPreview.text(Snippet(content: "exit 1", kind: .shell)) == "Script · eseguito solo all’inserimento")

        var query = ""; var selection: UUID? = a.id; var inserted: UUID?; var cancelled = false
        let field = QuickSearchField(query: Binding(get: { query }, set: { query = $0 }), move: { selection = SnippetSearch.moving(selection, by: $0, in: [a, c]) }, insert: { inserted = selection }, cancel: { cancelled = true })
        let delegate = field.makeCoordinator()
        let control = NSSearchField(); let editor = NSTextView()
        check(delegate.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        check(selection == c.id)
        check(delegate.control(control, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        check(inserted == c.id)
        check(delegate.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
        check(selection == a.id)
        check(!delegate.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        control.stringValue = "è 🙂"
        delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: control))
        check(query == "è 🙂")
        check(delegate.control(control, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        check(cancelled)
        print("Quick search: \(checks) search/preview/keyboard routing checks passed; no external input sent")
    }
}
