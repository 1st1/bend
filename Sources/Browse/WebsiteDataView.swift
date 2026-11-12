import SwiftUI
import WebKit

private typealias ViewState<Value> = SwiftUI.State<Value>

// @lat: [[lat.md/architecture/settings#Website data management]]
struct WebsiteDataView: View {
    let dataStore: WKWebsiteDataStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var records: [WKWebsiteDataRecord] = []
    @ViewState private var query = ""
    @ViewState private var busy = true
    @ViewState private var pendingRemoval: [WKWebsiteDataRecord] = []
    @ViewState private var confirmsRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Website Data").font(.title2.bold())
            Text("Removing cookies, caches, and website storage may sign you out. Browsing history and downloaded files are kept.")
                .foregroundStyle(.secondary)
            TextField("Filter websites", text: $query).textFieldStyle(.roundedBorder)
            List {
                ForEach(records.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) }, id: \.self) { record in
                    HStack {
                        Text(record.displayName)
                        Spacer()
                        Button("Remove…") { pendingRemoval = [record]; confirmsRemoval = true }
                    }
                }
            }
            .overlay { if busy { ProgressView() } else if records.isEmpty { Text("No website data").foregroundStyle(.secondary) } }
            .disabled(busy)
            HStack {
                Button("Remove All…") { pendingRemoval = records; confirmsRemoval = true }
                    .disabled(busy || records.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 540, height: 420)
        .task { await reload() }
        .confirmationDialog("Remove website data?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                let selected = pendingRemoval
                busy = true
                Task {
                    await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: selected)
                    await reload()
                }
            }
        } message: { Text("This may sign you out of the selected websites.") }
    }

    private func reload() async {
        busy = true
        records = await dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        busy = false
    }
}
