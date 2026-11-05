struct SearchNodeInfo: Equatable {
    var role: String?
    var focused: Bool
    var selectionSettable: Bool

    var isPreferred: Bool {
        focused && (selectionSettable || role == "AXTextArea" || role == "AXTextField")
    }
}

struct SearchLimits {
    var maxVisited = 6000
    var maxDepth = 40
    var maxMs = 600
}

struct SearchResult<Node> {
    var found: Node?
    var preferred = false
    var visited: Int
    var elapsedMs: Int
}

enum FocusedDescendantSearch {
    /// Breadth first below the root: the first preferred focused node, else the deepest focused one.
    static func find<Node>(
        in root: Node, limits: SearchLimits = SearchLimits(), elapsedMs: () -> Int,
        info: (Node) -> SearchNodeInfo, children: (Node) -> [Node]
    ) -> SearchResult<Node> {
        var queue: [(node: Node, depth: Int)] = limits.maxDepth >= 1 ? children(root).map { ($0, 1) } : []
        var next = 0
        var visited = 0
        var deepest: (node: Node, depth: Int)?
        while next < queue.count {
            guard visited < limits.maxVisited, elapsedMs() <= limits.maxMs else { break }
            let (node, depth) = queue[next]
            next += 1
            visited += 1
            let details = info(node)
            if details.focused {
                if details.isPreferred { return SearchResult(found: node, preferred: true, visited: visited, elapsedMs: elapsedMs()) }
                if depth > (deepest?.depth ?? 0) { deepest = (node, depth) }
            }
            if depth < limits.maxDepth { queue += children(node).map { ($0, depth + 1) } }
        }
        return SearchResult(found: deepest?.node, visited: visited, elapsedMs: elapsedMs())
    }
}
