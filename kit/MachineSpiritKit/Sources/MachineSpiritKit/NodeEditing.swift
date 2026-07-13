import Foundation

/// Why an edit was refused. Same philosophy as `WriteError`: the pen never
/// improvises — it either produces exactly the tree the caller asked for or
/// says precisely why it won't.
public enum EditError: Error, CustomStringConvertible, Equatable {
  case parentNotFound(String)
  /// The target carries an action. Leader Key's own schema keeps groups and
  /// actions exclusive; writing a dual node into the live config would hand
  /// the running fork something upstream never produces. The model HOLDS
  /// duality (that's its point) — the pen just won't be the one to write it
  /// into a config the fork executes. Revisit when the fork is ours enough.
  case parentHasAction(String)
  /// A sibling already answers to this key — the new bind would shadow it.
  case duplicateKey(key: String, parentID: String)
  case nodeNotFound(String)
  /// Removal is leaf-only: taking a whole group is a different, heavier
  /// ritual (and a different confirm) than striking one bind.
  case notALeaf(String)
  case rootUntouchable

  public var description: String {
    switch self {
    case .parentNotFound(let id): return "no group at \(id)"
    case .parentHasAction(let id): return "\(id) is a bind, not a group — cannot hold children"
    case .duplicateKey(let key, let parentID): return "\(parentID) already binds '\(key)'"
    case .nodeNotFound(let id): return "no node at \(id)"
    case .notALeaf(let id): return "\(id) has children — remove them first"
    case .rootUntouchable: return "the root is not removable"
    }
  }
}

/// The pen's grammar: pure-value edits that return a NEW root, never
/// mutating in place. An inserted child's id is minted exactly as the
/// importer would mint it on the next re-import (`parentID/key`), so
/// selection, sidecar overrides, and fired routes never skew.
extension Node {
  /// Insert a new leaf bind under a pure group. The caller brings
  /// key/label/action; the id is not theirs to choose.
  public func insertingLeaf(
    key: String, label: String? = nil, action: ActionPayload, underGroupID parentID: String
  ) throws -> Node {
    guard let parent = node(withID: parentID) else {
      throw EditError.parentNotFound(parentID)
    }
    guard parent.action == nil else {
      throw EditError.parentHasAction(parentID)
    }
    guard !parent.children.contains(where: { $0.key == key }) else {
      throw EditError.duplicateKey(key: key, parentID: parentID)
    }
    let trimmedLabel = label?.isEmpty == true ? nil : label
    let leaf = Node(
      id: parentID + "/" + key,
      key: key,
      label: trimmedLabel,
      action: action,
      children: [],
      extras: [:],
      status: .active,  // display-only; the post-write re-import recomputes it
      hadExplicitType: true,
      hadChildrenArray: false)
    return replacing(id: parentID) { group in
      var next = group
      next.children.append(leaf)
      next.hadChildrenArray = true
      return next
    }
  }

  /// Remove one leaf bind. Groups (and the root) refuse.
  public func removingLeaf(id targetID: String) throws -> Node {
    guard targetID != id else { throw EditError.rootUntouchable }
    guard let target = node(withID: targetID) else {
      throw EditError.nodeNotFound(targetID)
    }
    guard target.children.isEmpty else { throw EditError.notALeaf(targetID) }
    return removingSubtree(id: targetID)
  }

  private func removingSubtree(id targetID: String) -> Node {
    var next = self
    next.children = children.compactMap { child in
      child.id == targetID ? nil : child.removingSubtree(id: targetID)
    }
    return next
  }

  /// Rebuild the tree with the node at `id` transformed (value semantics —
  /// the original is untouched).
  private func replacing(id targetID: String, with transform: (Node) -> Node) -> Node {
    if id == targetID { return transform(self) }
    var next = self
    next.children = children.map { $0.replacing(id: targetID, with: transform) }
    return next
  }
}
