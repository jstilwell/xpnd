import Foundation

/// FreeRDP's error names (`ERRCONNECT_*`, `ERRINFO_*`) in the words of "Disconnected: <reason>".
enum RDPErrorText {
    /// Failures to reach the server, which a dropped session also ends with.
    static let transportErrors: Set = ["ERRCONNECT_CONNECT_TRANSPORT_FAILED", "ERRCONNECT_CONNECT_FAILED", "ERRCONNECT_DNS_NAME_NOT_FOUND"]
    /// Ends the user asked for, from Windows: the tab closes as if they had closed it.
    private static let cleanEnds: Set = ["ERRINFO_LOGOFF_BY_USER", "ERRINFO_RPC_INITIATED_LOGOFF", "ERRINFO_RPC_INITIATED_DISCONNECT_BYUSER"]
    private static let reasons = [
        "ERRCONNECT_LOGON_FAILURE": "logon failed",
        "ERRCONNECT_ACCESS_DENIED": "access denied",
        "ERRCONNECT_CONNECT_TRANSPORT_FAILED": "the connection timed out",
        "ERRCONNECT_CONNECT_FAILED": "the connection timed out",
        "ERRCONNECT_TLS_CONNECT_FAILED": "the certificate was rejected",
        "ERRCONNECT_CONNECT_CANCELLED": "cancelled",
        "ERRCONNECT_DNS_NAME_NOT_FOUND": "the server refused the connection",
    ]

    static func isClean(_ name: String?) -> Bool {
        name.map(cleanEnds.contains) ?? true
    }

    /// `afterConnect`: the session had been up, so a transport failure means the network went away.
    static func reason(forErrorName name: String?, afterConnect: Bool = false) -> String {
        guard let name else { return "the server closed the session" }
        if afterConnect, transportErrors.contains(name) { return "the network connection was lost" }
        if let reason = reasons[name] { return reason }
        return name.hasPrefix("ERRINFO_") ? "the server closed the session (\(name))" : name
    }
}

/// FreeRDP's Mac client has no reconnect loop of its own, so `RDPHost` retries a dropped session.
enum RDPReconnectPolicy {
    static let delay = Duration.seconds(2)

    /// `attempt`: retries already made since the session was last up. Nothing is retried before the
    /// first successful connect, nor a logon, certificate or cancel failure, nor a clean end.
    static func shouldRetry(errorName: String?, hadConnected: Bool, attempt: Int, config: RDPSessionConfig) -> Bool {
        guard let errorName, hadConnected, config.autoReconnect, attempt < config.reconnectTries else { return false }
        return RDPErrorText.transportErrors.contains(errorName) || (errorName.hasPrefix("ERRINFO_") && !RDPErrorText.isClean(errorName))
    }
}
