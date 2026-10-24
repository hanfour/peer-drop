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
    /// Movement (pt) before the horizontal/vertical decision is made.
    static let decisionRadius: CGFloat = 12
    private static let dominanceRatio: CGFloat = 1.5

    /// Horizontal only if |dx| > 1.5 * |dy|, so vertical scrolling is never hijacked.
    static func isHorizontalDominant(dx: CGFloat, dy: CGFloat) -> Bool {
        abs(dx) > dominanceRatio * abs(dy)
    }

    /// Decide the axis ONCE: nil while movement is below `decisionRadius`; an already-decided
    /// value is kept for the rest of the drag (later wobble never flips it).
    static func decideAxis(current: Bool?, dx: CGFloat, dy: CGFloat) -> Bool? {
        if let current { return current }
        guard hypot(dx, dy) >= decisionRadius else { return nil }
        return isHorizontalDominant(dx: dx, dy: dy)
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

private struct SwipeToReplyModifier: ViewModifier, PaperThemed {
    @Environment(\.paperMode) var paperMode
    let isEnabled: Bool
    let isDeleted: Bool
    let onReply: () -> Void

    /// Per-drag state. Lives in a `@GestureState`, so it resets whenever the gesture ends OR is
    /// cancelled (scroll takeover, interruption); no decision can outlive its drag.
    private struct DragState {
        var width: CGFloat = 0
        var axis: Bool?
        var crossed = false
    }
    @GestureState private var drag = DragState()

    private var dragWidth: CGFloat { drag.axis == true ? drag.width : 0 }

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .offset(x: SwipeReplyLogic.rowOffset(forTranslationWidth: dragWidth))
                .overlay(alignment: .leading) {
                    let p = SwipeReplyLogic.progress(forTranslationWidth: dragWidth)
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.body)
                        .foregroundStyle(paper(.accent))
                        .opacity(p)
                        .scaleEffect(0.5 + 0.5 * p)
                        .offset(x: SwipeReplyLogic.rowOffset(forTranslationWidth: dragWidth) - 36)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .updating($drag) { value, state, _ in
                            let t = value.translation
                            state.axis = SwipeReplyLogic.decideAxis(current: state.axis, dx: t.width, dy: t.height)
                            state.width = t.width
                            let nowCrossed = state.axis == true && !isDeleted && t.width >= SwipeReplyLogic.threshold
                            if nowCrossed && !state.crossed { haptic() }
                            state.crossed = nowCrossed
                        }
                        .onEnded { value in
                            let t = value.translation
                            let axis = SwipeReplyLogic.decideAxis(current: nil, dx: t.width, dy: t.height)
                            if SwipeReplyLogic.shouldTrigger(
                                translationWidth: t.width,
                                isHorizontal: axis == true,
                                isDeleted: isDeleted
                            ) { onReply() }
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
