# Signaling Server Specification

## 🎯 Overview

This document specifies the signaling server that the macOS remote desktop app connects to for peer discovery.

## 🏗️ Architecture

```
┌──────────────┐         WebSocket          ┌──────────────┐
│   Host App   │◄─────────────────────────►│              │
└──────────────┘                            │  Signaling   │
                                            │   Server     │
┌──────────────┐         WebSocket          │              │
│  Client App  │◄─────────────────────────►│              │
└──────────────┘                            └──────────────┘

Flow:
1. Host connects → registers session
2. Client connects → requests session
3. Server responds with host's IP:Port
4. Client connects directly to host
5. Server is no longer needed
```

## 📡 Protocol

### Transport
- **WebSocket** (ws:// or wss://)
- **Port**: 8080 (configurable)
- **Format**: JSON messages

### Message Structure

All messages follow this pattern:
```json
{
  "type": "message_type",
  "timestamp": 1234567890,
  ...additional fields
}
```

## 📨 Messages

### 1. Register (Host → Server)

Host registers a new session.

**Request**:
```json
{
  "type": "register",
  "session_id": "ABC12345",
  "port": 5900,
  "device_name": "John's MacBook",
  "timestamp": 1234567890000000
}
```

**Response (Success)**:
```json
{
  "type": "registered",
  "session_id": "ABC12345",
  "expires_in": 3600,
  "timestamp": 1234567890000000
}
```

**Response (Error - Session Exists)**:
```json
{
  "type": "error",
  "code": "session_already_exists",
  "message": "Session ID already registered",
  "timestamp": 1234567890000000
}
```

### 2. Connect (Client → Server)

Client requests peer information for a session.

**Request**:
```json
{
  "type": "connect",
  "session_id": "ABC12345",
  "client_name": "Alice's MacBook",
  "timestamp": 1234567890000000
}
```

**Response (Success)**:
```json
{
  "type": "peer_info",
  "session_id": "ABC12345",
  "peer": {
    "ip": "203.0.113.1",
    "port": 5900,
    "public_key": null
  },
  "timestamp": 1234567890000000
}
```

**Response (Error - Not Found)**:
```json
{
  "type": "error",
  "code": "session_not_found",
  "message": "Session ID not found or expired",
  "timestamp": 1234567890000000
}
```

### 3. Heartbeat (Both → Server)

Keep connection alive.

**Request**:
```json
{
  "type": "heartbeat",
  "timestamp": 1234567890000000
}
```

**Response**:
```json
{
  "type": "heartbeat_ack",
  "timestamp": 1234567890000000
}
```

### 4. Unregister (Host → Server)

Host explicitly unregisters session.

**Request**:
```json
{
  "type": "unregister",
  "session_id": "ABC12345",
  "timestamp": 1234567890000000
}
```

**Response**:
```json
{
  "type": "unregistered",
  "session_id": "ABC12345",
  "timestamp": 1234567890000000
}
```

## 🔧 Server Implementation Requirements

### Core Functionality

1. **Session Storage**
   - Store: session_id → {ip, port, device_name, created_at}
   - In-memory or Redis for production
   - Expire sessions after 1 hour (configurable)

2. **IP Detection**
   - Extract client's public IP from WebSocket connection
   - Store as peer IP for session

3. **Connection Management**
   - Track active WebSocket connections
   - Clean up on disconnect
   - Auto-unregister sessions on disconnect

4. **Validation**
   - Session ID format: 6-12 alphanumeric characters
   - Port range: 1024-65535
   - Rate limiting: max 10 requests/minute per IP

### Data Structures

```javascript
// Session storage
sessions = {
  "ABC12345": {
    ip: "203.0.113.1",
    port: 5900,
    device_name: "John's MacBook",
    created_at: 1234567890,
    expires_at: 1234571490,
    connection_id: "ws-conn-123"
  }
}

// Active connections
connections = {
  "ws-conn-123": {
    socket: WebSocket,
    ip: "203.0.113.1",
    connected_at: 1234567890,
    session_ids: ["ABC12345"]
  }
}
```

### Error Codes

| Code | Description | HTTP Status Equivalent |
|------|-------------|------------------------|
| session_not_found | Session ID doesn't exist | 404 |
| session_already_exists | Session ID in use | 409 |
| session_expired | Session has expired | 410 |
| invalid_message | Malformed JSON or missing fields | 400 |
| server_error | Internal server error | 500 |
| unauthorized | Authentication failed (future) | 401 |
| rate_limit_exceeded | Too many requests | 429 |

## 🔐 Security

### Basic Security (MVP)
- ✅ Random session IDs (hard to guess)
- ✅ Session expiration
- ✅ Rate limiting
- ⚠️ No authentication (session ID is the secret)

### Enhanced Security (Recommended)
- 🔒 Use WSS (TLS/SSL)
- 🔒 Add session passwords
- 🔒 IP whitelisting (optional)
- 🔒 Audit logging

## 📊 Performance Requirements

- **Latency**: <100ms for peer discovery
- **Throughput**: 1000 sessions/server
- **Concurrency**: 500 concurrent WebSocket connections
- **Memory**: ~1KB per session

## 🐳 Reference Implementation (Node.js)

Here's a minimal signaling server:

```javascript
// signaling-server.js
const WebSocket = require('ws');
const crypto = require('crypto');

const PORT = 8080;
const SESSION_EXPIRY = 3600 * 1000; // 1 hour

const sessions = new Map();
const connections = new Map();

const wss = new WebSocket.Server({ port: PORT });

console.log(`Signaling server running on ws://localhost:${PORT}`);

wss.on('connection', (ws, req) => {
  const clientIP = req.socket.remoteAddress;
  const connID = crypto.randomUUID();

  connections.set(connID, { ws, ip: clientIP, sessions: [] });

  console.log(`Client connected: ${clientIP} (${connID})`);

  ws.on('message', (data) => {
    try {
      const msg = JSON.parse(data);
      handleMessage(ws, connID, clientIP, msg);
    } catch (error) {
      sendError(ws, 'invalid_message', 'Malformed JSON');
    }
  });

  ws.on('close', () => {
    console.log(`Client disconnected: ${connID}`);
    cleanupConnection(connID);
    connections.delete(connID);
  });

  ws.on('error', (error) => {
    console.error(`WebSocket error: ${error.message}`);
  });
});

function handleMessage(ws, connID, clientIP, msg) {
  const timestamp = Date.now() * 1000; // microseconds

  switch (msg.type) {
    case 'register':
      handleRegister(ws, connID, clientIP, msg, timestamp);
      break;

    case 'connect':
      handleConnect(ws, msg, timestamp);
      break;

    case 'heartbeat':
      send(ws, { type: 'heartbeat_ack', timestamp });
      break;

    case 'unregister':
      handleUnregister(ws, msg, timestamp);
      break;

    default:
      sendError(ws, 'invalid_message', `Unknown message type: ${msg.type}`);
  }
}

function handleRegister(ws, connID, clientIP, msg, timestamp) {
  const { session_id, port, device_name } = msg;

  // Validate
  if (!session_id || !port) {
    sendError(ws, 'invalid_message', 'Missing session_id or port');
    return;
  }

  if (sessions.has(session_id)) {
    sendError(ws, 'session_already_exists', 'Session ID already in use');
    return;
  }

  // Store session
  sessions.set(session_id, {
    ip: clientIP,
    port,
    device_name,
    created_at: Date.now(),
    expires_at: Date.now() + SESSION_EXPIRY,
    connection_id: connID
  });

  // Track in connection
  const conn = connections.get(connID);
  conn.sessions.push(session_id);

  console.log(`Registered session: ${session_id} from ${clientIP}:${port}`);

  send(ws, {
    type: 'registered',
    session_id,
    expires_in: SESSION_EXPIRY / 1000,
    timestamp
  });

  // Auto-expire
  setTimeout(() => {
    if (sessions.has(session_id)) {
      console.log(`Session expired: ${session_id}`);
      sessions.delete(session_id);
    }
  }, SESSION_EXPIRY);
}

function handleConnect(ws, msg, timestamp) {
  const { session_id } = msg;

  if (!session_id) {
    sendError(ws, 'invalid_message', 'Missing session_id');
    return;
  }

  const session = sessions.get(session_id);

  if (!session) {
    sendError(ws, 'session_not_found', 'Session not found or expired');
    return;
  }

  // Check expiration
  if (Date.now() > session.expires_at) {
    sessions.delete(session_id);
    sendError(ws, 'session_expired', 'Session has expired');
    return;
  }

  console.log(`Client requesting session: ${session_id}`);

  send(ws, {
    type: 'peer_info',
    session_id,
    peer: {
      ip: session.ip,
      port: session.port,
      public_key: null
    },
    timestamp
  });
}

function handleUnregister(ws, msg, timestamp) {
  const { session_id } = msg;

  if (sessions.has(session_id)) {
    sessions.delete(session_id);
    console.log(`Unregistered session: ${session_id}`);
  }

  send(ws, {
    type: 'unregistered',
    session_id,
    timestamp
  });
}

function cleanupConnection(connID) {
  const conn = connections.get(connID);
  if (!conn) return;

  // Remove all sessions for this connection
  for (const sessionID of conn.sessions) {
    sessions.delete(sessionID);
    console.log(`Cleaned up session: ${sessionID}`);
  }
}

function send(ws, message) {
  ws.send(JSON.stringify(message));
}

function sendError(ws, code, message) {
  send(ws, {
    type: 'error',
    code,
    message,
    timestamp: Date.now() * 1000
  });
}

// Cleanup expired sessions every 5 minutes
setInterval(() => {
  const now = Date.now();
  let cleaned = 0;

  for (const [sessionID, session] of sessions.entries()) {
    if (now > session.expires_at) {
      sessions.delete(sessionID);
      cleaned++;
    }
  }

  if (cleaned > 0) {
    console.log(`Cleaned up ${cleaned} expired sessions`);
  }
}, 5 * 60 * 1000);
```

### Usage

1. **Install dependencies**:
   ```bash
   npm install ws
   ```

2. **Run server**:
   ```bash
   node signaling-server.js
   ```

3. **Test**:
   ```bash
   # Using wscat
   wscat -c ws://localhost:8080

   # Register
   > {"type":"register","session_id":"TEST123","port":5900,"timestamp":1234567890}

   # Connect (in another terminal)
   > {"type":"connect","session_id":"TEST123","timestamp":1234567890}
   ```

## 🚀 Production Deployment

### Docker

```dockerfile
FROM node:18-alpine

WORKDIR /app

COPY package*.json ./
RUN npm ci --only=production

COPY signaling-server.js .

EXPOSE 8080

CMD ["node", "signaling-server.js"]
```

### Environment Variables

```bash
PORT=8080
SESSION_EXPIRY_MS=3600000
LOG_LEVEL=info
```

### Monitoring

- Track active sessions count
- Monitor WebSocket connection count
- Log error rates
- Alert on high memory usage

## 📝 Testing

### Unit Tests

```javascript
// Test session registration
// Test peer discovery
// Test expiration
// Test cleanup
```

### Integration Tests

```bash
# Test with real WebSocket clients
# Test concurrent connections
# Test edge cases (invalid session, expired, etc.)
```

### Load Tests

```bash
# Artillery or k6
# Test 1000 concurrent connections
# Test session throughput
```

## 🎯 Success Criteria

- ✅ Hosts can register sessions
- ✅ Clients can discover peers
- ✅ Sessions expire correctly
- ✅ Handles disconnections gracefully
- ✅ Responds within 100ms
- ✅ Supports 500+ concurrent connections

---

**Implementation Time**: 2-3 hours for basic server

**Technology**: Any (Node.js, Python, Go, Rust)

**Deployment**: Docker, AWS, Heroku, DigitalOcean
