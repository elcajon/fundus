import os

/// Protokoll über das einheitliche macOS-Log. Mitlesen mit:
/// `log stream --predicate 'subsystem == "de.max-venz.ablage"' --level debug`
enum Log {
    static let app = Logger(subsystem: "de.max-venz.ablage", category: "app")
    static let network = Logger(subsystem: "de.max-venz.ablage", category: "network")
    static let sync = Logger(subsystem: "de.max-venz.ablage", category: "sync")
    static let imports = Logger(subsystem: "de.max-venz.ablage", category: "import")
}
