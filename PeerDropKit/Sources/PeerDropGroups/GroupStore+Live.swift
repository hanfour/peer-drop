import Foundation

extension GroupStore {
    /// Opens one live socket for a locally available group.
    public func connect(_ id: String) async {
        guard !isMock else { return }
        guard Self.isValidGroupId(id) else {
            lastError = Self.safeErrorDescription(.badId)
            return
        }
        guard liveSockets[id] == nil,
              let client,
              let secrets,
              let state = states[id],
              state.state != .removed,
              let identity = secrets.identity(for: id),
              identity.memberId == state.myMemberId else { return }

        let memberId = state.myMemberId
        let socket = GroupSocket(
            groupId: id,
            baseURL: liveSocketBaseURL,
            ticket: { [client] in try await client.wsTicket(id: id, memberId: memberId) },
            factory: liveSocketFactory,
            onEvent: { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.ingest([event], into: id)
                }
            },
            onClosed: { [weak self] reason in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch reason {
                    case .removed:
                        self.handleSyncError(GroupError.notMember, groupId: id)
                        self.liveSockets[id] = nil
                    case .reconnected:
                        await self.sync(id)
                    }
                }
            },
            clock: liveSocketClock
        )
        liveSockets[id] = socket
        await socket.start()
    }

    /// Closes and releases the live socket for a group, if present.
    public func disconnect(_ id: String) async {
        guard let socket = liveSockets.removeValue(forKey: id) else { return }
        await socket.stop()
    }
}
