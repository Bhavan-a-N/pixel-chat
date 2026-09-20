# ADR 0005: Defer Message Deletion

## Status
Accepted

## Context
In v1, there is no requirement to edit or delete messages. With only 3 users, storage is not a constraint. We must decide whether to implement the deletion mechanics (hard vs. soft delete, tombstones) now or defer it.

## Decision
We will defer implementing message deletion. 
When deletion is eventually implemented, it must use a "soft delete" or "tombstone" approach that propagates through the `after_seq` synchronization endpoint. If a message is hard deleted without a tombstone, clients that sync after the deletion will keep a stale copy of the message indefinitely since they rely on appending new sequential events.

## Consequences
*   **Pros**: Simplifies the v1 database schema and synchronization logic.
*   **Cons**: Deletion will require a schema migration and client-side update to handle tombstone records in the future.
