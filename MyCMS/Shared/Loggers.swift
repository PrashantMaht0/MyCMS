import OSLog

// One logger per module so Console.app can filter down to a single concern.
nonisolated enum Loggers {
    static let subsystem = "com.prashantmahto.MyCMS"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let health = Logger(subsystem: subsystem, category: "health")
    static let data = Logger(subsystem: subsystem, category: "data")
    static let publish = Logger(subsystem: subsystem, category: "publish")
    static let git = Logger(subsystem: subsystem, category: "git")
    static let ai = Logger(subsystem: subsystem, category: "ai")
}
