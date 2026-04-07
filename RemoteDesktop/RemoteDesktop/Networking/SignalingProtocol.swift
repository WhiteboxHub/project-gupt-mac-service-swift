//
//  SignalingProtocol.swift
//  RemoteDesktop
//
//  Signaling server protocol definitions
//

import Foundation

// MARK: - Signaling Message Types

/// Base protocol for all signaling messages
protocol SignalingMessage: Codable {
    var type: String { get }
    var timestamp: UInt64 { get }
}

// MARK: - Client → Server Messages

/// Host registers a session
struct RegisterMessage: SignalingMessage {
    let type: String = "register"
    let timestamp: UInt64
    let sessionID: String
    let port: UInt16
    let deviceName: String?

    enum CodingKeys: String, CodingKey {
        case type
        case timestamp
        case sessionID = "session_id"
        case port
        case deviceName = "device_name"
    }
}

/// Client requests peer information
struct ConnectMessage: SignalingMessage {
    let type: String = "connect"
    let timestamp: UInt64
    let sessionID: String
    let clientName: String?

    enum CodingKeys: String, CodingKey {
        case type
        case timestamp
        case sessionID = "session_id"
        case clientName = "client_name"
    }
}

/// Heartbeat to keep connection alive
struct HeartbeatMessage: SignalingMessage {
    let type: String = "heartbeat"
    let timestamp: UInt64
}

/// Unregister session
struct UnregisterMessage: SignalingMessage {
    let type: String = "unregister"
    let timestamp: UInt64
    let sessionID: String

    enum CodingKeys: String, CodingKey {
        case type
        case timestamp
        case sessionID = "session_id"
    }
}

// MARK: - Server → Client Messages

/// Server acknowledges registration
struct RegisteredMessage: Codable {
    let type: String
    let sessionID: String
    let expiresIn: Int
    let timestamp: UInt64

    enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "session_id"
        case expiresIn = "expires_in"
        case timestamp
    }
}

/// Server provides peer information
struct PeerInfoMessage: Codable {
    let type: String
    let sessionID: String
    let peer: PeerInfo
    let timestamp: UInt64

    enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "session_id"
        case peer
        case timestamp
    }
}

/// Peer connection details
struct PeerInfo: Codable {
    let ip: String
    let port: UInt16
    let publicKey: String?

    enum CodingKeys: String, CodingKey {
        case ip
        case port
        case publicKey = "public_key"
    }
}

/// Server error response
struct SignalingErrorMessage: Codable {
    let type: String
    let code: String
    let message: String
    let timestamp: UInt64
}

/// Heartbeat acknowledgment
struct HeartbeatAckMessage: Codable {
    let type: String
    let timestamp: UInt64
}

// MARK: - Message Envelope

/// Wrapper for all signaling messages
enum SignalingMessageType: String, Codable {
    case register
    case registered
    case connect
    case peerInfo = "peer_info"
    case error
    case heartbeat
    case heartbeatAck = "heartbeat_ack"
    case unregister
}

/// Decode any signaling message
struct SignalingMessageEnvelope: Codable {
    let type: SignalingMessageType

    /// Decode the specific message type
    func decode(from data: Data) throws -> Any {
        let decoder = JSONDecoder()

        switch type {
        case .register:
            return try decoder.decode(RegisterMessage.self, from: data)
        case .registered:
            return try decoder.decode(RegisteredMessage.self, from: data)
        case .connect:
            return try decoder.decode(ConnectMessage.self, from: data)
        case .peerInfo:
            return try decoder.decode(PeerInfoMessage.self, from: data)
        case .error:
            return try decoder.decode(SignalingErrorMessage.self, from: data)
        case .heartbeat:
            return try decoder.decode(HeartbeatMessage.self, from: data)
        case .heartbeatAck:
            return try decoder.decode(HeartbeatAckMessage.self, from: data)
        case .unregister:
            return try decoder.decode(UnregisterMessage.self, from: data)
        }
    }
}

// MARK: - Error Codes

enum SignalingErrorCode: String {
    case sessionNotFound = "session_not_found"
    case sessionExpired = "session_expired"
    case invalidMessage = "invalid_message"
    case serverError = "server_error"
    case unauthorized = "unauthorized"
    case sessionAlreadyExists = "session_already_exists"
}

// MARK: - Helper Extensions

extension SignalingMessage {
    /// Current timestamp in microseconds
    static func currentTimestamp() -> UInt64 {
        return UInt64(Date().timeIntervalSince1970 * 1_000_000)
    }
}

// MARK: - Message Builder

struct SignalingMessageBuilder {
    /// Create register message
    static func register(sessionID: String, port: UInt16, deviceName: String? = nil) -> RegisterMessage {
        return RegisterMessage(
            timestamp: SignalingMessage.currentTimestamp(),
            sessionID: sessionID,
            port: port,
            deviceName: deviceName
        )
    }

    /// Create connect message
    static func connect(sessionID: String, clientName: String? = nil) -> ConnectMessage {
        return ConnectMessage(
            timestamp: SignalingMessage.currentTimestamp(),
            sessionID: sessionID,
            clientName: clientName
        )
    }

    /// Create heartbeat message
    static func heartbeat() -> HeartbeatMessage {
        return HeartbeatMessage(
            timestamp: SignalingMessage.currentTimestamp()
        )
    }

    /// Create unregister message
    static func unregister(sessionID: String) -> UnregisterMessage {
        return UnregisterMessage(
            timestamp: SignalingMessage.currentTimestamp(),
            sessionID: sessionID
        )
    }
}
