import Testing
@testable import xpnd

struct RDPErrorTextTests {
    @Test func errorNamesMapToPlainReasons() {
        let cases: [(String?, String)] = [
            ("ERRCONNECT_LOGON_FAILURE", "logon failed"),
            ("ERRCONNECT_ACCESS_DENIED", "access denied"),
            ("ERRCONNECT_CONNECT_TRANSPORT_FAILED", "the connection timed out"),
            ("ERRCONNECT_CONNECT_FAILED", "the connection timed out"),
            ("ERRCONNECT_TLS_CONNECT_FAILED", "the certificate was rejected"),
            ("ERRCONNECT_CONNECT_CANCELLED", "cancelled"),
            ("ERRCONNECT_DNS_NAME_NOT_FOUND", "the server refused the connection"),
            ("FREERDP_ERROR_FOO", "FREERDP_ERROR_FOO"),
            ("ERRINFO_IDLE_TIMEOUT", "the server closed the session (ERRINFO_IDLE_TIMEOUT)"),
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

    @Test func logoffsAreClean() {
        for name in [nil, "ERRINFO_LOGOFF_BY_USER", "ERRINFO_RPC_INITIATED_LOGOFF", "ERRINFO_RPC_INITIATED_DISCONNECT_BYUSER"] {
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

    @Test func retriesTransportAndServerSideDrops() {
        for name in ["ERRCONNECT_CONNECT_FAILED", "ERRCONNECT_DNS_NAME_NOT_FOUND", "ERRINFO_IDLE_TIMEOUT"] {
            #expect(retry(name), "\(name)")
        }
    }

    @Test func neverRetriesBeforeTheFirstConnect() {
        #expect(!retry("ERRCONNECT_CONNECT_TRANSPORT_FAILED", hadConnected: false))
    }

    @Test func neverRetriesLogonCertificateCancelOrACleanEnd() {
        for name in [nil, "ERRCONNECT_LOGON_FAILURE", "ERRCONNECT_ACCESS_DENIED", "ERRCONNECT_TLS_CONNECT_FAILED",
                     "ERRCONNECT_CONNECT_CANCELLED", "ERRINFO_LOGOFF_BY_USER", "FREERDP_ERROR_FOO"] {
            #expect(!retry(name), "\(name ?? "nil")")
        }
    }

    @Test func autoReconnectOffNeverRetries() {
        #expect(!retry("ERRCONNECT_CONNECT_TRANSPORT_FAILED", autoReconnect: false))
    }
}
