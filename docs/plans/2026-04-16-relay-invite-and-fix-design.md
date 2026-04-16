# Relay Auto-Invite System + Connection Fix Design

**Date:** 2026-04-16
**Status:** Approved

## Problem

1. **Relay connections fail**: Joiner's WebSocket upgrade gets HTTP error (-1011) due to token/KV issues
2. **Poor UX**: Creator must share room code manually; Joiner must enter it manually
3. **No background notification**: No way to notify Joiner when Creator wants to connect

## Solution

WebSocket real-time inbox (foreground) + APNs push (background) for relay invitations, plus relay connection reliability fixes.

## Architecture

```
Creator                    Worker (CF)                  Joiner
  │                          │                            │
  ├─ Select device ──────────│                            │
  ├─ POST /room ────────────►│                            │
  │◄── roomCode+roomToken ───┤                            │
  ├─ POST /v2/invite/:id ──►│── WS push (foreground) ───►│
  │                          │── APNs push (background) ─►│
  ├─ WSS /room/:code ──────►│                            │
  │                          │                     Accept │
  │                          │◄── WSS /room/:code ───────┤
  │◄══════ WebRTC P2P ══════►│◄══════════════════════════►│
```

## New Worker Endpoints

### POST /v2/device/register
Register APNs device token for push notifications.
```json
Request:  { "deviceId": "abc123", "pushToken": "apns-hex-token", "platform": "ios" }
Response: { "ok": true }
```
Storage: `V2_STORE` key `device:{deviceId}` with 30-day TTL.

### GET /v2/inbox/:deviceId — WebSocket upgrade
Real-time inbox for receiving invitations. Uses Durable Object `DeviceInbox` per device.
- App foreground: opens WebSocket, receives invites instantly
- App background: WS is closed, invites go via APNs

### POST /v2/invite/:deviceId
Send a relay invitation to a target device.
```json
Request:  { "roomCode": "S63TW7", "roomToken": "hex-token", "senderName": "iPhone A", "senderId": "device-id-of-creator" }
Response: { "ok": true, "delivered": "websocket" | "apns" | "queued" }
```
Logic: WS connected → push via WS; else → send APNs + queue in KV.

### APNs Integration (Worker-side)
- Store APNs Auth Key (p8) as Worker secret `APNS_KEY_P8`
- Store Key ID as `APNS_KEY_ID`, Team ID as `APNS_TEAM_ID`
- Generate JWT, call APNs HTTP/2 API (`api.push.apple.com`)
- Push payload: `{ "aps": { "alert": { "title": "PeerDrop", "body": "XXX wants to connect" }, "sound": "default" }, "roomCode": "...", "roomToken": "...", "senderId": "..." }`

## New iOS Components

### InboxService
- Manages WebSocket connection to `/v2/inbox/:deviceId`
- Connects on `sceneDidBecomeActive`, disconnects on `sceneWillResignActive`
- Publishes `RelayInvite` via Combine when invite arrives
- Heartbeat ping every 30 seconds to keep connection alive

### PushNotificationManager
- Registers for remote notifications on app launch
- Sends device token to `POST /v2/device/register`
- Handles incoming push payload → triggers invite UI

### UI: Invite Banner (Joiner side)
- Top banner slides in: "{SenderName} wants to connect"
- "Accept" / "Decline" buttons
- Accept → auto-join room with roomCode + roomToken from invite
- Banner auto-dismisses after 30 seconds (room may expire)

### UI: Device Picker (Creator side)
- New view shown when Creator taps "Invite Device" in RelayConnectView
- Lists known devices from DeviceRecordStore
- Shows online indicator (green dot) for devices with active inbox WS
- Select device → create room → send invite → show "Waiting for response..."

### Device ID Exchange
- On first successful relay connection, both sides exchange `deviceId` via DataChannel
- Stored in DeviceRecordStore for future invitations
- `deviceId` is a stable UUID generated once per app install

## Relay Connection Fixes

### Worker-side
1. **Diagnostic logging**: Log WebSocket validation failures to KV (`wslog:{timestamp}`)
2. **Increase TTL**: `ROOM_TTL_SECONDS` 300 → 600
3. **Token tolerance**: If token validation fails, log details but still allow connection (temporary, for diagnosis)

### iOS-side
1. **WebSocket retry**: On -1011 failure, retry up to 2 times with 1-second delay
2. **Room token in invite**: Invite carries roomToken directly, so Joiner skips separate ICE→token fetch race condition
3. **Pre-flight check**: Before WebSocket, do HTTP GET to verify room exists and token is valid
4. **Enhanced error reporting**: Capture HTTP status code from WebSocket failure if available

## Data Flow: Device Registration

```
App Launch
  ├─ Generate or load deviceId (UUID, stored in UserDefaults)
  ├─ Request push notification permission
  ├─ Receive APNs device token
  ├─ POST /v2/device/register { deviceId, pushToken }
  └─ Connect WS to /v2/inbox/:deviceId
```

## Privacy Considerations

- Device tokens are stored server-side (required for APNs) with 30-day TTL
- Invite messages contain only room code, sender name, and device ID — no content
- No persistent logging of invite relationships
- Room tokens are ephemeral (10-minute TTL)
