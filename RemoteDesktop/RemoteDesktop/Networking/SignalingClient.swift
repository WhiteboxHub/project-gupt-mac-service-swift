//
//  SignalingClient.swift
//  RemoteDesktop
//
//  WebSocket client for signaling server communication
//

import Foundation
import os.log

/// Delegate for signaling events
protocol SignalingClientDelegate: AnyObject {
    func signalingClient(_ client: SignalingClient, didReceivePeerInfo info: PeerInfo, for sessionID: String)
    func signalingClient(_ client: SignalingClient, didRegisterSession sessionID: String, expiresIn: Int)
    func signalingClient(_ client: SignalingClient, didFailWithError error: SignalingError)
    func signalingClientDidConnect(_ client: SignalingClient)
    func signalingClientDidDisconnect(_ client: SignalingClient)
}

/// Signaling client errors
enum SignalingError: Error, LocalizedError {
    case connectionFailed(String)
    case timeout
    case invalidResponse
    case sessionNotFound(String)
    case serverError(code: String, message: String)
    case alreadyConnected
    case notConnected
    case encodingFailed
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .timeout:
            return "Connection timeout"
        case .invalidResponse:
            return "Invalid server response"
        case .sessionNotFound(let sessionID):
            return "Session '\(sessionID)' not found"
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        case .alreadyConnected:
            return "Already connected"
        case .notConnected:
            return "Not connected to signaling server"
        case .encodingFailed:
            return "Failed to encode message"
        case .decodingFailed:
            return "Failed to decode response"
        }
    }
}

/// WebSocket-based signaling client
actor SignalingClient {
    private let logger = Logger(subsystem: "com.remotedesktop", category: "SignalingClient")
    private let configuration: SignalingConfiguration

    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var isConnected = false
    private var heartbeatTask: Task<Void, Never>?

    weak var delegate: SignalingClientDelegate?

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Initialization

    init(configuration: SignalingConfiguration) {
        self.configuration = configuration
    }

    deinit {
        Task { await disconnect() }
    }

    // MARK: - Connection Management

    /// Connect to signaling server
    func connect() async throws {
        guard !isConnected else {
            throw SignalingError.alreadyConnected
        }

        logger.info("Connecting to signaling server: \(self.configuration.serverURL.absoluteString)")

        // Create URL session
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = configuration.timeout
        config.timeoutIntervalForResource = configuration.timeout * 2

        let urlSession = URLSession(configuration: config, delegate: nil, delegateQueue: nil)
        self.session = urlSession

        // Create WebSocket task
        let ws = urlSession.webSocketTask(with: configuration.serverURL)
        self.webSocket = ws

        // Start connection
        ws.resume()

        // Wait for connection with timeout
        try await withTimeout(configuration.timeout) {
            // Connection is established when we can send/receive
            // For simplicity, we'll consider it connected immediately
            // In production, you might want to wait for a server hello message
        }

        isConnected = true
        logger.info("Connected to signaling server")

        // Start receiving messages
        startReceiving()

        // Start heartbeat
        startHeartbeat()

        // Notify delegate
        await notifyDelegate { $0.signalingClientDidConnect(self) }
    }

    /// Disconnect from signaling server
    func disconnect() {
        guard isConnected else { return }

        logger.info("Disconnecting from signaling server")

        // Stop heartbeat
        heartbeatTask?.cancel()
        heartbeatTask = nil

        // Close WebSocket
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil

        // Invalidate session
        session?.invalidateAndCancel()
        session = nil

        isConnected = false

        // Notify delegate
        Task {
            await notifyDelegate { $0.signalingClientDidDisconnect(self) }
        }
    }

    // MARK: - Registration

    /// Register session as host
    func register(sessionID: String, port: UInt16, deviceName: String? = nil) async throws {
        guard isConnected else {
            throw SignalingError.notConnected
        }

        logger.info("Registering session: \(sessionID)")

        let message = SignalingMessageBuilder.register(
            sessionID: sessionID,
            port: port,
            deviceName: deviceName
        )

        try await send(message)
    }

    /// Unregister session
    func unregister(sessionID: String) async throws {
        guard isConnected else {
            throw SignalingError.notConnected
        }

        logger.info("Unregistering session: \(sessionID)")

        let message = SignalingMessageBuilder.unregister(sessionID: sessionID)
        try await send(message)
    }

    // MARK: - Discovery

    /// Request peer information for session
    func requestPeer(sessionID: String, clientName: String? = nil) async throws -> PeerInfo {
        guard isConnected else {
            throw SignalingError.notConnected
        }

        logger.info("Requesting peer info for session: \(sessionID)")

        let message = SignalingMessageBuilder.connect(
            sessionID: sessionID,
            clientName: clientName
        )

        try await send(message)

        // Wait for peer info response
        return try await withTimeout(configuration.timeout) {
            // In a real implementation, you would wait for the specific response
            // For now, this is a placeholder
            // The actual response will come through the receive loop
            throw SignalingError.timeout
        }
    }

    // MARK: - Messaging

    /// Send message to signaling server
    private func send<T: SignalingMessage>(_ message: T) async throws {
        guard let webSocket = webSocket else {
            throw SignalingError.notConnected
        }

        let data = try encoder.encode(message)
        let wsMessage = URLSessionWebSocketTask.Message.data(data)

        try await webSocket.send(wsMessage)

        logger.debug("Sent message: \(message.type)")
    }

    /// Send heartbeat
    private func sendHeartbeat() async {
        guard isConnected else { return }

        do {
            let message = SignalingMessageBuilder.heartbeat()
            try await send(message)
            logger.debug("Sent heartbeat")
        } catch {
            logger.error("Failed to send heartbeat: \(error.localizedDescription)")
        }
    }

    // MARK: - Receiving

    /// Start receiving messages
    private func startReceiving() {
        Task {
            await receiveLoop()
        }
    }

    /// Continuous receive loop
    private func receiveLoop() async {
        guard let webSocket = webSocket else { return }

        while isConnected {
            do {
                let message = try await webSocket.receive()

                switch message {
                case .data(let data):
                    await handleMessage(data)

                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        await handleMessage(data)
                    }

                @unknown default:
                    logger.warning("Received unknown message type")
                }
            } catch {
                if isConnected {
                    logger.error("Receive error: \(error.localizedDescription)")
                    await handleReceiveError(error)
                }
                break
            }
        }
    }

    /// Handle received message
    private func handleMessage(_ data: Data) async {
        do {
            // Decode message type first
            let envelope = try decoder.decode(SignalingMessageEnvelope.self, from: data)

            logger.debug("Received message: \(envelope.type.rawValue)")

            switch envelope.type {
            case .registered:
                let msg = try decoder.decode(RegisteredMessage.self, from: data)
                await handleRegistered(msg)

            case .peerInfo:
                let msg = try decoder.decode(PeerInfoMessage.self, from: data)
                await handlePeerInfo(msg)

            case .error:
                let msg = try decoder.decode(SignalingErrorMessage.self, from: data)
                await handleError(msg)

            case .heartbeatAck:
                logger.debug("Received heartbeat ack")

            default:
                logger.warning("Unhandled message type: \(envelope.type.rawValue)")
            }
        } catch {
            logger.error("Failed to decode message: \(error.localizedDescription)")
            await notifyDelegate { delegate in
                delegate.signalingClient(self, didFailWithError: .decodingFailed)
            }
        }
    }

    /// Handle registered message
    private func handleRegistered(_ message: RegisteredMessage) async {
        logger.info("Session registered: \(message.sessionID), expires in \(message.expiresIn)s")

        await notifyDelegate { delegate in
            delegate.signalingClient(
                self,
                didRegisterSession: message.sessionID,
                expiresIn: message.expiresIn
            )
        }
    }

    /// Handle peer info message
    private func handlePeerInfo(_ message: PeerInfoMessage) async {
        logger.info("Received peer info for session \(message.sessionID): \(message.peer.ip):\(message.peer.port)")

        await notifyDelegate { delegate in
            delegate.signalingClient(
                self,
                didReceivePeerInfo: message.peer,
                for: message.sessionID
            )
        }
    }

    /// Handle error message
    private func handleError(_ message: SignalingErrorMessage) async {
        logger.error("Signaling error: \(message.code) - \(message.message)")

        let error = SignalingError.serverError(code: message.code, message: message.message)

        await notifyDelegate { delegate in
            delegate.signalingClient(self, didFailWithError: error)
        }
    }

    /// Handle receive error
    private func handleReceiveError(_ error: Error) async {
        logger.error("Receive error: \(error.localizedDescription)")

        let signalingError = SignalingError.connectionFailed(error.localizedDescription)

        await notifyDelegate { delegate in
            delegate.signalingClient(self, didFailWithError: signalingError)
        }

        // Disconnect on error
        disconnect()
    }

    // MARK: - Heartbeat

    /// Start heartbeat timer
    private func startHeartbeat() {
        heartbeatTask?.cancel()

        heartbeatTask = Task {
            while !Task.isCancelled && isConnected {
                try? await Task.sleep(nanoseconds: UInt64(configuration.heartbeatInterval * 1_000_000_000))

                if !Task.isCancelled && isConnected {
                    await sendHeartbeat()
                }
            }
        }
    }

    // MARK: - Helpers

    /// Notify delegate on main actor
    private func notifyDelegate(_ handler: @escaping (SignalingClientDelegate) -> Void) async {
        guard let delegate = delegate else { return }

        await MainActor.run {
            handler(delegate)
        }
    }

    /// Execute with timeout
    private func withTimeout<T>(_ timeout: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                return try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw SignalingError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - State

    var connectionState: Bool {
        return isConnected
    }
}
