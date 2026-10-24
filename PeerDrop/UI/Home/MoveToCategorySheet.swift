import SwiftUI
import PeerDropCore

/// The friend whose "Move to category…" sheet is open. `person` holds every id the friend may be stored
/// under (all their records), so moving one record moves the whole person.
struct CategoryMoveTarget: Identifiable, Equatable {
    let recordID: String
    let name: String
    let person: [String]
    var id: String { recordID }
}

/// Lists every category plus "No category", with a checkmark on the friend's current one. Picking a row
/// moves the friend there and closes the sheet; a new category can be made (and picked) from here too.
struct MoveToCategorySheet: View, PaperThemed {
    var paperMode: PaperMode { .live }
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: FriendCategoryStore
    let target: CategoryMoveTarget
    @State private var creating = false

    private var currentID: String? { store.category(containingAnyOf: target.person)?.id }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    choice(title: Text("No category"), selected: currentID == nil) { move(to: nil) }
                        .accessibilityIdentifier("category-choice-none")
                    ForEach(store.categories) { category in
                        choice(title: Text(verbatim: category.name), selected: currentID == category.id) { move(to: category.id) }
                            .accessibilityIdentifier("category-choice")
                    }
                } header: {
                    Text(verbatim: target.name)
                }
                if store.categories.count < FriendCategoryStore.maxCategories {
                    Section {
                        if creating {
                            InlineCategoryNameField(onCommit: { name in
                                creating = false
                                if let category = store.create(name: name) { move(to: category.id) }
                            }, onCancel: { creating = false })
                        } else {
                            Button { creating = true } label: {
                                Label("New category", systemImage: "folder.badge.plus")
                                    .foregroundStyle(paper(.brand))
                            }
                            .accessibilityIdentifier("category-add")
                        }
                    }
                }
            }
            .navigationTitle("Move to category…")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .paperMode(.live)
        #if os(macOS)
        .frame(minWidth: 320, minHeight: 360)
        #endif
    }

    private func choice(title: Text, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                title
                    .foregroundStyle(paper(.incomingText))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(paper(.brand))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func move(to categoryID: String?) {
        store.move(person: target.person, record: target.recordID, to: categoryID)
        dismiss()
    }
}

/// An inline list-row text field for a category name (create on Home / in the move sheet, rename on the
/// category page): it takes focus when it appears; Return commits when the trimmed name is 1–20 characters
/// (the store's rule). Return on an invalid name keeps the field, the text and focus, and turns the hint
/// into a warning; Return on an empty field, Escape, or losing focus cancels and restores the row.
struct InlineCategoryNameField: View, PaperThemed {
    @Environment(\.paperMode) var paperMode
    var initial: String = ""
    /// Called only with a valid name.
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @State private var finished = false
    @State private var showInvalid = false
    /// Set when Return hit an invalid name, so the focus loss iOS reports for that Return does not cancel.
    @State private var keepAfterSubmit = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(text: $text) { Text("Category name") }
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { submit() }
                .onChange(of: text) { _ in showInvalid = false }
                #if os(macOS)
                .onExitCommand { cancel() }
                #endif
                .accessibilityIdentifier("category-name-field")
                .accessibilityHint(Text("1–20 characters."))
            Text("1–20 characters.")
                .font(.caption2)
                .foregroundStyle(showInvalid ? paper(.warning) : paper(.datePillText))
                .accessibilityHidden(true)
        }
        .onAppear {
            text = initial
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: focused) { isFocused in
            if isFocused { keepAfterSubmit = false; return }
            // Checked a turn later: the blur caused by Return may arrive before or after onSubmit.
            DispatchQueue.main.async { if !focused && !keepAfterSubmit { cancel() } }
        }
    }

    private func submit() {
        guard !finished else { return }
        switch InlineNameSubmit.decide(text: text) {
        case .create(let name):
            finished = true
            onCommit(name)
        case .cancel:
            finished = true
            onCancel()
        case .keepEditing:
            // Keep the typed text; Return may have resigned focus, so take it back.
            showInvalid = true
            keepAfterSubmit = true
            #if os(iOS)
            UIAccessibility.post(notification: .announcement, argument: String(localized: "1–20 characters."))
            #endif
            DispatchQueue.main.async { focused = true }
        }
    }

    private func cancel() {
        guard !finished else { return }
        finished = true
        onCancel()
    }
}
