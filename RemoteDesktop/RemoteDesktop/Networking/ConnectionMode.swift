//
//  ConnectionMode.swift
//  RemoteDesktop
//
//  Connection mode and state definitions
//

import Foundation

// MARK: - Connection Mode

/// Connection establishment mode
enum ConnectionMode: Equatable {
    case signaling(serverURL: URL)
    case direct
    case auto(signalingURL: URL)  // Try signaling first, fallback to direct

    var isSignalingEnabled: Bool {
        switch self {
        case .signaling, .auto:
            return true
        case .direct:
            return false
        }
    }

    var signalingURL: URL? {
        switch self {
        case .signaling(let url), .auto(let url):
            return url
        case .direct:
            return nil
        }
    }
}

// MARK: - Connection Target

/// Target for client connection
enum ConnectionTarget {
    case sessionID(String)  // For signaling mode
    case direct(host: String, port: UInt16)  // For direct mode

    var sessionID: String? {
        if case .sessionID(let id) = self {
            return id
        }
        return nil
    }

    var directAddress: (host: String, port: UInt16)? {
        if case .direct(let host, let port) = self {
            return (host, port)
        }
        return nil
    }
}

// MARK: - Connection State

/// State machine for connection establishment
enum ConnectionState: Equatable {
    case idle
    case connectingToSignaling
    case discoveringPeer(sessionID: String)
    case connectingToPeer(host: String, port: UInt16)
    case connected
    case fallingBackToDirect(reason: String)
    case failed(error: String)

    var isActive: Bool {
        switch self {
        case .connected:
            return true
        default:
            return false
        }
    }

    var isConnecting: Bool {
        switch self {
        case .connectingToSignaling, .discoveringPeer, .connectingToPeer:
            return true
        default:
            return false
        }
    }

    var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }

    /// Human-readable description
    var description: String {
        switch self {
        case .idle:
            return "Idle"
        case .connectingToSignaling:
            return "Connecting to signaling server..."
        case .discoveringPeer(let sessionID):
            return "Discovering peer (Session: \(sessionID))..."
        case .connectingToPeer(let host, let port):
            return "Connecting to \(host):\(port)..."
        case .connected:
            return "Connected"
        case .fallingBackToDirect(let reason):
            return "Falling back to direct connection (\(reason))"
        case .failed(let error):
            return "Failed: \(error)"
        }
    }
}

// MARK: - Fallback Trigger

/// Reasons for triggering fallback to direct mode
enum FallbackTrigger {
    case signalingServerUnreachable(timeout: TimeInterval)
    case sessionNotFound(sessionID: String)
    case peerUnreachable(ip: String, port: UInt16)
    case connectionTimeout(duration: TimeInterval)
    case tlsHandshakeFailure
    case signalingError(code: String, message: String)

    var description: String {
        switch self {
        case .signalingServerUnreachable(let timeout):
            return "Signaling server unreachable (timeout: \(timeout)s)"
        case .sessionNotFound(let sessionID):
            return "Session '\(sessionID)' not found"
        case .peerUnreachable(let ip, let port):
            return "Peer \(ip):\(port) unreachable"
        case .connectionTimeout(let duration):
            return "Connection timeout (\(duration)s)"
        case .tlsHandshakeFailure:
            return "TLS handshake failed"
        case .signalingError(let code, let message):
            return "Signaling error: \(code) - \(message)"
        }
    }

    var shouldRetry: Bool {
        switch self {
        case .signalingServerUnreachable, .peerUnreachable, .connectionTimeout:
            return false  // Retry unlikely to help
        case .sessionNotFound, .tlsHandshakeFailure, .signalingError:
            return false  // User action required
        }
    }
}

// MARK: - Signaling Configuration

/// Configuration for signaling server
struct SignalingConfiguration: Codable {
    var enabled: Bool
    var serverURL: URL
    var timeout: TimeInterval
    var heartbeatInterval: TimeInterval
    var autoFallback: Bool
    var sessionIDLength: Int

    init(
        enabled: Bool = true,
        serverURL: URL = URL(string: "ws://localhost:8080")!,
        timeout: TimeInterval = 5.0,
        heartbeatInterval: TimeInterval = 30.0,
        autoFallback: Bool = true,
        sessionIDLength: Int = 8
    ) {
        self.enabled = enabled
        self.serverURL = serverURL
        self.timeout = timeout
        self.heartbeatInterval = heartbeatInterval
        self.autoFallback = autoFallback
        self.sessionIDLength = sessionIDLength
    }

    /// Default configuration
    static let `default` = SignalingConfiguration()

    /// Development configuration (local server)
    static let development = SignalingConfiguration(
        serverURL: URL(string: "ws://localhost:8080")!
    )

    /// Production configuration
    static let production = SignalingConfiguration(
        serverURL: URL(string: "wss://signal.remotedesktop.example.com")!,
        timeout: 10.0
    )

    /// Check if URL is secure (WSS)
    var isSecure: Bool {
        return serverURL.scheme == "wss"
    }
}

// MARK: - Session ID Generator

struct SessionIDGenerator {
    /// Generate random session ID
    static func generate(length: Int = 8) -> String {
        let characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map { _ in
            characters.randomElement()!
        })
    }

    /// Validate session ID format
    static func validate(_ sessionID: String) -> Bool {
        let pattern = "^[A-Z0-9]{6,12}$"
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: sessionID.utf16.count)
        return regex?.firstMatch(in: sessionID, range: range) != nil
    }
}

// MARK: - Connection Metrics

/// Track connection establishment metrics
struct ConnectionMetrics {
    var signalingConnectTime: TimeInterval?
    var peerDiscoveryTime: TimeInterval?
    var peerConnectTime: TimeInterval?
    var totalTime: TimeInterval?
    var fallbackTriggered: Bool = false
    var mode: ConnectionMode?

    mutating func recordSignalingConnect(_ duration: TimeInterval) {
        signalingConnectTime = duration
    }

    mutating func recordPeerDiscovery(_ duration: TimeInterval) {
        peerDiscoveryTime = duration
    }

    mutating func recordPeerConnect(_ duration: TimeInterval) {
        peerConnectTime = duration
    }

    mutating func recordTotal(_ duration: TimeInterval) {
        totalTime = duration
    }

    mutating func recordFallback() {
        fallbackTriggered = true
    }

    /// Summary string
    var summary: String {
        var parts: [String] = []

        if let signaling = signalingConnectTime {
            parts.append("Signaling: \(String(format: "%.1f", signaling * 1000))ms")
        }

        if let discovery = peerDiscoveryTime {
            parts.append("Discovery: \(String(format: "%.1f", discovery * 1000))ms")
        }

        if let connect = peerConnectTime {
            parts.append("P2P Connect: \(String(format: "%.1f", connect * 1000))ms")
        }

        if let total = totalTime {
            parts.append("Total: \(String(format: "%.1f", total * 1000))ms")
        }

        if fallbackTriggered {
            parts.append("Fallback: YES")
        }

        return parts.joined(separator: ", ")
    }
}
