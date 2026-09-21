import OSLog

// One logger per module so Console.app can filter down to a single concern.
nonisolated enum Loggers {
    static let subsystem = "com.prashantmahto.MyCMS"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let health = Logger(subsystem: subsystem, category: "health")
    static let data = Logger(subsystem: subsystem, category: "data")
    static let publish = Logger(subsystem: subsystem, category: "publish")
    static let git = Logger(subsystem: subsystem, category: "git")
    static let repository = Logger(subsystem: subsystem, category: "repository")
    static let onboarding = Logger(subsystem: subsystem, category: "onboarding")
    static let ai = Logger(subsystem: subsystem, category: "ai")
    static let rendering = Logger(subsystem: subsystem, category: "rendering")
    static let assets = Logger(subsystem: subsystem, category: "assets")
}
