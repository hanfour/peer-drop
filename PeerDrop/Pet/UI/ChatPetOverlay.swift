import SwiftUI

struct ChatPetOverlay: View {
    @ObservedObject var engine: PetEngine
    let messageFrames: [CGRect]

    @State private var chatAction: ChatPetAction?
    @State private var updateTimer: Timer?

    private let petSize: CGFloat = 96

    var body: some View {
        Group {
            if let action = chatAction,
               let targetIdx = action.targetMessageIndex,
               targetIdx < messageFrames.count {
                let frame = messageFrames[targetIdx]
                let pos = petPosition(for: action.position, messageFrame: frame)

                SpriteImageView(image: engine.renderedImage, displaySize: petSize)
                    .opacity(0.85)
                    .allowsHitTesting(false)
                    .position(pos)
                    .transition(.opacity)
            }
        }
        .onAppear {
            updateChatBehavior()
            startUpdateTimer()
        }
        .onDisappear {
            updateTimer?.invalidate()
        }
        .onChange(of: messageFrames.count) { _ in
            updateChatBehavior()
        }
    }

    private func petPosition(for chatPos: ChatPetPosition, messageFrame: CGRect) -> CGPoint {
        switch chatPos {
        case .onTop(let offset):
            return CGPoint(x: messageFrame.midX, y: messageFrame.minY + offset)
        case .beside(let leading):
            let x = leading ? messageFrame.minX - petSize / 2 : messageFrame.maxX + petSize / 2
            return CGPoint(x: x, y: messageFrame.midY)
        case .stickedOn(let leading):
            let x = leading ? messageFrame.minX : messageFrame.maxX
            return CGPoint(x: x, y: messageFrame.midY)
        case .wrappedAround:
            return CGPoint(x: messageFrame.midX, y: messageFrame.midY)
        case .behind:
            return CGPoint(x: messageFrame.midX, y: messageFrame.midY)
        case .above(let height):
            return CGPoint(x: messageFrame.midX, y: messageFrame.minY - height)
        case .between:
            return CGPoint(x: messageFrame.midX, y: messageFrame.maxY + 10)
        case .leaningOn(let leading):
            let x = leading ? messageFrame.minX - petSize / 3 : messageFrame.maxX + petSize / 3
            return CGPoint(x: x, y: messageFrame.maxY)
        case .coiled:
            return CGPoint(x: messageFrame.midX, y: messageFrame.midY)
        case .dripping:
            return CGPoint(x: messageFrame.midX, y: messageFrame.minY - 10)
        }
    }

    private func updateChatBehavior() {
        guard !messageFrames.isEmpty else {
            chatAction = nil
            return
        }
        let petPos = engine.physicsState.position
        if let newAction = engine.behaviorProvider.chatBehavior(
            messageFrames: messageFrames, petPosition: petPos) {
            withAnimation(.easeInOut(duration: 0.3)) {
                chatAction = newAction
                engine.currentAction = newAction.action
            }
        }
    }

    private func startUpdateTimer() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
            Task { @MainActor in
                updateChatBehavior()
            }
        }
    }
}
