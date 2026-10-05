infix operator ??=: AssignmentPrecedence

/// Assigns the unwrapped value of `rhs` to `lhs` if `lhs` is currently `nil`.
public func ??= <T>(lhs: inout T?, rhs: @autoclosure () -> T?) {
    if lhs == nil { lhs = rhs() }
}
public func ??= <T>(lhs: inout T?, rhs: @autoclosure () -> T) {
    if lhs == nil { lhs = rhs() }
}
