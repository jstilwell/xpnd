import Foundation
import xpndRDP

/// FreeRDP's error names (`ERRCONNECT_*`, `ERRINFO_*`) in the words of "Disconnected: <reason>".
enum RDPErrorText {
    /// Failures to reach the server, which a dropped session also ends with.
    static let transportErrors: Set = ["ERRCONNECT_CONNECT_TRANSPORT_FAILED", "ERRCONNECT_CONNECT_FAILED", "ERRCONNECT_DNS_NAME_NOT_FOUND"]
    /// Ends the user asked for, from Windows: the tab closes as if they had closed it.
    private static let cleanEnds: Set = ["ERRINFO_LOGOFF_BY_USER", "ERRINFO_RPC_INITIATED_LOGOFF", "ERRINFO_RPC_INITIATED_DISCONNECT_BY_USER"]
    /// `XPRDPSession.start` failed before connecting (the context or a setting).
    static let startFailed = "the session could not start"
    private static let reasons = [
        "ERRCONNECT_LOGON_FAILURE": "logon failed",
        "ERRCONNECT_ACCESS_DENIED": "access denied",
        "ERRCONNECT_WRONG_PASSWORD": "the password was rejected",
        "ERRCONNECT_PASSWORD_EXPIRED": "the password has expired",
        "ERRCONNECT_PASSWORD_CERTAINLY_EXPIRED": "the password has expired",
        "ERRCONNECT_PASSWORD_MUST_CHANGE": "the password must be changed",
        "ERRCONNECT_ACCOUNT_LOCKED_OUT": "the account is locked out",
        "ERRCONNECT_ACCOUNT_DISABLED": "the account is disabled",
        "ERRCONNECT_AUTHENTICATION_FAILED": "authentication failed",
        "ERRCONNECT_ACCOUNT_EXPIRED": "the account has expired",
        "ERRCONNECT_ACCOUNT_RESTRICTION": "the account's restrictions don't allow this sign-in (a blank password, logon hours or allowed computers)",
        "ERRCONNECT_LOGON_TYPE_NOT_GRANTED": "the account may not sign in remotely to this computer (it needs to be in Remote Desktop Users)",
        "ERRCONNECT_INSUFFICIENT_PRIVILEGES": "the account doesn't have permission to connect",
        "ERRINFO_SERVER_INSUFFICIENT_PRIVILEGES": "the account doesn't have permission to connect",
        "ERRCONNECT_NO_OR_MISSING_CREDENTIALS": "no login was given",
        "ERRCONNECT_CLIENT_REVOKED": "the account's sign-in was revoked",
        "ERRCONNECT_KDC_UNREACHABLE": "the domain controller couldn't be reached",
        "ERRCONNECT_NTLM_BLOCKED": "the server doesn't allow NTLM sign-in",
        "ERRCONNECT_HYBRID_REQUIRED_BY_SERVER": "the server requires Network Level Authentication (turn it on for this connection)",
        "ERRCONNECT_ACTIVATION_TIMEOUT": "the server took too long to start the session",
        "ERRCONNECT_TARGET_BOOTING": "the computer is still starting up",
        "ERRCONNECT_DNS_ERROR": "the host name could not be resolved",
        "ERRCONNECT_CONNECT_TRANSPORT_FAILED": "the connection timed out",
        "ERRCONNECT_CONNECT_FAILED": "the server refused the connection",
        "ERRCONNECT_TLS_CONNECT_FAILED": "the secure connection failed",
        "ERRCONNECT_SECURITY_NEGO_CONNECT_FAILED": "the server doesn't accept this connection's security (check its Network Level Authentication option)",
        XPRDPErrorCertificateRejected: "the certificate was rejected",
        "ERRCONNECT_CONNECT_CANCELLED": "cancelled",
        "ERRCONNECT_DNS_NAME_NOT_FOUND": "the host name could not be resolved",
        "ERRINFO_DISCONNECTED_BY_OTHER_CONNECTION": "another client took over the session",
    ]

    static func isClean(_ name: String?) -> Bool {
        name.map(cleanEnds.contains) ?? true
    }

    /// The server rejected the login, so the sheet asks again instead of the password being resent.
    /// An expired, locked or disabled account isn't one: another try can't fix it.
    private static let rejectedLogins: Set = [
        "ERRCONNECT_LOGON_FAILURE", "ERRCONNECT_ACCESS_DENIED", "ERRCONNECT_WRONG_PASSWORD", "ERRCONNECT_AUTHENTICATION_FAILED",
    ]

    static func needsNewPassword(_ name: String?) -> Bool {
        name.map(rejectedLogins.contains) ?? false
    }

    /// One line for the password sheet a rejected login brings up, so it says why it is asking; nil otherwise.
    static func rejectionNote(forErrorName name: String?) -> String? {
        guard let name, needsNewPassword(name) else { return nil }
        let note = "Windows answered: \(reason(forErrorName: name))."
        // FreeRDP reports this when the login was right and the account may not open a session on this host.
        return name == "ERRCONNECT_ACCESS_DENIED"
            ? note + " The password may be right and the account not allowed to connect to this computer." : note
    }

    /// `afterConnect`: the session had been up, so a transport failure means the network went away.
    static func reason(forErrorName name: String?, afterConnect: Bool = false) -> String {
        guard let name else { return "the server closed the session" }
        if afterConnect, transportErrors.contains(name) { return "the network connection was lost" }
        if let reason = reasons[name] { return reason }
        if name.hasPrefix("ERRINFO_") { return "the server closed the session (\(name))" }
        return name.hasPrefix("ERRCONNECT_") ? "the connection failed (\(name))" : name
    }
}

/// FreeRDP's Mac client has no reconnect loop of its own, so `RDPHost` retries a dropped session.
enum RDPReconnectPolicy {
    static let delay = Duration.seconds(2)

    /// `attempt`: retries already made since the session was last up. Only a lost network connection
    /// after a successful connect is retried: a server that ends the session (idle or logon timeout, an
    /// administrator, another client) means it, and the tab ends with its reason.
    static func shouldRetry(errorName: String?, hadConnected: Bool, attempt: Int, config: RDPSessionConfig) -> Bool {
        guard let errorName, hadConnected, config.autoReconnect, attempt < config.reconnectTries else { return false }
        return RDPErrorText.transportErrors.contains(errorName)
    }
}
