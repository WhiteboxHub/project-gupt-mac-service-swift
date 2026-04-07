//
//  PeerConnectionManager.swift
//  RemoteDesktop
//
//  Orchestrates connection establishment with signaling and fallback
//

import Foundation
import os.log

/// Delegate for connection manager events
protocol PeerConnectionManagerDelegate: AnyObject {
    func connectionManager(_ manager: PeerConnectionManager, didChangeState state: ConnectionState)
    func connectionManager(_ manager: PeerConnectionManager, didEstablishConnection connection: NetworkConnection)
    func connectionManager(_ manager: PeerConnectionManager, didTriggerFallback trigger: FallbackTrigger)
    func connectionManager(_ manager: PeerConnectionManager, didFailWithError error: Error)
}

/// Manages peer connection establishment with signaling and fallback
actor PeerConnectionManager {
    private let logger = Logger(subsystem: "com.remotedesktop", category: "PeerConnectionManager")

    private var signalingClient: SignalingClient?
    private var listener: NetworkListener?
    private var connection: NetworkConnection?

    private(set) var state: ConnectionState = .idle {
        didSet {
            logger.info("State changed: \(self.state.description)")
            Task {
                await notifyStateChange(state)
            }
        }
    }

    private(set) var metrics = ConnectionMetrics()
    private var startTime: Date?

    weak var delegate: PeerConnectionManagerDelegate?

    // MARK: - Host Connection

    /// Start hosting with specified mode
    func connectAsHost(mode: ConnectionMode, sessionID: String?, port: UInt16) async throws {
        guard state == .idle else {
            throw NSError(domain: "PeerConnectionManager", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Already connecting or connected"])
        }

        startTime = Date()
        metrics = ConnectionMetrics()
        metrics.mode = mode

        logger.info("Starting host mode: \(String(describing: mode))")

        // Start listener first (always needed)
        try await startListener(port: port)

        // If signaling enabled, register session
        if mode.isSignalingEnabled, let serverURL = mode.signalingURL, let sessionID = sessionID {
            do {
                try await registerWithSignaling(
                    serverURL: serverURL,
                    sessionID: sessionID,
                    port: port
                )
            } catch {
                logger.error("Signaling registration failed: \(error.localizedDescription)")

                if case .auto = mode {
                    // In auto mode, continue without signaling (already listening)
                    logger.info("Continuing in direct mode only")
                } else {
                    throw error
                }
            }
        }

        logger.info("Host ready: Direct listening on port \(port)" + (sessionID != nil ? ", Session ID: \(sessionID!)" : ""))
    }

    private func startListener(port: UInt16) async throws {
        state = .connectingToPeer(host: "0.0.0.0", port: port)

        let newListener = NetworkListener(port: port, useTLS: true)
        newListener.delegate = self

        try newListener.start()
        self.listener = newListener

        logger.info("Listener started on port \(port)")
    }

    private func registerWithSignaling(serverURL: URL, sessionID: String, port: UInt16) async throws {
        state = .connectingToSignaling

        let config = SignalingConfiguration(enabled: true, serverURL: serverURL)
        let client = SignalingClient(configuration: config)
        self.signalingClient = client

        let signalingStart = Date()

        // Connect to signaling server
        try await client.connect()

        metrics.recordSignalingConnect(Date().timeIntervalSince(signalingStart))

        // Register session
        let deviceName = Host.current().localizedName
        try await client.register(sessionID: sessionID, port: port, deviceName: deviceName)

        state = .discoveringPeer(sessionID: sessionID)

        logger.info("Registered with signaling server: session \(sessionID)")
    }

    // MARK: - Client Connection

    /// Connect as client with specified mode and target
    func connectAsClient(mode: ConnectionMode, target: ConnectionTarget) async throws -> NetworkConnection {
        guard state == .idle else {
            throw NSError(domain: "PeerConnectionManager", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Already connecting or connected"])
        }

        startTime = Date()
        metrics = ConnectionMetrics()
        metrics.mode = mode

        logger.info("Starting client connection: \(String(describing: mode))")

        switch mode {
        case .signaling(let serverURL):
            return try await connectViaSignaling(serverURL: serverURL, target: target)

        case .direct:
            return try await connectDirect(target: target)

        case .auto(let serverURL):
            return try await connectAuto(serverURL: serverURL, target: target)
        }
    }

    // MARK: - Signaling Connection

    private func connectViaSignaling(serverURL: URL, target: ConnectionTarget) async throws -> NetworkConnection {
        guard let sessionID = target.sessionID else {
            throw NSError(domain: "PeerConnectionManager", code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "Session ID required for signaling mode"])
        }

        state = .connectingToSignaling

        let config = SignalingConfiguration(enabled: true, serverURL: serverURL, timeout: 5.0)
        let client = SignalingClient(configuration: config)
        self.signalingClient = client

        let signalingStart = Date()

        do {
            // Connect to signaling server
            try await client.connect()

            metrics.recordSignalingConnect(Date().timeIntervalSince(signalingStart))

            state = .discoveringPeer(sessionID: sessionID)

            // Discover peer
            let discoveryStart = Date()
            let peerInfo = try await client.requestPeer(sessionID: sessionID)

            metrics.recordPeerDiscovery(Date().timeIntervalSince(discoveryStart))

            // Connect to peer
            return try await connectToPeer(host: peerInfo.ip, port: peerInfo.port)

        } catch {
            logger.error("Signaling connection failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Direct Connection

    private func connectDirect(target: ConnectionTarget) async throws -> NetworkConnection {
        guard let (host, port) = target.directAddress else {
            throw NSError(domain: "PeerConnectionManager", code: -3,
                         userInfo: [NSLocalizedDescriptionKey: "Host and port required for direct mode"])
        }

        return try await connectToPeer(host: host, port: port)
    }

    // MARK: - Auto Mode (Fallback Logic)

    private func connectAuto(serverURL: URL, target: ConnectionTarget) async throws -> NetworkConnection {
        // Try signaling first
        do {
            logger.info("Attempting connection via signaling...")

            return try await withTimeout(5.0) {
                try await self.connectViaSignaling(serverURL: serverURL, target: target)
            }

        } catch {
            logger.warning("Signaling failed: \(error.localizedDescription)")

            // Determine fallback trigger
            let trigger: FallbackTrigger

            if let signalingError = error as? SignalingError {
                switch signalingError {
                case .sessionNotFound(let sessionID):
                    trigger = .sessionNotFound(sessionID: sessionID)
                case .timeout:
                    trigger = .signalingServerUnreachable(timeout: 5.0)
                case .connectionFailed(let reason):
                    trigger = .signalingError(code: "connection_failed", message: reason)
                default:
                    trigger = .signalingError(code: "unknown", message: error.localizedDescription)
                }
            } else {
                trigger = .signalingServerUnreachable(timeout: 5.0)
            }

            // Notify delegate about fallback
            await notifyFallback(trigger)

            state = .fallingBackToDirect(reason: trigger.description)

            metrics.recordFallback()

            // Fallback to direct connection
            logger.info("Falling back to direct connection...")

            // In auto mode, if we only have sessionID, we need to ask user for IP
            if target.sessionID != nil {
                // Signal UI to request direct IP from user
                throw FallbackRequiresUserInputError(trigger: trigger)
            }

            // If we have direct address, use it
            return try await connectDirect(target: target)
        }
    }

    // MARK: - Peer Connection

    private func connectToPeer(host: String, port: UInt16) async throws -> NetworkConnection {
        state = .connectingToPeer(host: host, port: port)

        let connectStart = Date()

        let newConnection = await NetworkConnection(host: host, port: port, useTLS: true)
        newConnection.delegate = self
        newConnection.start()

        // Wait for connection to establish
        try await waitForConnection(newConnection, timeout: 10.0)

        metrics.recordPeerConnect(Date().timeIntervalSince(connectStart))

        if let startTime = startTime {
            metrics.recordTotal(Date().timeIntervalSince(startTime))
        }

        self.connection = newConnection
        state = .connected

        logger.info("Connected to peer: \(host):\(port)")
        logger.info("Connection metrics: \(metrics.summary)")

        await notifyConnection(newConnection)

        return newConnection
    }

    private func waitForConnection(_ connection: NetworkConnection, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if connection.isConnected {
                return
            }

            try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        }

        throw NSError(domain: "PeerConnectionManager", code: -4,
                     userInfo: [NSLocalizedDescriptionKey: "Connection timeout"])
    }

    // MARK: - Disconnection

    /// Disconnect and cleanup
    func disconnect() async {
        logger.info("Disconnecting...")

        // Disconnect signaling
        signalingClient?.disconnect()
        signalingClient = nil

        // Stop listener
        listener?.stop()
        listener = nil

        // Disconnect peer connection
        connection?.stop()
        connection = nil

        state = .idle
    }

    // MARK: - Helpers

    private func withTimeout<T>(_ timeout: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                return try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw NSError(domain: "PeerConnectionManager", code: -5,
                             userInfo: [NSLocalizedDescriptionKey: "Operation timeout"])
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func notifyStateChange(_ newState: ConnectionState) async {
        guard let delegate = delegate else { return }

        await MainActor.run {
            delegate.connectionManager(self, didChangeState: newState)
        }
    }

    private func notifyConnection(_ connection: NetworkConnection) async {
        guard let delegate = delegate else { return }

        await MainActor.run {
            delegate.connectionManager(self, didEstablishConnection: connection)
        }
    }

    private func notifyFallback(_ trigger: FallbackTrigger) async {
        guard let delegate = delegate else { return }

        await MainActor.run {
            delegate.connectionManager(self, didTriggerFallback: trigger)
        }
    }

    private func notifyError(_ error: Error) async {
        guard let delegate = delegate else { return }

        await MainActor.run {
            delegate.connectionManager(self, didFailWithError: error)
        }
    }

    // MARK: - State Access

    func getCurrentState() -> ConnectionState {
        return state
    }

    func getMetrics() -> ConnectionMetrics {
        return metrics
    }
}

// MARK: - NetworkListenerDelegate

extension PeerConnectionManager: NetworkListenerDelegate {
    nonisolated func listener(_ listener: NetworkListener, didAcceptConnection connection: NetworkConnection) {
        Task {
            await handleIncomingConnection(connection)
        }
    }

    nonisolated func listener(_ listener: NetworkListener, didEncounterError error: Error) {
        Task {
            await handleListenerError(error)
        }
    }

    nonisolated func listener(_ listener: NetworkListener, didChangeState state: NWListener.State) {
        // Optional: handle listener state changes
    }

    private func handleIncomingConnection(_ connection: NetworkConnection) async {
        logger.info("Accepted incoming connection")

        self.connection = connection
        state = .connected

        await notifyConnection(connection)
    }

    private func handleListenerError(_ error: Error) async {
        logger.error("Listener error: \(error.localizedDescription)")
        await notifyError(error)
    }
}

// MARK: - NetworkConnectionDelegate

extension PeerConnectionManager: NetworkConnectionDelegate {
    nonisolated func connection(_ connection: NetworkConnection, didChangeState connectionState: ConnectionState) {
        // Handled internally
    }

    nonisolated func connection(_ connection: NetworkConnection, didReceiveMessage message: NetworkMessage) {
        // Forward to app layer
    }

    nonisolated func connection(_ connection: NetworkConnection, didEncounterError error: Error) {
        Task {
            await handleConnectionError(error)
        }
    }

    private func handleConnectionError(_ error: Error) async {
        logger.error("Connection error: \(error.localizedDescription)")
        await notifyError(error)

        state = .failed(error: error.localizedDescription)
    }
}

// MARK: - Fallback Error

/// Error indicating fallback requires user input
struct FallbackRequiresUserInputError: Error, LocalizedError {
    let trigger: FallbackTrigger

    var errorDescription: String? {
        return "Signaling failed, direct IP required: \(trigger.description)"
    }

    var requiresUserInput: Bool {
        return true
    }
}
