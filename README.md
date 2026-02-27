# Svoyak MVP (Flutter + Node.js)

Monorepo scaffold for a multiplayer trivia game inspired by "Своя игра".

## Structure

- `backend`: Node.js/TypeScript real-time server (Socket.io + PostgreSQL + Redis)
- `mobile`: Flutter client MVP
- `infra`: local dev infrastructure (Postgres + Redis)

## Quick start

### 1) Start infrastructure

```bash
cd infra
docker compose up -d
```

### 2) Initialize database

```bash
psql postgres://postgres:postgres@localhost:5432/svoyak -f backend/migrations/001_init.sql
psql postgres://postgres:postgres@localhost:5432/svoyak -f backend/migrations/002_seed_demo.sql
```

Demo package UUID:

```text
22222222-2222-2222-2222-222222222222
```

Demo question UUIDs:

```text
33333333-3333-3333-3333-333333333333
44444444-4444-4444-4444-444444444444
```

### 3) Run backend

```bash
cd backend
cp .env.example .env
npm install
npm run dev
```

Health check:

```bash
curl http://localhost:3000/health
```

### 4) Run Flutter client

```bash
cd mobile
flutter pub get
flutter run --dart-define=BACKEND_URL=http://localhost:3000
```

## Implemented MVP scaffolding

- Room create/join/leave with reconnect token
- Host migration on disconnect
- Real-time room state sync
- Question open/close flow
- Latency-compensated buzzer (`effectivePressMs`)
- Fuzzy answer checking (Levenshtein)
- PostgreSQL schema + Redis room state model

## Timeweb Staging (Backend + Postgres + Redis)

1. In Timeweb Cloud create:
   - App Platform app from this repository
   - PostgreSQL database
   - Redis instance
2. For App Platform choose Dockerfile deployment.
   - This repo already has root `Dockerfile` tuned for `backend/`.
   - Container start command already runs migrations automatically (`npm run start:with-migrate`).
3. Set backend environment variables:
   - `NODE_ENV=production`
   - `PG_CONNECTION_STRING=<timeweb_postgres_connection_string>`
   - `PG_SSL_REJECT_UNAUTHORIZED=false` (for self-signed certificate chain errors)
   - `REDIS_URL=<timeweb_redis_url>`
   - Optional for staging demo data: `MIGRATE_WITH_SEED=true`
4. Attach domain and HTTPS to backend app.
5. Verify health:
   - `GET https://<your-backend-domain>/health`

Important:
- Keep `MIGRATE_WITH_SEED=true` only for initial staging seed, then set it back to `false`.
- Backend already reads `PORT` from env, so it is compatible with App Platform runtime port injection.
- For this MVP run a single backend replica (`instances = 1`) because Socket.io cross-node adapter is not configured yet.

Flutter launch against Timeweb backend:

```bash
cd mobile
flutter run -d <SIMULATOR_OR_DEVICE_ID> --dart-define=BACKEND_URL=https://<your-backend-domain>
```

## Next

- Add auth/session layer
- Add package import/editor pipeline
- Add integration tests for buzzer race conditions
- Add audio channel integration (LiveKit/Agora)
