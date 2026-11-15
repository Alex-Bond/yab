// Default source. A qualified PREPARATION may rewrite only this tracked file in
// its owned farm snapshot before main compilation; exact source SHA is sealed.
// These are diagnostic pins ONLY. Production accepted version/set stay0/empty.
enum CompiledOriginalHelperImagePolicy {
    static let version = 0
    static let candidateIdentifier = ""
    static let helperIdentifier = ""
    static let helperCodeDirectories: Set<String> = []
    static let helperLeafSHA256 = ""
}
