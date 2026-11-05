import Testing
@testable import xpnd
import xpndRDP

struct RDPErrorTextTests {
    @Test func errorNamesMapToPlainReasons() {
        let cases: [(String?, String)] = [
            ("ERRCONNECT_LOGON_FAILURE", "logon failed"),
            ("ERRCONNECT_ACCESS_DENIED", "access denied"),
            ("ERRCONNECT_CONNECT_TRANSPORT_FAILED", "the connection timed out"),
            ("ERRCONNECT_CONNECT_FAILED", "the server refused the connection"),
            ("ERRCONNECT_TLS_CONNECT_FAILED", "the secure connection failed"),
            (XPRDPErrorCertificateRejected, "the certificate was rejected"),
            ("ERRCONNECT_CONNECT_CANCELLED", "cancelled"),
            ("ERRCONNECT_DNS_NAME_NOT_FOUND", "the host name could not be resolved"),
            ("FREERDP_ERROR_FOO", "FREERDP_ERROR_FOO"),
            ("ERRINFO_IDLE_TIMEOUT", "the server closed the session (ERRINFO_IDLE_TIMEOUT)"),
            ("ERRINFO_DISCONNECTED_BY_OTHER_CONNECTION", "another client took over the session"),
            (nil, "the server closed the session"),
        ]
        for (name, reason) in cases {
            #expect(RDPErrorText.reason(forErrorName: name) == reason, "\(name ?? "nil")")
        }
    }

    @Test func aTransportFailureAfterConnectingIsALostConnection() {
        for name in ["ERRCONNECT_CONNECT_TRANSPORT_FAILED", "ERRCONNECT_CONNECT_FAILED", "ERRCONNECT_DNS_NAME_NOT_FOUND"] {
            #expect(RDPErrorText.reason(forErrorName: name, afterConnect: true) == "the network connection was lost")
        }
        #expect(RDPErrorText.reason(forErrorName: "ERRCONNECT_LOGON_FAILURE", afterConnect: true) == "logon failed")
    }

    @Test func aSessionThatCouldNotStartSaysSo() {
        #expect(RDPErrorText.startFailed == "the session could not start")
    }

    @Test func aRejectedLoginAsksForANewPassword() {
        for name in ["ERRCONNECT_LOGON_FAILURE", "ERRCONNECT_ACCESS_DENIED", "ERRCONNECT_WRONG_PASSWORD", "ERRCONNECT_AUTHENTICATION_FAILED"] {
            #expect(RDPErrorText.needsNewPassword(name), "\(name)")
        }
        for name in [nil, "ERRCONNECT_CONNECT_TRANSPORT_FAILED", "ERRCONNECT_ACCOUNT_LOCKED_OUT", "ERRCONNECT_PASSWORD_EXPIRED",
                     "ERRCONNECT_PASSWORD_MUST_CHANGE", "ERRCONNECT_ACCOUNT_DISABLED"] {
            #expect(!RDPErrorText.needsNewPassword(name), "\(name ?? "nil")")
        }
    }

    @Test func accountAndPasswordProblemsAreWorded() {
        let cases = [
            ("ERRCONNECT_WRONG_PASSWORD", "the password was rejected"),
            ("ERRCONNECT_PASSWORD_EXPIRED", "the password has expired"),
            ("ERRCONNECT_PASSWORD_MUST_CHANGE", "the password must be changed"),
            ("ERRCONNECT_ACCOUNT_LOCKED_OUT", "the account is locked out"),
            ("ERRCONNECT_ACCOUNT_DISABLED", "the account is disabled"),
            ("ERRCONNECT_AUTHENTICATION_FAILED", "authentication failed"),
        ]
        for (name, reason) in cases {
            #expect(RDPErrorText.reason(forErrorName: name) == reason, "\(name)")
        }
    }

    @Test func logoffsAreClean() {
        for name in [nil, "ERRINFO_LOGOFF_BY_USER", "ERRINFO_RPC_INITIATED_LOGOFF", "ERRINFO_RPC_INITIATED_DISCONNECT_BY_USER"] {
            #expect(RDPErrorText.isClean(name), "\(name ?? "nil")")
        }
        #expect(!RDPErrorText.isClean("ERRINFO_IDLE_TIMEOUT"))
        #expect(!RDPErrorText.isClean("ERRCONNECT_LOGON_FAILURE"))
    }
}

struct RDPReconnectPolicyTests {
    private let config = RDPOptions().resolved(over: .standard, host: "win", port: 3389, username: nil, domain: nil)

    private func retry(_ name: String?, hadConnected: Bool = true, attempt: Int = 0, autoReconnect: Bool = true) -> Bool {
        var config = config
        config.autoReconnect = autoReconnect
        return RDPReconnectPolicy.shouldRetry(errorName: name, hadConnected: hadConnected, attempt: attempt, config: config)
    }

    @Test func retriesADropUpToTheTries() {
        #expect(config.reconnectTries == 5)
        #expect(retry("ERRCONNECT_CONNECT_TRANSPORT_FAILED", attempt: 0))
        #expect(retry("ERRCONNECT_CONNECT_TRANSPORT_FAILED", attempt: 4))
        #expect(!retry("ERRCONNECT_CONNECT_TRANSPORT_FAILED", attempt: 5))
    }

    @Test func retriesOnlyTransportDrops() {
        for name in ["ERRCONNECT_CONNECT_FAILED", "ERRCONNECT_DNS_NAME_NOT_FOUND"] {
            #expect(retry(name), "\(name)")
        }
        // The server ended the session on purpose: idle and logon timeouts, an administrator.
        for name in ["ERRINFO_IDLE_TIMEOUT", "ERRINFO_LOGON_TIMEOUT", "ERRINFO_DISCONNECTED_BY_OTHER_CONNECTION",
                     "ERRINFO_RPC_INITIATED_DISCONNECT"] {
            #expect(!retry(name), "\(name)")
        }
    }

    @Test func neverRetriesBeforeTheFirstConnect() {
        #expect(!retry("ERRCONNECT_CONNECT_TRANSPORT_FAILED", hadConnected: false))
    }

    @Test func neverRetriesLogonCertificateCancelOrACleanEnd() {
        for name in [nil, "ERRCONNECT_LOGON_FAILURE", "ERRCONNECT_ACCESS_DENIED", "ERRCONNECT_TLS_CONNECT_FAILED",
                     XPRDPErrorCertificateRejected, "ERRCONNECT_CONNECT_CANCELLED", "ERRINFO_LOGOFF_BY_USER",
                     "FREERDP_ERROR_FOO"] {
            #expect(!retry(name), "\(name ?? "nil")")
        }
    }

    @Test func autoReconnectOffNeverRetries() {
        #expect(!retry("ERRCONNECT_CONNECT_TRANSPORT_FAILED", autoReconnect: false))
    }
}
