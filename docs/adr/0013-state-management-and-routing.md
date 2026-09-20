# ADR 0013: Flutter State Management and Routing

## Status
Accepted

## Context
The Pixel Chat mobile client requires a predictable state management solution and declarative routing that seamlessly handles auth lifecycle transitions (splash -> login/signup <-> home). Requirements include avoiding code generation (`freezed`, `json_serializable`, `build_runner`, or Riverpod codegen), maintaining testability with pure Dart unit and widget tests, and preventing UI flash (e.g. flashing the login screen on app boot for already-authenticated users).

## Decision
1. **State Management**: We use **Flutter Riverpod** (`flutter_riverpod: 3.3.2`) with manual, hand-written `Notifier` and immutable state models.
   - `AuthNotifier` holds an `AuthState` enum (`unknown`, `authenticated`, `unauthenticated`, `networkError`).
   - Domain models (`User`, `AuthTokens`) are hand-crafted immutable classes with explicit `fromJson` and `toJson` serialization methods.
2. **Routing**: We use **GoRouter** (`go_router: 17.5.0`) with reactive redirects via a `ChangeNotifier` bridge (`RouterNotifier`) listening to `authNotifierProvider`.
   - On startup, the app loads into `/splash` with state `unknown`.
   - If tokens are found and `/api/auth/me` succeeds, state transitions to `authenticated` and routes automatically to `/home`.
   - If `/api/auth/me` fails with a network/cold-start error, state transitions to `networkError`, staying on `/splash` with a friendly "Retry" button.
   - Only when explicit 401/403 or missing tokens occur does state transition to `unauthenticated`, routing to `/login`.

## Consequences
* **Pros**:
  - Eliminates build runner overhead, speeding up CI and local builds.
  - Zero login-screen flicker on cold start for logged-in users.
  - Graceful handling of cold starts / offline states without logging the user out.
* **Cons**:
  - Requires writing boilerplate equality operators and `fromJson`/`toJson` serializers by hand.
