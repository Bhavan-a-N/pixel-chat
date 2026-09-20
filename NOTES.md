# Notes

## Backend Authentication (Completed)
- Custom `User` model with UUIDv4 primary keys and case-insensitive email/username constraints.
- SimpleJWT with 15-minute access token lifespan and rotating blacklisted refresh tokens.
- Structured error envelopes (`{"error": {"code": ..., "message": ..., "details": ...}}`).
- Throttling on login, register, and user search.
- CI workflow in `.github/workflows/backend.yml`.

## Flutter Client Authentication (Completed)
- Flutter Android app bootstrapped in `app/` with pinned dependency versions.
- Clean feature-first architecture: `features/auth`, `features/home`, and `core/` (`config`, `network`, `router`, `storage`, `theme`).
- Design system: centralized tokens for colors, spacing, radii, and typography in `core/theme/app_theme.dart`. No hardcoded values in widgets.
- Network & Interceptor:
  - Dio configured with `AuthInterceptor`.
  - Single-flight token refresh: concurrent 401s coalesce into a single refresh request.
  - Separate `refreshDio` instance with zero interceptors.
  - Divergent token check: if request token already differs from current stored token, retries with current token directly.
  - Refresh rotation: newly rotated refresh token is saved on every refresh.
  - Safe failure boundaries: logs out only on explicit 400/401 from refresh endpoint; network timeouts and connectivity errors do not log out.
  - Decoupled session expiration callback.
- Storage: `flutter_secure_storage` abstraction (`TokenStorage`).
- State Management & Routing:
  - Riverpod 3 `Notifier` (`AuthNotifier`) tracking `AuthState` (`unknown`, `authenticated`, `unauthenticated`, `networkError`).
  - GoRouter declarative redirects based on `AuthState` without login screen flicker on app launch.
  - Splash screen gracefully displays a retry state on cold starts or network failures.
- Testing & CI:
  - 17 Flutter unit and widget tests covering the single-flight refresh interceptor, login validation/errors, and signup validation/errors.
  - CI workflow in `.github/workflows/flutter.yml` pinned to Flutter 3.38.1 running `flutter analyze` and `flutter test`.
- ADRs:
  - ADR 0013: State Management and Routing (Riverpod & GoRouter)
  - ADR 0014: Single-Flight Token Refresh Strategy

## Chat Backend (`apps/chat`) (Completed)
- Infrastructure:
  - Docker Compose updated with `redis:7-alpine` service on `127.0.0.1:6379`.
  - Daphne ASGI runner and Django Channels with `channels-redis` channel layer.
  - CI workflow `.github/workflows/backend.yml` updated with Postgres & Redis service containers.
- Data Models:
  - `Conversation`: UUIDv4, `type` (`dm`/`group`), `next_seq` counter, `dm_key` with unique constraint preventing duplicate 1:1 conversation races.
  - `Membership`: UUIDv4, `conversation`, `user`, `role`, `last_delivered_seq`, `last_read_seq`. Unique `(conversation, user)`.
  - `Message`: UUIDv4, `conversation`, `sender`, `seq`, `body` (stripped, max 4000 chars), `client_id`, `created_at`. Unique `(conversation, seq)` and unique `(sender, client_id)`.
- Atomic Send Service (`send_message`):
  - Row-level lock (`SELECT FOR UPDATE`) on parent `Conversation` guarantees monotonic gapless sequence numbering under concurrent sends.
  - Idempotent: duplicate `(sender, client_id)` returns existing message without consuming sequence number or re-broadcasting.
  - Rejects duplicate `client_id` used across different conversations.
  - Updates `conversation.updated_at` on every message.
  - Post-commit broadcast via `transaction.on_commit` fanout to `user_{id}` Channels group for all members.
  - Resilient: failing channel layer post-commit is caught and logged, sender still receives ack, consumer does not crash.
- REST API:
  - `POST /api/conversations/dm`: Idempotent find-or-create DM. Prevents self-DMs (400) and unknown users (404).
  - `GET /api/conversations`: Lists conversations with other participant, last message, last sequence number. Optimized with `prefetch_related` to eliminate per-row N+1 queries.
  - `GET /api/conversations/{id}/messages`: History pagination (`before_seq`, newest-first) and catch-up pagination (`after_seq`, oldest-first). Non-members get 404.
- WebSocket Protocol (`/ws/chat/`):
  - Handshake JWT validation from HTTP headers. Unauthenticated/expired connections accepted and immediately closed with close code `4401`.
  - Versioned JSON envelope: `{v: 1, type, client_id, payload}`.
  - Frame size validation (max 64KB), JSON decoding error recovery, envelope validation, and per-connection rate limiting (20 sends / 10s).
  - New conversations created after connect deliver messages immediately without reconnecting.
- ADRs:
  - ADR 0015: Monotonic Sequence Assignment under Concurrent Sends
  - ADR 0016: Deterministic DM Uniqueness via dm_key
  - ADR 0017: Post-Commit Message Broadcast and Per-User Fanout
- Tooling & Verification:
  - Interactive manual verification script in `scripts/ws_test.py`.
