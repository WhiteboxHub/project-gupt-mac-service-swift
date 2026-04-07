# Signaling Server Integration Architecture

## 🎯 Overview

Enhance the existing P2P remote desktop app to support two connection modes:
1. **Signaling Server Mode** - Discover peers via signaling server (for internet)
2. **Direct IP Mode** - Direct connection using IP:Port (LAN/fallback)

## 🏗️ Architecture Changes

### Current Architecture (Simplified)

```
┌─────────────────────────────────────────────────┐
│           Application Layer                     │
│  HostController / ClientController              │
└─────────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────────┐
│         Network Layer (Existing)                │
│  NetworkListener + NetworkConnection            │
│  Direct P2P connection via IP:Port              │
└─────────────────────────────────────────────────┘
```

### New Architecture (Enhanced)

```
┌─────────────────────────────────────────────────────────┐
│              Application Layer                          │
│  HostController / ClientController                      │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│         Connection Mode Manager (NEW)                   │
│  - Decides: Signaling or Direct                         │
│  - Handles fallback logic                               │
│  - Manages connection state                             │
└─────────────────────────────────────────────────────────┘
            ↓                              ↓
┌─────────────────────────┐   ┌──────────────────────────┐
│  Signaling Path (NEW)   │   │  Direct Path (Existing)  │
│  ┌──────────────────┐   │   │  ┌──────────────────┐   │
│  │ SignalingClient  │   │   │  │ NetworkListener  │   │
│  │ (WebSocket)      │   │   │  │ NetworkConnection│   │
│  └──────────────────┘   │   │  └──────────────────┘   │
│          ↓              │   │                          │
│  Discover Peer IP:Port  │   │   Use Known IP:Port      │
│          ↓              │   │          ↓               │
└──────────┴──────────────┘   └──────────┴───────────────┘
            ↓                              ↓
            └──────────────┬───────────────┘
                           ↓
┌─────────────────────────────────────────────────────────┐
│         P2P Connection (Existing)                       │
│  NetworkConnection establishes direct link              │
└─────────────────────────────────────────────────────────┘
```

## 📦 New Modules

### 1. SignalingClient.swift (NEW)
**Purpose**: WebSocket client for signaling server communication

**Responsibilities**:
- Connect to signaling server (ws://server:port)
- Send registration/discovery messages
- Receive peer information
- Handle disconnections and errors

**Key Methods**:
```swift
actor SignalingClient {
    func connect(to serverURL: URL) async throws
    func register(sessionID: String, port: UInt16) async throws
    func requestPeer(sessionID: String) async throws -> PeerInfo
    func disconnect()
}
```

### 2. PeerConnectionManager.swift (NEW)
**Purpose**: Orchestrate connection establishment with fallback

**Responsibilities**:
- Choose connection mode (signaling vs direct)
- Implement timeout and retry logic
- Fallback to direct IP on failure
- Manage connection state transitions

**Key Methods**:
```swift
actor PeerConnectionManager {
    func connectAsHost(mode: ConnectionMode, sessionID: String?, port: UInt16) async throws
    func connectAsClient(mode: ConnectionMode, target: ConnectionTarget) async throws -> NetworkConnection
    func handleFallback(from error: Error, to mode: ConnectionMode) async throws
}
```

### 3. SignalingProtocol.swift (NEW)
**Purpose**: Define signaling message protocol

**Message Types**:
- `RegisterMessage` - Host registers session
- `ConnectMessage` - Client requests session
- `PeerInfoMessage` - Server responds with peer details
- `ErrorMessage` - Server error response

### 4. ConnectionMode.swift (NEW)
**Purpose**: Define connection modes and targets

**Enums**:
```swift
enum ConnectionMode {
    case signaling(serverURL: URL)
    case direct
    case auto  // Try signaling, fallback to direct
}

enum ConnectionState {
    case idle
    case connectingToSignaling
    case discoveringPeer
    case connectingToPeer
    case connected
    case failed(Error)
}
```

## 🔄 Connection Flow

### Host Flow

```
┌─────────────────────────────────────────────────────────┐
│ 1. Host starts                                          │
│    - Choose mode: Auto/Signaling/Direct                 │
└─────────────────────────────────────────────────────────┘
                          ↓
         ┌────────────────┴────────────────┐
         │                                  │
    [Signaling Mode]               [Direct Mode]
         │                                  │
         ↓                                  ↓
┌──────────────────────┐          ┌──────────────────────┐
│ 2. Connect to        │          │ 2. Start listener    │
│    signaling server  │          │    on local port     │
└──────────────────────┘          └──────────────────────┘
         ↓                                  ↓
┌──────────────────────┐          ┌──────────────────────┐
│ 3. Register session  │          │ 3. Show IP + Port    │
│    - Send session ID │          │    to user           │
│    - Send port       │          └──────────────────────┘
└──────────────────────┘                   ↓
         ↓                          ┌──────────────────────┐
┌──────────────────────┐            │ 4. Wait for client   │
│ 4. Show session ID   │            └──────────────────────┘
│    to user           │
└──────────────────────┘
         ↓
┌──────────────────────┐
│ 5. Start listener    │
│    on local port     │
└──────────────────────┘
         ↓
┌──────────────────────┐
│ 6. Wait for client   │
│    connection        │
└──────────────────────┘
```

### Client Flow

```
┌─────────────────────────────────────────────────────────┐
│ 1. Client starts                                        │
│    - Input: Session ID OR IP:Port                       │
│    - Choose mode: Auto/Signaling/Direct                 │
└─────────────────────────────────────────────────────────┘
                          ↓
         ┌────────────────┴────────────────┐
         │                                  │
    [Signaling Mode]               [Direct Mode]
         │                                  │
         ↓                                  ↓
┌──────────────────────┐          ┌──────────────────────┐
│ 2. Connect to        │          │ 2. Connect to        │
│    signaling server  │          │    IP:Port directly  │
└──────────────────────┘          └──────────────────────┘
         ↓                                  ↓
┌──────────────────────┐          ┌──────────────────────┐
│ 3. Request peer info │          │ 3. Establish P2P     │
│    - Send session ID │          │    connection        │
└──────────────────────┘          └──────────────────────┘
         ↓                                  ↓
┌──────────────────────┐                SUCCESS
│ 4. Receive peer info │
│    - IP, Port        │
└──────────────────────┘
         ↓
┌──────────────────────┐
│ 5. Connect to peer   │
│    using IP:Port     │
└──────────────────────┘
         ↓
    ┌─────────┐
    │ SUCCESS?│
    └────┬────┘
         │
    ┌────┴────┐
    │   NO    │ [TIMEOUT/ERROR]
    └────┬────┘
         ↓
┌──────────────────────┐
│ 6. FALLBACK:         │
│    Ask for direct IP │
│    Connect directly  │
└──────────────────────┘
```

## 🛡️ Fallback Logic

### Automatic Fallback Triggers

```swift
enum FallbackTrigger {
    case signalingServerUnreachable(timeout: TimeInterval)
    case sessionNotFound(sessionID: String)
    case peerUnreachable(ip: String, port: UInt16)
    case connectionTimeout
    case tlsHandshakeFailure
}
```

### Fallback Implementation

```
Try Signaling Mode (Timeout: 5 seconds)
    ↓
┌───────────────────┐
│ Signaling Success?│
└─────┬──────┬──────┘
      │      │
     YES     NO
      │      │
      ↓      ↓
  CONNECT  ┌─────────────────────────┐
           │ Show fallback dialog:   │
           │ "Enter IP:Port to       │
           │  connect directly"      │
           └───────────┬─────────────┘
                       ↓
                 [User enters IP]
                       ↓
               Try Direct Connection
                       ↓
                ┌──────────┐
                │ Success? │
                └─────┬────┘
                      │
                 ┌────┴────┐
                YES       NO
                 │         │
              CONNECT   FAIL
```

## 📡 Signaling Protocol

### Message Format (JSON)

#### 1. Register (Host → Server)
```json
{
  "type": "register",
  "session_id": "abc123",
  "port": 5900,
  "timestamp": 1234567890
}
```

**Server Response:**
```json
{
  "type": "registered",
  "session_id": "abc123",
  "expires_in": 3600
}
```

#### 2. Connect (Client → Server)
```json
{
  "type": "connect",
  "session_id": "abc123",
  "timestamp": 1234567890
}
```

**Server Response (Success):**
```json
{
  "type": "peer_info",
  "session_id": "abc123",
  "peer": {
    "ip": "203.0.113.1",
    "port": 5900,
    "public_key": "optional"
  }
}
```

**Server Response (Error):**
```json
{
  "type": "error",
  "code": "session_not_found",
  "message": "Session ID not found or expired"
}
```

#### 3. Heartbeat (Both → Server)
```json
{
  "type": "heartbeat",
  "timestamp": 1234567890
}
```

## 🔧 Integration Points

### Minimal Changes to Existing Code

#### 1. HostController (Extend, don't replace)
```swift
// BEFORE
class HostController {
    func startHosting(port: UInt16) async throws {
        listener = NetworkListener(port: port)
        try listener.start()
    }
}

// AFTER
class HostController {
    private let connectionManager = PeerConnectionManager()

    func startHosting(mode: ConnectionMode, sessionID: String?, port: UInt16) async throws {
        try await connectionManager.connectAsHost(
            mode: mode,
            sessionID: sessionID,
            port: port
        )
    }
}
```

#### 2. ClientController (Extend)
```swift
// BEFORE
class ClientController {
    func connect(host: String, port: UInt16) async throws {
        connection = await NetworkConnection(host: host, port: port)
        connection.start()
    }
}

// AFTER
class ClientController {
    private let connectionManager = PeerConnectionManager()

    func connect(mode: ConnectionMode, target: ConnectionTarget) async throws {
        let connection = try await connectionManager.connectAsClient(
            mode: mode,
            target: target
        )
        self.connection = connection
        connection.start()
    }
}
```

## ⚙️ Configuration

### New Settings

```swift
struct SignalingConfiguration: Codable {
    var enabled: Bool = true
    var serverURL: URL = URL(string: "ws://signal.example.com:8080")!
    var timeout: TimeInterval = 5.0
    var autoFallback: Bool = true
    var sessionIDLength: Int = 8
}

struct ConnectionConfiguration: Codable {
    var preferredMode: ConnectionMode = .auto
    var signalingConfig: SignalingConfiguration
    var directConfig: DirectConnectionConfiguration
}
```

## 📊 State Management

### Connection State Machine

```
        ┌──────┐
        │ IDLE │
        └───┬──┘
            │ start()
            ↓
┌────────────────────────┐
│ CONNECTING_TO_SIGNALING│
└───┬───────────────┬────┘
    │ success       │ timeout/error
    ↓               ↓
┌─────────────┐  ┌──────────────┐
│DISCOVERING  │  │ FALLBACK_TO  │
│   PEER      │  │   DIRECT     │
└───┬─────────┘  └──────┬───────┘
    │ peer found        │
    ↓                   ↓
┌────────────────────────┐
│   CONNECTING_TO_PEER   │
└───┬───────────────┬────┘
    │ success       │ fail
    ↓               ↓
┌──────────┐    ┌────────┐
│CONNECTED │    │ FAILED │
└──────────┘    └────────┘
```

## 🧪 Testing Strategy

### Unit Tests
1. SignalingClient connection/disconnection
2. Message serialization/deserialization
3. Timeout handling
4. Fallback logic

### Integration Tests
1. End-to-end signaling flow
2. Direct connection fallback
3. Network failure scenarios
4. Session expiration

### Manual Tests
1. Connect via signaling server
2. Disconnect signaling → test fallback
3. Invalid session ID → test error handling
4. Behind NAT scenarios

## 📈 Performance Considerations

### Latency Impact
- Signaling discovery: +500ms - 2s (one-time)
- After discovery: Same P2P performance
- Keep existing low-latency optimizations

### Resource Usage
- One WebSocket connection (minimal overhead)
- Automatic reconnection with backoff
- Clean disconnect on app termination

## 🔐 Security

### Existing Security (Maintained)
- TLS for P2P connections
- Password authentication
- Session tokens

### New Security Considerations
- WSS (WebSocket Secure) for signaling
- Session ID validation
- Expiration times for sessions
- Rate limiting for discovery requests

## 📝 Implementation Phases

### Phase 1: Core Signaling Client (1-2 hours)
- SignalingClient.swift
- SignalingProtocol.swift
- Basic WebSocket communication

### Phase 2: Connection Manager (1-2 hours)
- PeerConnectionManager.swift
- ConnectionMode.swift
- State machine

### Phase 3: Integration (1 hour)
- Update HostController
- Update ClientController
- Wire up signaling flow

### Phase 4: Fallback Logic (1 hour)
- Timeout implementation
- Error handling
- User prompts

### Phase 5: UI Updates (1 hour)
- Session ID input/display
- Mode selection
- Status indicators

### Phase 6: Testing & Polish (1-2 hours)
- Unit tests
- Integration tests
- Error message refinement

**Total Estimated Time**: 6-9 hours

## 🎯 Success Criteria

- ✅ Host can register session via signaling
- ✅ Client can discover peer via session ID
- ✅ Automatic fallback to direct IP works
- ✅ Connection timeout <5 seconds
- ✅ Minimal changes to existing code
- ✅ Clean error messages
- ✅ Existing direct IP mode still works

## 🚀 Next Steps

1. Review and approve architecture
2. Implement SignalingClient
3. Implement PeerConnectionManager
4. Update controllers
5. Update UI
6. Test and iterate
