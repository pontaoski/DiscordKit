
protocol ValidationResult {
    func get() -> [ValidationFailure]
}

extension ValidationFailure: ValidationResult {
    func get() -> [ValidationFailure] {
        [self]
    }
}

extension Array: ValidationResult where Element == ValidationFailure {
    func get() -> [ValidationFailure] {
        self
    }
}

extension Optional: ValidationResult where Wrapped: ValidationResult {
    func get() -> [ValidationFailure] {
        self?.get() ?? []
    }
}
