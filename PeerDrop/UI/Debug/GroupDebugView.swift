#if DEBUG
import SwiftUI
import PeerDropCore
import PeerDropGroups

/// Throwaway DEBUG-only harness so G1b can be exercised on a real device before the G2 UI exists.
/// Everything here calls the public `GroupStore` API; nothing is persisted outside it.
struct GroupDebugView: View {
    @EnvironmentObject private var connectionManager: ConnectionManager

    var body: some View {
        GroupDebugRoot(store: connectionManager.groupStore)
    }
}

private struct GroupDebugRoot: View {
    @ObservedObject var store: GroupStore
    @State private var newName = ""
    @State private var allowAnonymous = true
    @State private var joinInput = ""
    @State private var nickname = ""
    @State private var busy = false
    @State private var status: String?

    var body: some View {
        List {
            Section("Create") {
                TextField("Group name", text: $newName)
                Toggle("Allow anonymous members", isOn: $allowAnonymous)
                Button("Create group") { run("create") {
                    let id = try await store.create(name: newName, description: nil, category: nil, joinPolicy: (allowAnonymous ? JoinPolicy.anonymousAllowed : .accountOnly).rawValue)
                    newName = ""
                    return "created \(id.prefix(8))"
                } }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }

            Section {
                TextField("Invite link or code", text: $joinInput, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Nickname (anonymous)", text: $nickname)
                if let pending = store.pendingInvite {
                    Button("Use pending invite (\(pending.groupId.prefix(8)))") {
                        run("join pending") {
                            let id = try await store.join(code: pending.code, as: .anon, nickname: nickname.nilIfEmpty)
                            return "joined \(id.prefix(8))"
                        }
                    }
                }
                Button("Join anonymously") { run("join") {
                    let input = joinInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    let id: String
                    if let url = URL(string: input), GroupInviteLink.parse(url) != nil {
                        id = try await store.join(link: url, as: .anon, nickname: nickname.nilIfEmpty)
                    } else {
                        id = try await store.join(code: input, as: .anon, nickname: nickname.nilIfEmpty)
                    }
                    joinInput = ""
                    return "joined \(id.prefix(8))"
                } }
                .disabled(joinInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            } header: { Text("Join") } footer: { Text("Account-identity join needs a signed-in account; this harness joins anonymously.") }

            Section("Groups") {
                if store.groups.isEmpty { Text("No groups yet").foregroundStyle(.secondary) }
                ForEach(store.groups) { group in
                    NavigationLink {
                        GroupDebugRoom(store: store, groupId: group.groupId)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(group.name ?? "(awaiting key)")
                            Text("\(group.groupId.prefix(8)) · \(group.memberCount) members · \(group.state.rawValue)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Refresh server list") { run("syncList") { await store.syncList(); return "unknown on server: \(store.unknownGroupIds.count)" } }
            }

            if status != nil || store.lastError != nil {
                Section("Status") {
                    if let status { Text(status).font(.caption) }
                    if let error = store.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle("Group debug")
        .disabled(busy)
    }

    private func run(_ label: String, _ work: @escaping () async throws -> String) {
        busy = true
        Task {
            do { status = "\(label): \(try await work())" }
            catch { status = "\(label) failed: \(error)" }
            busy = false
        }
    }
}

private struct GroupDebugRoom: View {
    @ObservedObject var store: GroupStore
    let groupId: String
    @State private var draft = ""
    @State private var status: String?

    private var state: GroupState? { store.states[groupId] }

    var body: some View {
        List {
            Section("Invite") {
                if let link = store.inviteLink(for: groupId) {
                    Text(link.absoluteString).font(.caption2).textSelection(.enabled)
                    ShareLink(item: link) { Label("Share invite link", systemImage: "square.and.arrow.up") }
                } else {
                    Text("No invite link (not owner, or closed)").foregroundStyle(.secondary)
                }
            }

            if let state {
                Section("Members (\(state.members.count)) · epoch \(state.epoch)") {
                    ForEach(state.members, id: \.memberId) { member in
                        Text("\(member.nickname ?? member.memberId.prefix(8).description)\(member.isOwner ? " 👑" : "")\(member.hasKey ? "" : " (no key)")")
                    }
                }
                Section("Messages (\(state.messages.count))") {
                    ForEach(state.messages, id: \.eventId) { message in
                        VStack(alignment: message.isMine ? .trailing : .leading) {
                            Text(message.text)
                            Text("#\(message.seq) · \(message.authorMemberId.prefix(6))").font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: message.isMine ? .trailing : .leading)
                    }
                    if state.pendingDecryptCount > 0 { Text("\(state.pendingDecryptCount) undecryptable").foregroundStyle(.orange) }
                    if state.hasGap { Text("history gap").foregroundStyle(.orange) }
                }
            }

            Section("Send") {
                TextField("Message", text: $draft)
                Button("Send") { run("send") { try await store.send(groupId, text: draft); draft = "" } }
                    .disabled(draft.isEmpty)
            }

            Section("Actions") {
                Button("Sync now") { run("sync") { await store.sync(groupId) } }
                Button("Connect live socket") { run("connect") { await store.connect(groupId) } }
                Button("Disconnect live socket") { run("disconnect") { await store.disconnect(groupId) } }
                Button("Request key") { run("requestKey") { try await store.requestKey(groupId) } }
                Button("Relay keys") { run("relayKeys") { await store.relayKeys(for: groupId, force: true) } }
                Button("Rotate if needed") { run("rotate") { await store.rotateIfNeeded(groupId) } }
                Button("Leave group", role: .destructive) { run("leave") { try await store.leave(groupId) } }
            }

            if status != nil || store.lastError != nil {
                Section("Status") {
                    if let status { Text(status).font(.caption) }
                    if let error = store.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle(state?.meta?.name ?? groupId.prefix(8).description)
        .task {
            await store.sync(groupId)
            store.markRead(groupId)
            if let link = store.inviteLink(for: groupId) { print("GROUPHARNESS invite \(link.absoluteString)") }
        }
        .onChange(of: state?.messages.count ?? 0) { _ in
            print("GROUPHARNESS messages \(state?.messages.map { "\($0.isMine ? "me" : "peer"):\($0.text)" } ?? [])")
        }
    }

    private func run(_ label: String, _ work: @escaping () async throws -> Void) {
        Task {
            do { try await work(); status = "\(label): ok" }
            catch { status = "\(label) failed: \(error)" }
        }
    }
}

/// Scripted second member for simulator runs, driven by launch arguments:
/// `-groupHarnessJoin <invite link> [-groupHarnessNick <name>] [-groupHarnessSend <text>]`.
enum GroupHarnessAutorun {
    @MainActor
    static func runIfRequested(_ store: GroupStore) async {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: "groupHarnessJoin"), let link = URL(string: raw) else { return }
        do {
            let id: String
            if let invite = GroupInviteLink.parse(link), store.groups.contains(where: { $0.groupId == invite.groupId }) {
                id = invite.groupId
            } else {
                id = try await store.join(link: link, as: .anon, nickname: defaults.string(forKey: "groupHarnessNick"))
            }
            print("GROUPHARNESS joined \(id)")
            await store.connect(id)
            let text = defaults.string(forKey: "groupHarnessSend")
            var sent = false
            for round in 0..<100 {
                await store.sync(id)
                if !sent, let text {
                    do {
                        try await store.send(id, text: text)
                        sent = true
                        print("GROUPHARNESS sent \(text)")
                    } catch {
                        if round % 5 == 0 { try? await store.requestKey(id) }
                        print("GROUPHARNESS send pending: \(error)")
                    }
                }
                let lines = store.states[id]?.messages.map { "\($0.isMine ? "me" : "peer"):\($0.text)" } ?? []
                print("GROUPHARNESS messages \(lines) members \(store.states[id]?.members.count ?? 0) error \(store.lastError ?? "-")")
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        } catch {
            print("GROUPHARNESS failed \(error)")
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
