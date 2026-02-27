# WebSocket Event Dictionary (MVP)

## Client -> Server

- `create_room`: `{ packageId, displayName, visibility?, settings? }`
- `list_public_rooms`: `{ limit? }` -> ack data: `{ rooms: PublicRoomSummary[] }`
- `join_room`: `{ roomCode, displayName, reconnectToken? }`
- `leave_room`: `{ roomCode }`
- `sync_time`: `{ sampleId, t0ClientMs }`
- `start_game`: `{ roomCode }`
- `select_question`: `{ roomCode, questionId }`
- `buzz_attempt`: `{ roomCode, questionId, pressClientMs, offsetMs, rttMs, sampleId }`
- `answer_submitted`: `{ roomCode, questionId, answerText, submittedClientMs }`
- `heartbeat`: `{ roomCode, clientNowMs }`

All events use ack envelope:

```json
{ "ok": true, "data": {} }
```

or

```json
{ "ok": false, "error": { "code": "...", "message": "..." } }
```

## Server -> Client

- `room_joined`
- `room_state`
- `time_sync`
- `question_opened`
- `buzz_locked`
- `buzz_rejected`
- `answer_result`
- `question_closed`
- `host_migrated`
- `player_presence`
- `error`
