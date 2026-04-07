# Quick Start - Signaling Integration

## 🚀 5-Minute Integration

### Step 1: Add Files (1 minute)

In Xcode, add these 4 files to your Networking group:
```
RemoteDesktop/RemoteDesktop/Networking/
├── SignalingProtocol.swift
├── ConnectionMode.swift
├── SignalingClient.swift
└── PeerConnectionManager.swift
```

### Step 2: Minimal Host Code (2 minutes)

Replace your current host code with:

```swift
class HostController {
    private let connectionManager = PeerConnectionManager()

    func startHosting() async throws {
        // Generate session ID
        let sessionID = SessionIDGenerator.generate()

        // Start hosting with auto mode (signaling + fallback)
        try await connectionManager.connectAsHost(
            mode: .auto(signalingURL: URL(string: "ws://localhost:8080")!),
            sessionID: sessionID,
            port: 5900
        )

        print("🎉 Session ID: \(sessionID)")
        print("📡 Waiting for client...")
    }
}
```

### Step 3: Minimal Client Code (2 minutes)

Replace your current client code with:

```swift
class ClientController {
    private let connectionManager = PeerConnectionManager()

    func connect(sessionID: String) async throws {
        // Connect using session ID (auto mode with fallback)
        let connection = try await connectionManager.connectAsClient(
            mode: .auto(signalingURL: URL(string: "ws://localhost:8080")!),
            target: .sessionID(sessionID)
        )

        print("🎉 Connected to peer!")
        // Use connection for video streaming...
    }
}
```

### Step 4: Run Signaling Server (1 minute)

Copy this into `signaling-server.js`:

```javascript
const WebSocket = require('ws');
const wss = new WebSocket.Server({ port: 8080 });

const sessions = new Map();

wss.on('connection', (ws, req) => {
  const clientIP = req.socket.remoteAddress;

  ws.on('message', (data) => {
    const msg = JSON.parse(data);

    if (msg.type === 'register') {
      sessions.set(msg.session_id, {
        ip: clientIP,
        port: msg.port
      });
      ws.send(JSON.stringify({
        type: 'registered',
        session_id: msg.session_id,
        expires_in: 3600,
        timestamp: Date.now() * 1000
      }));
    }

    if (msg.type === 'connect') {
      const session = sessions.get(msg.session_id);
      if (session) {
        ws.send(JSON.stringify({
          type: 'peer_info',
          session_id: msg.session_id,
          peer: {
            ip: session.ip,
            port: session.port
          },
          timestamp: Date.now() * 1000
        }));
      } else {
        ws.send(JSON.stringify({
          type: 'error',
          code: 'session_not_found',
          message: 'Session not found',
          timestamp: Date.now() * 1000
        }));
      }
    }
  });
});

console.log('Signaling server running on ws://localhost:8080');
```

Run it:
```bash
npm install ws
node signaling-server.js
```

## ✅ Test It

**Terminal 1 (Host)**:
```swift
// Run your app
// Start hosting
// Note session ID (e.g., "ABC12345")
```

**Terminal 2 (Client)**:
```swift
// Run your app
// Enter session ID: "ABC12345"
// Connect
```

**Result**: Connected! 🎉

## 🔄 Fallback Test

Stop signaling server, try connecting with client → will prompt for direct IP!

## 📚 For Full Details

- **Architecture**: See `SIGNALING_ARCHITECTURE.md`
- **Integration Guide**: See `SIGNALING_INTEGRATION.md`
- **Server Spec**: See `SIGNALING_SERVER_SPEC.md`
- **Summary**: See `SIGNALING_SUMMARY.md`

---

**That's it!** You now have signaling + automatic fallback in ~5 minutes! 🚀
