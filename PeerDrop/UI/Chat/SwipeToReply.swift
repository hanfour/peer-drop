// SwipeToReply.swift
// Drag-a-row-to-the-right to reply. SwiftUI `.swipeActions` only works inside a `List`,
// and the chat is a `ScrollView`, so this is a real DragGesture. The decision logic is
// pure (`SwipeReplyLogic`) so it can be unit-tested.

import SwiftUI
#if os(iOS)
import UIKit
#endif

enum SwipeReplyLogic {
    /// Raw rightward drag distance (pt) at which releasing triggers a reply.
    static let threshold: CGFloat = 60
    /// The row never moves further than this, however far the finger goes.
    static let maxOffset: CGFloat = 90
    /// Drag distance within which the horizontal/vertical decision may still be revised.
    static let decisionWindow: CGFloat = 16
    private static let dominanceRatio: CGFloat = 1.5

    /// Horizontal only if |dx| > 1.5 * |dy|, so vertical scrolling is never hijacked.
    static func isHorizontalDominant(dx: CGFloat, dy: CGFloat) -> Bool {
        abs(dx) > dominanceRatio * abs(dy)
    }

    /// Rubber band: slope 1 at the start, saturating toward `maxOffset`. 0 for leftward drags.
    static func rowOffset(forTranslationWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return maxOffset * (1 - exp(-width / maxOffset))
    }

    /// 0...1, reaching 1 at `threshold`.
    static func progress(forTranslationWidth width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(width / threshold, 1))
    }

    static func shouldTrigger(translationWidth: CGFloat, isHorizontal: Bool, isDeleted: Bool) -> Bool {
        isHorizontal && !isDeleted && translationWidth >= threshold
    }
}

private struct SwipeToReplyModifier: ViewModifier {
    let isEnabled: Bool
    let isDeleted: Bool
    let onReply: () -> Void

    /// Resets automatically when the gesture ends or is cancelled (e.g. a scroll takes over).
    @GestureState private var dragWidth: CGFloat = 0
    /// Decided once near the start of a drag and kept until it ends.
    @State private var isHorizontal: Bool?
    @State private var crossed = false

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .offset(x: SwipeReplyLogic.rowOffset(forTranslationWidth: dragWidth))
                .overlay(alignment: .leading) {
                    let p = SwipeReplyLogic.progress(forTranslationWidth: dragWidth)
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.body)
                        .foregroundStyle(PaperTheme.color(.accent))
                        .opacity(p)
                        .scaleEffect(0.5 + 0.5 * p)
                        .offset(x: SwipeReplyLogic.rowOffset(forTranslationWidth: dragWidth) - 36)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .updating($dragWidth) { value, state, _ in
                            guard isHorizontal == true else { return }
                            state = value.translation.width
                        }
                        .onChanged { value in
                            let t = value.translation
                            if isHorizontal == nil || hypot(t.width, t.height) <= SwipeReplyLogic.decisionWindow {
                                isHorizontal = SwipeReplyLogic.isHorizontalDominant(dx: t.width, dy: t.height)
                            }
                            let nowCrossed = isHorizontal == true && !isDeleted && t.width >= SwipeReplyLogic.threshold
                            if nowCrossed && !crossed { haptic() }
                            crossed = nowCrossed
                        }
                        .onEnded { value in
                            let trigger = SwipeReplyLogic.shouldTrigger(
                                translationWidth: value.translation.width,
                                isHorizontal: isHorizontal == true,
                                isDeleted: isDeleted
                            )
                            isHorizontal = nil
                            crossed = false
                            if trigger { onReply() }
                        }
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: dragWidth == 0)
        } else {
            content
        }
    }

    private func haptic() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}

extension View {
    /// Drag the row right past 60 pt and release to call `onReply`.
    func swipeToReply(isEnabled: Bool = true, isDeleted: Bool = false, onReply: @escaping () -> Void) -> some View {
        modifier(SwipeToReplyModifier(isEnabled: isEnabled, isDeleted: isDeleted, onReply: onReply))
    }
}
