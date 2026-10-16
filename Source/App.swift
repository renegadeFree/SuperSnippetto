import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ServiceManagement
import Combine
import Carbon

extension SnippetKind {
    var label: String {
        switch self { case .plain: return "Testo"; case .rich: return "Testo formattato"; case .html: return "HTML"; case .image: return "Immagine"; case .shell: return "Script shell"; case .appleScript: return "AppleScript"; case .javascript: return "JavaScript (JXA)" }
    }
    var isScript: Bool { [.shell, .appleScript, .javascript].contains(self) }
}
extension TriggerMode {
    var label: String {
        switch self { case .immediate: return "Appena digitata"; case .delimiterKeep: return "Dopo separatore, conservandolo"; case .delimiterDiscard: return "Dopo separatore, rimuovendolo"; case .manual: return "Solo menu o scorciatoia" }
    }
}
extension AppScope {
    var label: String { switch self { case .all: return "Tutte le app"; case .only: return "Solo queste app"; case .except: return "Tutte tranne queste app" } }
}

final class DesktopDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = DesktopController.current else { return .terminateNow }
        return controller.saveBeforeExit() ? .terminateNow : .terminateCancel
    }
}

final class DesktopController: ObservableObject {
    static weak var current: DesktopController?
    let store: LibraryStore
    let engine: ExpansionEngine
    let folderSync: LibraryFolderSync
    @Published var error: String?
    @Published var showingHelp = false
    @Published var showingBackups = false
    @Published var showingTrash = false
    private var quickPanel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    init(store: LibraryStore, engine: ExpansionEngine) {
        self.store = store; self.engine = engine; self.folderSync = LibraryFolderSync(store: store)
        Self.current = self
        engine.onError = { [weak self] message in DispatchQueue.main.async { self?.error = message } }
        engine.onShowSearch = { [weak self] in self?.showQuickSearch() }
        store.$data.dropFirst().debounce(for: .milliseconds(400), scheduler: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            do { try self.store.save(); self.engine.refreshHotkeys() }
            catch { self.error = error.localizedDescription }
        }.store(in: &cancellables)
        folderSync.start()
    }
    func showQuickSearch() {
        if quickPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "Cerca e inserisci"; panel.level = .floating; panel.isReleasedWhenClosed = false
            quickPanel = panel
        }
        quickPanel?.contentView = NSHostingView(rootView: QuickSearchView(store: store) { [weak self] snippet in
            self?.quickPanel?.orderOut(nil)
            self?.engine.expand(snippet)
        })
        quickPanel?.center(); quickPanel?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func importLibrary() {
        let panel = NSOpenPanel(); panel.title = "Importa frammenti"; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json, .commaSeparatedText, .propertyList, .data]
        panel.message = "JSON di SuperSnippetto o aText, CSV, raccolte TextExpander testuali o esportazioni .atext, anche legacy. Le conversioni incomplete sono segnalate e disattivate."
        let completed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            // Let AppKit close the sheet before SwiftUI updates its lists or shows an alert.
            DispatchQueue.main.async {
                guard let self else { return }
                do {
                    try self.store.importFile(url); try self.store.save()
                    if !self.store.lastImportWarnings.isEmpty {
                        let shown = self.store.lastImportWarnings.prefix(10).joined(separator: "\n\n")
                        let more = self.store.lastImportWarnings.count > 10 ? "\n\nAltri \(self.store.lastImportWarnings.count - 10) avvisi: consulta le note dei frammenti importati." : ""
                        self.error = "Importazione completata con avvisi.\n\n" + shown + more
                    }
                } catch { self.error = error.localizedDescription }
            }
        }
        if let window = NSApp.mainWindow { panel.beginSheetModal(for: window, completionHandler: completed) }
        else { panel.begin(completionHandler: completed) }
    }
    func exportLibrary() {
        let panel = NSSavePanel(); panel.title = "Esporta una copia"; panel.nameFieldStringValue = "SuperSnippetto.json"
        panel.allowedContentTypes = [.json, .commaSeparatedText]
        panel.message = "Usa .json per un backup completo o .csv per una tabella di frammenti."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.exportFile(url) } catch { self.error = error.localizedDescription }
    }
    func saveNow() { do { try store.save() } catch { self.error = error.localizedDescription } }
    func chooseSyncFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.title = "Cartella di sincronizzazione"; panel.message = "Scegli la stessa cartella sugli altri Mac: il tuo provider gestisce il trasferimento dei file. I conflitti vengono conservati come copie."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try folderSync.configure(folder: url) } catch { self.error = error.localizedDescription }
    }
    func chooseBackupFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.title = "Cartella dei backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let previous = store.data.backupFolder
        store.data.backupFolder = url.path
        do { try store.save() } catch { store.data.backupFolder = previous; self.error = error.localizedDescription }
    }
    func saveBeforeExit() -> Bool {
        do { try store.save(); return true }
        catch {
            let alert = NSAlert(); alert.messageText = "Salvataggio non riuscito"; alert.informativeText = error.localizedDescription + "\nEsporta una copia della libreria prima di uscire."
            alert.addButton(withTitle: "Torna alla libreria"); alert.runModal(); return false
        }
    }
}

@main
struct SuperSnippettoApp: App {
    @NSApplicationDelegateAdaptor(DesktopDelegate.self) var delegate
    @StateObject private var store: LibraryStore
    @StateObject private var engine: ExpansionEngine
    @StateObject private var controller: DesktopController
    init() {
        let store = LibraryStore(); let engine = ExpansionEngine(store: store)
        _store = StateObject(wrappedValue: store); _engine = StateObject(wrappedValue: engine)
        _controller = StateObject(wrappedValue: DesktopController(store: store, engine: engine))
    }
    var body: some Scene {
        WindowGroup("SuperSnippetto", id: "library") {
            LibraryView(store: store, engine: engine, controller: controller)
                .frame(minWidth: 1000, minHeight: 650)
                .onAppear { engine.start(); if let error = store.lastError { controller.error = error } }
                .alert("SuperSnippetto", isPresented: Binding(get: { controller.error != nil }, set: { if !$0 { controller.error = nil } })) {
                    Button("OK") { controller.error = nil }
                } message: { Text(controller.error ?? "") }
                .sheet(isPresented: $controller.showingHelp) { HelpView().frame(width: 760, height: 620) }
                .sheet(isPresented: $controller.showingBackups) { BackupBrowser(store: store, controller: controller).frame(width: 780, height: 570) }
                .sheet(isPresented: $controller.showingTrash) { TrashBrowser(store: store, controller: controller).frame(width: 780, height: 570) }
        }
        .commands {
            TextEditingCommands()
            TextFormattingCommands()
            CommandGroup(replacing: .newItem) {
                Button("Importa…", action: controller.importLibrary).keyboardShortcut("o")
                Button("Esporta…", action: controller.exportLibrary).keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Salva", action: controller.saveNow).keyboardShortcut("s")
                Divider()
                Button("Backup e ripristino…") { controller.showingBackups = true }
                Button("Cestino…") { controller.showingTrash = true }
            }
            CommandGroup(replacing: .help) { Button("Guida a SuperSnippetto") { controller.showingHelp = true } }
        }
        Settings { PreferencesView(store: store, engine: engine, controller: controller, sync: controller.folderSync).frame(width: 680, height: 700) }
        MenuBarExtra("SuperSnippetto", systemImage: "text.cursor") {
            MenuContent(store: store, engine: engine, controller: controller)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: ExpansionEngine
    @ObservedObject var controller: DesktopController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(engine.status)
        Toggle("Espansione attiva", isOn: Binding(get: { !store.data.paused }, set: { store.data.paused = !$0; if $0 { engine.start() } }))
        Button("Cerca e inserisci…", action: controller.showQuickSearch).keyboardShortcut(" ", modifiers: [.control, .option])
        Button("Apri libreria") { openWindow(id: "library"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        ForEach(store.data.snippets.filter { $0.enabled }.prefix(18)) { snippet in
            Button(snippet.title.isEmpty ? snippet.abbreviation : snippet.title) { engine.expand(snippet) }
        }
        Divider()
        Button("Importa…", action: controller.importLibrary)
        Button("Esporta…", action: controller.exportLibrary)
        Button("Backup e ripristino…") { controller.showingBackups = true; openWindow(id: "library"); NSApp.activate(ignoringOtherApps: true) }
        Button("Cestino…") { controller.showingTrash = true; openWindow(id: "library"); NSApp.activate(ignoringOtherApps: true) }
        Button("Guida") { controller.showingHelp = true; openWindow(id: "library"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button("Esci") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct LibraryView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: ExpansionEngine
    @ObservedObject var controller: DesktopController
    @State private var groupID: UUID?
    @State private var selectedID: UUID?
    @State private var query = ""
    @State private var groupName = ""
    @State private var namingGroup = false
    @State private var renameID: UUID?
    @State private var deletingSnippet = false
    var snippets: [Snippet] {
        store.data.snippets.filter { snippet in
            (groupID == nil || snippet.groupID == groupID) && (query.isEmpty || (snippet.title + " " + snippet.allAbbreviations.joined(separator: " ") + " " + snippet.content + " " + snippet.notes).localizedCaseInsensitiveContains(query))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var body: some View {
        NavigationSplitView {
            List {
                Button { groupID = nil } label: {
                    Label("Tutti i frammenti (\(store.data.snippets.count))", systemImage: "square.stack.3d.up")
                        .foregroundStyle(groupID == nil ? Color.accentColor : Color.primary)
                }.buttonStyle(.plain)
                Section("Raccolte") {
                    ForEach(store.data.groups) { group in
                        Button { groupID = group.id } label: {
                            HStack {
                                Label(group.name, systemImage: group.enabled ? "folder" : "folder.badge.minus")
                                    .padding(.leading, CGFloat(groupDepth(group.id)) * 12)
                                Spacer()
                                Text("\(store.data.snippets.filter { $0.groupID == group.id }.count)").foregroundStyle(.secondary)
                            }.foregroundStyle(groupID == group.id ? Color.accentColor : Color.primary)
                        }.buttonStyle(.plain)
                        .contextMenu {
                            Button("Rinomina…") { renameID = group.id; groupName = group.name; namingGroup = true }
                            Button(group.enabled ? "Disattiva raccolta" : "Attiva raccolta") { if let i = store.data.groups.firstIndex(where: { $0.id == group.id }) { store.data.groups[i].enabled.toggle() } }
                            Menu("Sposta in") {
                                Button("Livello principale") { setParent(group.id, parent: nil) }
                                ForEach(store.data.groups.filter { $0.id != group.id && !isDescendant($0.id, of: group.id) }) { parent in
                                    Button(parent.name) { setParent(group.id, parent: parent.id) }
                                }
                            }
                            Button("Elimina raccolta, conserva frammenti") { deleteGroup(group.id) }
                        }
                    }
                }
            }.listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading) {
                    Button { renameID = nil; groupName = ""; namingGroup = true } label: { Label("Nuova raccolta", systemImage: "folder.badge.plus") }
                    Button { controller.showingTrash = true } label: { Label("Cestino (\(store.data.trash?.count ?? 0))", systemImage: "trash") }
                }.padding()
            }.navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } content: {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Cerca titolo, abbreviazione o testo", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                }.padding(12)
                Divider()
                List(selection: $selectedID) {
                    ForEach(snippets) { snippet in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(snippet.title.isEmpty ? "Senza titolo" : snippet.title).fontWeight(.medium)
                                Spacer()
                                if !snippet.enabled { Image(systemName: "pause.circle").foregroundStyle(.secondary) }
                            }
                            HStack { Text(snippet.abbreviation).font(.system(.caption, design: .monospaced)).foregroundStyle(Color.accentColor); Spacer(); Text(snippet.kind.label).font(.caption2).foregroundStyle(.secondary) }
                            Text(snippet.kind.isScript || snippet.kind == .image ? snippet.notes : snippet.content.replacingOccurrences(of: "\n", with: " ")).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).tag(snippet.id)
                        .contextMenu {
                            Button("Duplica") { duplicate(snippet) }
                            Button("Copia contenuto") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(snippet.content, forType: .string) }
                            Button("Elimina…", role: .destructive) { selectedID = snippet.id; deletingSnippet = true }
                        }
                    }
                }
                Divider()
                HStack {
                    Button(action: addSnippet) { Label("Nuovo", systemImage: "plus") }
                    Spacer(); Text("\(snippets.count) frammenti").font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            }.navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 430)
        } detail: {
            if let id = selectedID, store.data.snippets.contains(where: { $0.id == id }) {
                SnippetEditor(snippet: snippetBinding(id), groups: store.data.groups, engine: engine) { deletingSnippet = true }.id(id)
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "text.badge.plus").font(.system(size: 52)).foregroundStyle(Color.accentColor)
                    Text("Le parole che scrivi ogni giorno").font(.title2.bold())
                    Text("Crea un frammento, scegli un’abbreviazione e usala nelle tue app.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Crea un frammento", action: addSnippet).buttonStyle(.borderedProminent)
                    Button("Importa raccolta…", action: controller.importLibrary)
                    Button("Leggi la guida") { controller.showingHelp = true }.buttonStyle(.link)
                }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if engine.running { Label(store.data.paused ? "In pausa" : "Attivo", systemImage: store.data.paused ? "pause.circle" : "checkmark.circle.fill").foregroundStyle(store.data.paused ? Color.orange : Color.green) }
                else { Button("Concedi accesso") { engine.start(prompt: true) } }
                Button { store.data.paused.toggle() } label: { Image(systemName: store.data.paused ? "play.fill" : "pause.fill") }.help("Sospendi o riprendi le espansioni")
                Button(action: controller.showQuickSearch) { Image(systemName: "text.magnifyingglass") }.help("Cerca e inserisci")
                Button(action: controller.exportLibrary) { Image(systemName: "square.and.arrow.up") }.help("Esporta backup")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !engine.running { HStack { Image(systemName: "info.circle"); Text(engine.status); Spacer(); Button("Riprova") { engine.start(prompt: true) } }.font(.caption).padding(8).background(Color.orange.opacity(0.12)) }
        }
        .alert(renameID == nil ? "Nuova raccolta" : "Rinomina raccolta", isPresented: $namingGroup) {
            TextField("Nome", text: $groupName)
            Button("Annulla", role: .cancel) {}
            Button("Salva") {
                let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                if let id = renameID, let i = store.data.groups.firstIndex(where: { $0.id == id }) { store.data.groups[i].name = name }
                else { var group = SnippetGroup(); group.name = name; group.parentID = groupID; store.data.groups.append(group); groupID = group.id }
            }
        }
        .alert("Spostare questo frammento nel cestino?", isPresented: $deletingSnippet) {
            Button("Annulla", role: .cancel) {}
            Button("Sposta nel cestino", role: .destructive) { if let id = selectedID { store.moveToTrash([id]) }; selectedID = nil }
        } message: { Text("Potrai recuperarlo dal Cestino della libreria.") }
    }
    private func snippetBinding(_ id: UUID) -> Binding<Snippet> {
        Binding(get: { store.data.snippets.first { $0.id == id } ?? Snippet() }, set: { value in if let i = store.data.snippets.firstIndex(where: { $0.id == id }) { store.data.snippets[i] = value } })
    }
    private func addSnippet() { var snippet = Snippet(); snippet.title = "Nuovo frammento"; snippet.groupID = groupID; store.data.snippets.append(snippet); selectedID = snippet.id }
    private func duplicate(_ value: Snippet) { var copy = value; copy.id = UUID(); copy.title += " — copia"; copy.abbreviation = ""; copy.hotkeyCode = nil; copy.useCount = 0; store.data.snippets.append(copy); selectedID = copy.id }
    private func groupDepth(_ id: UUID) -> Int { var current = id; var seen = Set<UUID>(); var depth = 0; while let p = store.data.groups.first(where: { $0.id == current })?.parentID, seen.insert(p).inserted { depth += 1; current = p }; return min(depth, 8) }
    private func isDescendant(_ id: UUID, of ancestor: UUID) -> Bool { var current: UUID? = id; var seen = Set<UUID>(); while let c = current, seen.insert(c).inserted { if c == ancestor { return true }; current = store.data.groups.first(where: { $0.id == c })?.parentID }; return false }
    private func setParent(_ id: UUID, parent: UUID?) { if let i = store.data.groups.firstIndex(where: { $0.id == id }) { store.data.groups[i].parentID = parent } }
    private func deleteGroup(_ id: UUID) {
        let parent = store.data.groups.first { $0.id == id }?.parentID
        for i in store.data.snippets.indices where store.data.snippets[i].groupID == id { store.data.snippets[i].groupID = parent }
        for i in store.data.groups.indices where store.data.groups[i].parentID == id { store.data.groups[i].parentID = parent }
        store.data.groups.removeAll { $0.id == id }; if groupID == id { groupID = parent }
    }
}

struct SnippetEditor: View {
    @Binding var snippet: Snippet
    let groups: [SnippetGroup]
    @ObservedObject var engine: ExpansionEngine
    let delete: () -> Void
    @State private var tab = 0
    @State private var capturingHotkey = false
    @State private var previewError: String?
    private let macros: [(String, String)] = [("Data", "{{date:dd/MM/yyyy}}"), ("Data tra due giorni", "{{date:+2d|dd/MM/yyyy}}"), ("Ora", "{{time}}"), ("Appunti", "{{clipboard}}"), ("Selezione", "{{selection}}"), ("Cursore", "{{cursor}}"), ("Campo", "{{field:Nome}}"), ("Campo con valore iniziale", "{{field:Nome|Mario}}"), ("Testo su più righe", "{{multiline:Note}}"), ("Scelta", "{{choice:Tipo|Privato|Azienda}}"), ("Casella", "{{check:Conferma|sì|no}}"), ("Data compilabile", "{{datefield:Scadenza|dd/MM/yyyy}}"), ("Condizione", "{{if:Conferma|Confermato|Da confermare}}"), ("Altro frammento", "{{snippet:;firma}}"), ("UUID", "{{uuid}}")]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    TextField("Titolo", text: $snippet.title).font(.title2.bold()).textFieldStyle(.plain)
                    Toggle("Attivo", isOn: $snippet.enabled).toggleStyle(.switch).fixedSize()
                }
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading) { Text("Abbreviazione").font(.caption).foregroundStyle(.secondary); TextField("es. ;firma", text: $snippet.abbreviation).font(.system(.body, design: .monospaced)) }
                    VStack(alignment: .leading) { Text("Raccolta").font(.caption).foregroundStyle(.secondary); Picker("Raccolta", selection: $snippet.groupID) { Text("Nessuna").tag(Optional<UUID>.none); ForEach(groups) { Text($0.name).tag(Optional($0.id)) } }.labelsHidden() }
                }
                DisclosureGroup("Altre abbreviazioni (\((snippet.aliases ?? []).filter { !$0.isEmpty }.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Una per riga. Usano le stesse regole dell’abbreviazione principale.").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: Binding(get: { (snippet.aliases ?? []).joined(separator: "\n") }, set: { snippet.aliases = $0.components(separatedBy: "\n") }))
                            .font(.system(.body, design: .monospaced)).frame(height: 70)
                    }.padding(.top, 6)
                }
                Picker("Formato", selection: Binding(get: { snippet.kind }, set: changeKind)) { ForEach(SnippetKind.allCases, id: \.self) { Text($0.label).tag($0) } }
                if snippet.kind.isScript {
                    Label("Lo script viene eseguito localmente solo se abilitato nelle impostazioni. L’output diventa il testo inserito.", systemImage: "terminal").font(.caption).foregroundStyle(.secondary)
                }
                if snippet.kind == .image {
                    HStack { TextField("Percorso dell’immagine", text: $snippet.content); Button("Scegli…", action: chooseImage) }
                    if let image = NSImage(contentsOfFile: snippet.content) { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 240) }
                } else {
                    HStack {
                        Text("Contenuto").font(.headline)
                        Spacer()
                        if !snippet.kind.isScript {
                            Menu("Inserisci variabile") { ForEach(macros, id: \.0) { item in Button(item.0) { snippet.content += item.1 } } }
                        }
                    }
                    if snippet.kind == .rich {
                        RichEditor(html: $snippet.content).frame(minHeight: 220).overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                        Text("Usa il menu Formato e le scorciatoie native per grassetto, corsivo e caratteri.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        TextEditor(text: $snippet.content).font(.system(.body, design: snippet.kind == .plain ? .default : .monospaced)).frame(minHeight: 220).padding(5).overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                    }
                    if !snippet.kind.isScript {
                        DisclosureGroup("Anteprima delle variabili") {
                            Text(preview).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.quaternary.opacity(0.3))
                            Text("I campi vengono richiesti al momento dell’inserimento. Gli script non vengono eseguiti dall’anteprima.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                DisclosureGroup("Espansione", isExpanded: .constant(true)) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Quando", selection: $snippet.trigger) { ForEach(TriggerMode.allCases, id: \.self) { Text($0.label).tag($0) } }
                        Toggle("Solo all’inizio di una parola", isOn: $snippet.wholeWord)
                        Toggle("Distingui maiuscole e minuscole", isOn: $snippet.caseSensitive)
                        Toggle("Adatta le maiuscole al testo digitato", isOn: $snippet.adaptCase)
                        HStack {
                            Text("Scorciatoia")
                            Button(hotkeyLabel) { capturingHotkey = true }
                            if snippet.hotkeyCode != nil { Button("Rimuovi") { snippet.hotkeyCode = nil; snippet.hotkeyModifiers = 0 } }
                        }
                    }.padding(.top, 8)
                }
                DisclosureGroup("Applicazioni e note") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Disponibilità", selection: $snippet.appScope) { ForEach(AppScope.allCases, id: \.self) { Text($0.label).tag($0) } }
                        if snippet.appScope != .all {
                            TextField("Bundle ID separati da virgole", text: Binding(get: { snippet.apps.joined(separator: ",") }, set: { snippet.apps = $0.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }))
                            Text("Per esempio com.apple.TextEdit. Usa il pulsante per aggiungere un’app.").font(.caption).foregroundStyle(.secondary)
                            Button("Aggiungi applicazione…", action: chooseApp)
                        }
                        TextField("Note", text: $snippet.notes, axis: .vertical).lineLimit(2...5)
                        if let source = snippet.atextSourceJSON {
                            HStack {
                                Text("Importato da aText. Controlla gli avvisi nelle note prima di attivarlo.").font(.caption).foregroundStyle(.secondary)
                                Button("Copia dati originali") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source, forType: .string) }
                            }
                        }
                        Text("Inserimenti: \(snippet.useCount)").font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
                Divider()
                HStack {
                    Button("Inserisci nell’ultima app") { engine.expand(snippet) }.buttonStyle(.borderedProminent)
                    if [.plain, .rich, .html].contains(snippet.kind) { Button("Anteprima con campi…") { engine.preview(snippet) } }
                    Button("Copia testo") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(snippet.content, forType: .string) }
                    Spacer()
                    Button(role: .destructive, action: delete) { Image(systemName: "trash") }.help("Elimina frammento")
                }
            }.padding(24)
        }.sheet(isPresented: $capturingHotkey) {
            VStack(spacing: 18) {
                Text("Premi la combinazione di tasti").font(.headline)
                Text("Usa almeno ⌘, ⌥ o ⌃. Esc annulla. ⌃⌥Spazio è riservata alla ricerca.").font(.caption).foregroundStyle(.secondary)
                HotkeyRecorder { code, modifiers in snippet.hotkeyCode = code; snippet.hotkeyModifiers = modifiers; capturingHotkey = false }.frame(width: 400, height: 60)
                Button("Annulla") { capturingHotkey = false }.keyboardShortcut(.cancelAction)
            }.padding(28)
        }
    }
    private var preview: String { (try? TemplateRenderer().render(snippet.content, context: RenderContext(clipboard: "[appunti al momento dell’inserimento]", selection: "[selezione nell’app di destinazione]")))?.text ?? "Contenuto non valido: controlla le variabili." }
    private var hotkeyLabel: String {
        guard let code = snippet.hotkeyCode else { return "Registra…" }
        let m = snippet.hotkeyModifiers
        return ((m & UInt32(controlKey)) != 0 ? "⌃" : "") + ((m & UInt32(optionKey)) != 0 ? "⌥" : "") + ((m & UInt32(shiftKey)) != 0 ? "⇧" : "") + ((m & UInt32(cmdKey)) != 0 ? "⌘" : "") + " tasto \(code)"
    }
    private func changeKind(_ kind: SnippetKind) {
        let oldRich = snippet.kind == .rich || snippet.kind == .html
        let newRich = kind == .rich || kind == .html
        if newRich && !oldRich {
            let escaped = snippet.content.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
            snippet.content = "<html><meta charset=\"utf-8\"><body>" + escaped + "</body></html>"
        } else if oldRich && !newRich, let text = try? NSAttributedString(data: Data(snippet.content.utf8), options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil) {
            snippet.content = text.string
        }
        snippet.kind = kind
    }
    private func chooseImage() { let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; if panel.runModal() == .OK, let url = panel.url { snippet.content = url.path } }
    private func chooseApp() { let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.directoryURL = URL(fileURLWithPath: "/Applications"); if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier, !snippet.apps.contains(id) { snippet.apps.append(id) } }
}

struct RichEditor: NSViewRepresentable {
    @Binding var html: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        let text = NSTextView(); text.isRichText = true; text.allowsUndo = true; text.isEditable = true; text.isSelectable = true; text.usesFontPanel = true; text.usesRuler = true
        text.minSize = NSSize(width: 0, height: 220); text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 10, height: 10); text.delegate = context.coordinator
        scroll.documentView = text; setText(text); return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let text = scroll.documentView as? NSTextView, context.coordinator.lastHTML != html else { return }
        let selection = text.selectedRange()
        setText(text); context.coordinator.lastHTML = html
        let length = text.attributedString().length
        text.setSelectedRange(NSRange(location: min(selection.location, length), length: min(selection.length, max(0, length - selection.location))))
    }
    private func setText(_ view: NSTextView) {
        if let data = html.data(using: .utf8), let attr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil) { view.textStorage?.setAttributedString(attr) }
        else { view.string = html }
    }
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichEditor; var lastHTML = ""
        init(_ parent: RichEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView, let data = try? text.attributedString().data(from: NSRange(location: 0, length: text.attributedString().length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html]), let html = String(data: data, encoding: .utf8) else { return }
            lastHTML = html; parent.html = html
        }
    }
}

struct HotkeyRecorder: NSViewRepresentable {
    let onRecord: (Int, UInt32) -> Void
    func makeNSView(context: Context) -> RecorderView { let view = RecorderView(); view.onRecord = onRecord; DispatchQueue.main.async { view.window?.makeFirstResponder(view) }; return view }
    func updateNSView(_ nsView: RecorderView, context: Context) {}
    class RecorderView: NSView {
        var onRecord: ((Int, UInt32) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.intersection([.command, .option, .control]).isEmpty else { NSSound.beep(); return }
            var modifiers: UInt32 = 0
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }; if flags.contains(.option) { modifiers |= UInt32(optionKey) }; if flags.contains(.control) { modifiers |= UInt32(controlKey) }; if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            guard !(event.keyCode == 49 && modifiers == UInt32(controlKey | optionKey)) else { NSSound.beep(); return }
            onRecord?(Int(event.keyCode), modifiers)
        }
        override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect); let str = "La prossima combinazione verrà assegnata al frammento"; (str as NSString).draw(at: NSPoint(x: 10, y: 22), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]) }
    }
}

struct QuickSearchView: View {
    @ObservedObject var store: LibraryStore
    let insert: (Snippet) -> Void
    @State private var query = ""
    @State private var selected: UUID?
    @FocusState private var focused: Bool
    private var matches: [Snippet] { store.data.snippets.filter { $0.enabled && (query.isEmpty || ($0.title + " " + $0.allAbbreviations.joined(separator: " ") + " " + $0.content).localizedCaseInsensitiveContains(query)) }.sorted { $0.useCount > $1.useCount } }
    var body: some View {
        VStack {
            TextField("Cerca un frammento…", text: $query).textFieldStyle(.roundedBorder).focused($focused).onSubmit { choose() }
            List(selection: $selected) { ForEach(matches) { snippet in HStack { VStack(alignment: .leading) { Text(snippet.title); Text(snippet.abbreviation).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Inserisci") { insert(snippet) } }.tag(snippet.id) } }
            HStack { Text("⌃⌥Spazio · Invio inserisce la selezione").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Inserisci", action: choose).disabled(matches.isEmpty) }
        }.padding(15).onAppear { DispatchQueue.main.async { focused = true }; selected = matches.first?.id }.onChange(of: query) { _ in selected = matches.first?.id }
    }
    private func choose() { if let snippet = matches.first(where: { $0.id == selected }) ?? matches.first { insert(snippet) } }
}

struct PreferencesView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: ExpansionEngine
    @ObservedObject var controller: DesktopController
    @ObservedObject var sync: LibraryFolderSync
    @State private var loginError: String?
    var body: some View {
        Form {
            Section("Espansione") {
                Toggle("Sospendi tutte le espansioni", isOn: $store.data.paused)
                TextField("Separatori", text: Binding(get: { store.data.delimiters.replacingOccurrences(of: "\t", with: "\\t").replacingOccurrences(of: "\n", with: "\\n") }, set: { store.data.delimiters = $0.replacingOccurrences(of: "\\t", with: "\t").replacingOccurrences(of: "\\n", with: "\n") }))
                Text("Uno spazio è un separatore. Usa \\t per Tab e \\n per Invio.").font(.caption).foregroundStyle(.secondary)
                TextField("App escluse (bundle ID, separati da virgole)", text: Binding(get: { store.data.excludedApps.joined(separator: ",") }, set: { store.data.excludedApps = $0.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }))
            }
            Section("Sistema") {
                HStack { Text(engine.status); Spacer(); Button("Abilita accesso") { engine.start(prompt: true) } }
                Button("Apri impostazioni Accessibilità") { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) } }
                Button("Apri Monitoraggio input") { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(url) } }
                Toggle("Avvia all’accesso", isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { enable in
                    do { if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; store.data.launchAtLogin = enable }
                    catch { controller.error = error.localizedDescription }
                }))
                Toggle("Consenti l’esecuzione dei miei script", isOn: $store.data.allowScripts)
                Text("Shell, AppleScript e JXA operano con i tuoi permessi; durata massima 5 secondi. Abilita solo script che hai scritto o controllato.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Libreria") {
                Text(store.fileURL.path).font(.caption).textSelection(.enabled)
                HStack { Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL]) }; Button("Importa…", action: controller.importLibrary); Button("Esporta backup…", action: controller.exportLibrary) }
                HStack { Button("Cestino…") { controller.showingTrash = true }; Button("Backup e ripristino…") { controller.showingBackups = true } }
            }
            Section("Backup automatici") {
                TextField("Intervallo in minuti", value: Binding(get: { store.effectiveBackupIntervalMinutes }, set: { store.data.backupIntervalMinutes = max(1, min(525_600, $0)) }), format: .number)
                TextField("Copie da conservare", value: Binding(get: { store.effectiveBackupRetention }, set: { store.data.backupRetention = max(1, min(10_000, $0)) }), format: .number)
                Text(store.backupsDirectory.path).font(.caption).textSelection(.enabled)
                HStack { Button("Scegli cartella…", action: controller.chooseBackupFolder); Button("Cartella predefinita") { store.data.backupFolder = nil }; Button("Crea copia ora") { do { _ = try store.createBackup() } catch { controller.error = error.localizedDescription } } }
                Text("Una copia dello stato precedente viene creata al salvataggio, quando è trascorso l’intervallo scelto. Il ripristino conserva prima lo stato corrente.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Sincronizzazione tramite cartella") {
                Text(sync.status)
                if let message = sync.lastError { Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if let path = store.data.syncFolder { Text(path).font(.caption).textSelection(.enabled) }
                HStack {
                    Button("Scegli cartella…", action: controller.chooseSyncFolder)
                    Button("Sincronizza ora") { do { try sync.syncNow() } catch { controller.error = error.localizedDescription } }.disabled(sync.folderURL == nil)
                    Button("Disattiva") { do { try sync.configure(folder: nil) } catch { controller.error = error.localizedDescription } }.disabled(sync.folderURL == nil)
                }
                Text("Scegli una cartella replicata dal tuo provider sugli altri Mac. I conflitti conservano entrambe le versioni. Sono condivisi raccolte, frammenti e cestino; le impostazioni e i permessi degli script rimangono locali. Il formato è di SuperSnippetto.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding()
    }
}

struct BackupBrowser: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var controller: DesktopController
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [URL] = []
    @State private var selected: URL?
    @State private var confirmRestore = false
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Backup e ripristino").font(.title2.bold()); Spacer(); Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text(store.backupsDirectory.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            List(selection: $selected) {
                ForEach(entries, id: \.self) { url in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(date(for: url).formatted(date: .abbreviated, time: .standard))
                        Text(url.lastPathComponent).font(.caption2).foregroundStyle(.secondary)
                    }.tag(url)
                }
            }.overlay { if entries.isEmpty { Text("Le copie automatiche e manuali compariranno qui.").foregroundStyle(.secondary) } }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Button("Crea copia ora") { do { let url = try store.createBackup(); reload(); selected = url; message = "Copia creata." } catch { message = error.localizedDescription } }
                Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting(selected.map { [$0] } ?? [store.backupsDirectory]) }
                Spacer()
                Button("Ripristina…") { confirmRestore = true }.disabled(selected == nil)
            }
            Text("Il ripristino sostituisce la libreria e le sue impostazioni. Prima viene creata una copia dello stato corrente, comprese le modifiche non ancora salvate.").font(.caption).foregroundStyle(.secondary)
        }.padding(22).onAppear(perform: reload)
            .alert("Ripristinare questa copia?", isPresented: $confirmRestore) {
                Button("Annulla", role: .cancel) {}
                Button("Ripristina") {
                    guard let selected else { return }
                    controller.folderSync.stop()
                    do {
                        try store.restoreBackup(selected); controller.engine.refreshHotkeys(); reload(); message = "Libreria ripristinata."
                        do { try controller.folderSync.configure(folder: store.data.syncFolder.map { URL(fileURLWithPath: $0) }) }
                        catch {
                            controller.folderSync.stop(); controller.folderSync.lastError = error.localizedDescription
                            controller.folderSync.status = "Sincronizzazione sospesa dopo il ripristino"
                            message = "Libreria ripristinata. Scegli di nuovo la cartella di sincronizzazione: \(error.localizedDescription)"
                        }
                    } catch { controller.folderSync.start(); message = error.localizedDescription }
                }
            } message: { Text("\(selected?.lastPathComponent ?? "")\nLa libreria corrente rimarrà recuperabile dai backup.") }
    }
    private func reload() { do { entries = try store.backups(); if let selected, !entries.contains(selected) { self.selected = nil } } catch { message = error.localizedDescription } }
    private func date(for url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
}

struct TrashBrowser: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var controller: DesktopController
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<UUID>()
    @State private var confirmEmpty = false
    @State private var message: String?
    private var items: [TrashedSnippet] { (store.data.trash ?? []).sorted { $0.deletedAt > $1.deletedAt } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Cestino").font(.title2.bold()); Spacer(); Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("I frammenti nel cestino sono disattivati e possono essere recuperati.").foregroundStyle(.secondary)
            List(selection: $selected) {
                ForEach(items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) { Text(item.snippet.title); Text(item.snippet.abbreviation).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                        Spacer(); Text(item.deletedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }.tag(item.id)
                }
            }.overlay { if items.isEmpty { Text("Il cestino è vuoto.").foregroundStyle(.secondary) } }
            if let message { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Seleziona tutto") { selected = Set(items.map(\.id)) }.disabled(items.isEmpty)
                Button("Ripristina selezionati") {
                    let before = store.data
                    do { store.restoreFromTrash(selected); try store.save(); selected.removeAll(); message = nil }
                    catch { store.data = before; message = error.localizedDescription }
                }.disabled(selected.isEmpty)
                Spacer()
                Button("Svuota cestino…", role: .destructive) { confirmEmpty = true }.disabled(items.isEmpty)
            }
        }.padding(22).alert("Svuotare il cestino?", isPresented: $confirmEmpty) {
            Button("Annulla", role: .cancel) {}
            Button("Svuota", role: .destructive) {
                let before = store.data
                do { _ = try store.createBackup(); store.emptyTrash(); try store.save(); selected.removeAll(); message = nil }
                catch { store.data = before; message = error.localizedDescription }
            }
        } message: { Text("Verranno rimossi \(items.count) frammenti dal cestino. Prima verrà creata una copia di backup recuperabile.") }
    }
}

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text("SuperSnippetto").font(.largeTitle.bold()); Spacer(); Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction) }.padding()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Crea un frammento e assegnagli un’abbreviazione come ;firma. Concedi Accessibilità e Monitoraggio input nelle impostazioni di macOS, poi riavvia l’app se richiesto. Digita l’abbreviazione in TextEdit per provarla.")
                    Text("La ricerca rapida si apre con Ctrl–Option–Spazio o dal menu nella barra di macOS. Seleziona un frammento per inserirlo nell’ultima app usata. Le app escluse e le raccolte disattivate vengono rispettate anche nell’inserimento manuale.")
                    Text("Variabili").font(.title2.bold())
                    Text("{{date:dd/MM/yyyy}} · data con formato Unicode\n{{time}} · ora locale\n{{clipboard}} · testo negli appunti\n{{selection}} · testo selezionato accessibile\n{{cursor}} · posizione finale del cursore\n{{field:Nome}} · valore da chiedere prima dell’inserimento\n{{snippet:;firma}} · contenuto di un altro frammento\n{{uuid}} · identificatore nuovo\n{{upper:testo}} · maiuscolo\n{{lower:testo}} · minuscolo\n{{title:testo}} · iniziali maiuscole").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Text("Moduli e trasformazioni").font(.title2.bold())
                    Text("{{field:Nome|Mario}} · valore iniziale\n{{multiline:Note}} · testo su più righe\n{{choice:Tipo|Privato|Azienda}} · menu di scelta\n{{check:Conferma|sì|no}} · casella\n{{datefield:Scadenza|dd/MM/yyyy}} · data compilabile\n{{if:Conferma|Confermato|Da confermare}} · condizione\n{{var:Nome}} · riuso di un valore\n{{date:+2d|dd/MM/yyyy}} · data relativa\n{{date:HH:mm|it_IT|Europe/Rome}} · lingua e fuso\n{{replace:cerca|sostituisci|testo}} · sostituzione\n{{regex:(\\d+)|[$1]|a12}} · espressione regolare\n{{trim: testo }} · elimina spazi esterni\n{{length:testo}} · numero di caratteri\n{{urlencode:testo}} · codifica URL\n{{base64:testo}} · codifica Base64").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Text("Puoi annidare le variabili. Per usare | dentro un argomento scrivi \\|; per un backslash scrivi \\\\. Le trasformazioni inverse sono urldecode e unbase64. L’anteprima con campi consente di provare un modulo nella sola finestra dell’app, senza inserirlo altrove.")
                    Text("Formati").font(.title2.bold())
                    Text("Testo semplice, testo formattato, HTML e immagini locali vengono incollati tramite gli appunti. La formattazione dipende dall’app di destinazione. Shell, AppleScript e JavaScript for Automation producono testo e richiedono l’opzione Consenti script. Il motore non tiene uno storico dei tasti; conserva solo un breve buffer in memoria per riconoscere le abbreviazioni e si sospende nei campi protetti riconosciuti da macOS.")
                    Text("Dati e backup").font(.title2.bold())
                    Text("Esporta JSON per una copia completa, oppure CSV per i frammenti attivi. L’importazione unisce i dati. Sono supportati plist TextExpander testuali compatibili e file aText .atext non protetti. Gli elementi aText partono con attivazione manuale: script, macro e regole non convertibili sono disattivati con avvisi nelle note. I dati originali sono conservati nel JSON esportato. I frammenti rimossi vanno nel cestino recuperabile. I backup automatici hanno frequenza, conservazione e cartella configurabili; prima di un ripristino viene conservata la libreria corrente.")
                    Text("La sincronizzazione usa una cartella scelta da te e trasferita dal tuo provider fra i Mac. Frammenti, raccolte e cestino condividono un formato di SuperSnippetto; le copie in conflitto vengono mantenute. Impostazioni, autorizzazione script e conteggi d’uso restano locali.")
                    Text("Automazione AppleScript").font(.title2.bold())
                    Text("tell application \"SuperSnippetto\"\n    status\n    -- enable / disable\n    -- expand \";firma\"\n    -- import \"/percorso/raccolta.json\"\n    -- delete \"UUID-DEL-FRAMMENTO\"\nend tell").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Text("I comandi usano gli stessi permessi e le stesse regole dell’interfaccia. delete sposta nel cestino. expand conferma la richiesta asincrona; l’esito dell’inserimento dipende dall’app di destinazione.")
                    Text("Implementazione indipendente, versione 0.2. La ricostruzione integrale resta incompleta: .atext, parametri digitati, autocorrezione completa, sequenze mouse/tastiera, allegati e altre funzioni sono ancora da realizzare o verificare. Consulta Verifica.txt.").font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }
        }
    }
}
