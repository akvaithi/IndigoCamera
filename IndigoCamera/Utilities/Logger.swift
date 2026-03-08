import os

/// Centralized loggers for different subsystems.
enum Log {
    static let camera = Logger(subsystem: "com.indigo.camera", category: "Camera")
    static let processing = Logger(subsystem: "com.indigo.camera", category: "Processing")
    static let metal = Logger(subsystem: "com.indigo.camera", category: "Metal")
    static let memory = Logger(subsystem: "com.indigo.camera", category: "Memory")
    static let export = Logger(subsystem: "com.indigo.camera", category: "Export")
}
