import SwiftUI
import BrowseCore

private typealias CustomizationState<Value> = SwiftUI.State<Value>

struct FavoriteCustomizationRequest: Identifiable {
    let id = UUID()
    let service: GoogleFavoriteService
    let originalAddress: String
    let tabID: UUID?
    let pageID: UUID?
    let favoriteID: UUID?
    let email: String
}

// @lat: [[architecture#Google account favorites]]
extension BrowserStore {
    func requestFavorite(_ tabID: UUID) {
        guard let tab = session.workspaces.flatMap(\.tabs).first(where: { $0.id == tabID }),
              canFavorite(tab), let page = favoritePage(in: tab) else { return }
        guard let service = GoogleFavoriteService(address: page.address) else { addFavorite(tabID); return }
        favoriteCustomization = FavoriteCustomizationRequest(service: service, originalAddress: page.address,
            tabID: tabID, pageID: page.id, favoriteID: nil,
            email: GoogleFavoriteService.suggestedEmail(address: page.address) ?? "")
    }

    func customizeFavorite(_ id: UUID) {
        guard let favorite = favorites.first(where: { $0.id == id }),
              let service = GoogleFavoriteService(address: favorite.address) else { return }
        favoriteCustomization = FavoriteCustomizationRequest(service: service, originalAddress: favorite.address,
            tabID: nil, pageID: nil, favoriteID: id,
            email: favorite.googleAccountEmail ?? GoogleFavoriteService.suggestedEmail(address: favorite.address) ?? "")
    }

    func saveFavoriteCustomization(_ request: FavoriteCustomizationRequest, email input: String) -> String? {
        guard favoriteCustomization?.id == request.id else { return "This popup is no longer active." }
        let blank = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let email = GoogleFavoriteService.normalizedEmail(input)
        guard blank || email != nil else { return "Enter a valid Google account email address." }
        let address = email.map { request.service.accountAddress(email: $0) }
            ?? (request.favoriteID == nil ? request.originalAddress : request.service.home)
        let id: UUID
        if let favoriteID = request.favoriteID {
            guard let index = favorites.firstIndex(where: { $0.id == favoriteID }),
                  favorites[index].address == request.originalAddress else { return "This favorite changed. Open its settings again." }
            if favorites[index].address == address && favorites[index].googleAccountEmail == email {
                favoriteCustomization = nil
                return nil
            }
            guard !favorites.contains(where: { $0.id != favoriteID && $0.address == address }) else {
                return "A favorite already uses this Google account."
            }
            preferencesStore.session.favorites?[index].address = address
            preferencesStore.session.favorites?[index].googleAccountEmail = email
            preferencesStore.saveSoon()
            id = favoriteID
        } else {
            guard let tabID = request.tabID, let pageID = request.pageID,
                  let tab = session.workspaces.flatMap(\.tabs).first(where: { $0.id == tabID }),
                  tab.focusedPane == pageID, tab.pages.contains(where: { $0.id == pageID && $0.address == request.originalAddress }),
                  let added = addFavorite(tabID, address: address, googleAccountEmail: email) else {
                return "This tab changed or all nine favorites are in use. Try adding it again."
            }
            id = added
        }
        // Apply the chosen account to an already-open target as well as future launches.
        if let favorite = favorites.first(where: { $0.id == id }),
           let target = favoriteTarget(id), email != nil || request.favoriteID != nil {
            editTab(target.tab.id) { tab in
                if let index = tab.pages.firstIndex(where: { $0.id == target.page.id }) {
                    tab.pages[index].address = favorite.launchAddress
                }
            }
            existingController(for: target.page.id)?.navigate(favorite.launchAddress)
        }
        favoriteCustomization = nil
        return nil
    }
}

struct FavoriteCustomizationView: View {
    @ObservedObject var store: BrowserStore
    let request: FavoriteCustomizationRequest
    @CustomizationState<String> private var email: String
    @CustomizationState<String?> private var error: String?
    @FocusState private var inputFocused: Bool

    init(store: BrowserStore, request: FavoriteCustomizationRequest) {
        self.store = store
        self.request = request
        _email = CustomizationState(initialValue: request.email)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.favoriteID == nil ? "Favorite \(request.service.name)" : "\(request.service.name) account")
                .font(.title2.weight(.semibold))
            Text("Open this favorite with a specific Google account.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Email address (optional)").font(.callout)
                TextField("you@example.com", text: $email).textFieldStyle(.roundedBorder)
                    .focused($inputFocused).onSubmit(save)
                    .accessibilityLabel("Google account email")
                    .onChange(of: email) { _, _ in error = nil }
                Text(request.favoriteID == nil ? "Leave blank to keep the current link." : "Leave blank to use your default account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { store.favoriteCustomization = nil }.keyboardShortcut(.cancelAction)
                Button(request.favoriteID == nil ? "Add Favorite" : "Save", action: save).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 380)
            .onAppear { inputFocused = true }
    }

    private func save() { error = store.saveFavoriteCustomization(request, email: email) }
}
