# ADR 0025: System Messages with Structured Data and Server Authority

## Status
Accepted

## Context
Group lifecycle events (creation, member additions, removals, departures, role updates, renames) need to be recorded in the conversation stream so all members share an auditable history of group alterations. However, client-generated messages must never be capable of forging system notifications or impersonating administrative actions.

## Decision
1. **Server Authority on System Messages**:
   - The `is_system` field on `Message` is exclusively set by the backend service.
   - Any client-submitted frame (`chat.send`) that supplies `is_system=True` or `system_data` has those fields ignored and forced to `is_system=False, system_data=None`.
2. **Message Sender & Client ID**:
   - The `sender` on a system message is set to the actor who initiated the action (e.g. the admin who added members, or the user who left).
   - The server generates a unique `client_id` (format: `sys-<uuid>`).
3. **Structured `system_data` Schema**:
   - `Message.system_data` stores JSON:
     - `kind`: String identifier (`group_created`, `member_added`, `member_removed`, `member_left`, `member_promoted`, `member_demoted`, `group_renamed`).
     - `actor_id`: UUID string of the acting user.
     - `target_ids`: List of UUID strings of impacted users (e.g. newly added members).
   - In addition to structured data, `body` contains human-readable summary text (e.g. `"Alice added Bob to the group"`).
4. **Client Rendering**:
   - Clients identify system messages via `is_system == true`.
   - System messages are displayed as centered pill chips rather than speech bubbles.
   - System messages are excluded from outgoing message ticks and preview-as-mine logic.

## Consequences
- **Pros**: Robust defense against message forgery. Structured metadata enables localized UI rendering or rich interactive chips in future updates.
- **Cons**: System messages increment `seq` monotonically like standard chat messages (intentional, to preserve linear conversation stream ordering).
