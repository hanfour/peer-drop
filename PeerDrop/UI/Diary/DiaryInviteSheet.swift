import SwiftUI
import PeerDropDiary
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Copy/share the invite link, short code, and (owner-only) reset-code /
/// close-diary actions (spec §5.2/§6). Only the owner ever has a usable
/// `inviteCode` locally (spec §2.3 — the worker only returns it to the
/// owner), so everything beyond the "waiting" message is owner-gated.
struct DiaryInviteSheet: View {
    let diaryId: String
    @ObservedObject var store: DiaryStore
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var showShare = false
    @State private var isResetting = false
    @State private var showCloseConfirm = false
    @State private var errorMessage: String?

    private var state: DiaryState? { store.states[diaryId] }
    private var isOwner: Bool { state?.isOwner ?? false }
    private var inviteCode: String? { state?.meta.inviteCode }
    private var link: URL? { store.inviteLink(for: diaryId) }

    var body: some View {
        Form {
            if isOwner, let inviteCode {
                Section {
                    Text("Short Code: \(inviteCode)").font(.body.monospaced()).textSelection(.enabled)
                    HStack(spacing: 12) {
                        Button(copied ? "Copied" : "Copy Link") { copyLink() }
                            .disabled(link == nil)
                        Button("Share Link") { showShare = true }
                            .disabled(link == nil)
                    }
                } footer: {
                    Text("This link contains the diary's key. Only share it with the person you're inviting.")
                }
                Section {
                    Button("Reset Code") { Task { await resetInvite() } }
                        .disabled(isResetting)
                    Button("Close Diary", role: .destructive) { showCloseConfirm = true }
                }
            } else {
                Section {
                    Text("Only the diary's owner can share an invite.").foregroundStyle(.secondary)
                }
            }
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
        }
        .navigationTitle("Invite")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
        .confirmationDialog("Close this diary?", isPresented: $showCloseConfirm, titleVisibility: .visible) {
            Button("Close Diary", role: .destructive) { Task { await close() } }
        } message: { Text("Members can still read and leave, but no one can write or join.") }
        #if os(iOS)
        .sheet(isPresented: $showShare) {
            if let link { ShareSheet(items: [link]) }
        }
        #elseif os(macOS)
        .background(SharingServicePickerHost(isPresented: $showShare, items: link.map { [$0] } ?? []))
        #endif
    }

    private func copyLink() {
        guard let link else { return }
        #if os(iOS)
        UIPasteboard.general.string = link.absoluteString
        #elseif os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link.absoluteString, forType: .string)
        #endif
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
    }

    private func resetInvite() async {
        isResetting = true; errorMessage = nil
        defer { isResetting = false }
        do { _ = try await store.resetInvite(diaryId) }
        catch let e as DiaryError { errorMessage = e.userMessage() }
        catch { errorMessage = String(localized: "Something went wrong. Please try again.") }
    }

    private func close() async {
        do { try await store.close(diaryId); dismiss() }
        catch let e as DiaryError { errorMessage = e.userMessage() }
        catch { errorMessage = String(localized: "Something went wrong. Please try again.") }
    }
}

#if os(macOS)
/// `NSSharingServicePicker` shim — macOS has no `UIActivityViewController`
/// equivalent as a SwiftUI-native sheet; present it imperatively against
/// the hosting `NSView` the same way `ConnectionQRView`'s share affordance
/// does elsewhere in the Mac app.
private struct SharingServicePickerHost: NSViewRepresentable {
    @Binding var isPresented: Bool
    let items: [Any]

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard isPresented, !items.isEmpty else { return }
        DispatchQueue.main.async {
            let picker = NSSharingServicePicker(items: items)
            picker.show(relativeTo: .zero, of: nsView, preferredEdge: .minY)
            isPresented = false
        }
    }
}
#endif
