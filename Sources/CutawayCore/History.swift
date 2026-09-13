import Foundation

/// Undo and redo for the edit.
///
/// Every edit is already a whole-file write of project.json, so history is a
/// stack of previous documents rather than a set of inverse operations. That
/// costs a few kilobytes per step and makes undo correct by construction: there
/// is no way for an inverse to be wrong, because there are no inverses.
public final class History {

    private var past: [Project] = []
    private var future: [Project] = []
    private let limit: Int
    /// Set while applying an undo, so the resulting save is not itself recorded.
    private var replaying = false
    /// While a drag is in progress only its starting state is kept, so the whole
    /// gesture undoes in one step instead of one step per mouse event.
    private var grouping = false
    private var groupRecorded = false

    public init(limit: Int = 60) {
        self.limit = limit
    }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }

    public func beginGroup() {
        grouping = true
        groupRecorded = false
    }

    public func endGroup() {
        grouping = false
        groupRecorded = false
    }

    /// Call with the state *before* a change is applied.
    public func record(_ project: Project) {
        guard !replaying else { return }
        if grouping {
            guard !groupRecorded else { return }
            groupRecorded = true
        }
        past.append(project)
        if past.count > limit { past.removeFirst() }
        // A new edit invalidates anything that was undone, which is what every
        // editor does and what people expect.
        future.removeAll()
    }

    /// - Parameter current: the state being moved away from.
    /// - Returns: the state to restore, or nil when there is nothing to undo.
    public func undo(current: Project) -> Project? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        return previous
    }

    public func redo(current: Project) -> Project? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        return next
    }

    /// Runs a restore without recording it as a new step.
    public func replay(_ body: () -> Void) {
        replaying = true
        body()
        replaying = false
    }

    public func clear() {
        past.removeAll()
        future.removeAll()
    }

    public var depth: (undo: Int, redo: Int) { (past.count, future.count) }
}
