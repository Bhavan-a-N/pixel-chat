# ADR 0007: Primary Key Strategy

## Status
Accepted

## Context
We must decide between UUIDs and auto-incrementing integers (BigInt) for primary keys on core entities (User, Conversation, Message).

## Decision
We will use **UUIDv4** for all primary keys (User, Conversation, Message). 
Crucially, ordering will *never* rely on the UUID. All chronological ordering will rely strictly on the per-conversation monotonic `seq` (as defined in ADR 0003).

## Consequences
*   **Pros**: Prevents ID enumeration attacks. Allows clients to generate IDs safely for idempotency. Database merges and migrations are simpler without collision risks.
*   **Cons**: UUIDs consume more storage and memory overhead compared to sequential integers.
