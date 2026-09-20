# ADR 0016: Deterministic DM Uniqueness via dm_key

## Status
Accepted

## Context
In a 1:1 chat, two users may attempt to initiate a direct message simultaneously. Without concurrency controls or unique constraints, two separate conversation rows could be created for the exact same pair of participants, causing fragmented chat histories.

## Decision
1. For direct messages (`type='dm'`), we compute a deterministic `dm_key`:
   ```python
   sorted_ids = sorted([str(user1.id), str(user2.id)])
   dm_key = f"{sorted_ids[0]}:{sorted_ids[1]}"
   ```
2. The `Conversation` model enforces a database unique constraint on `dm_key`:
   ```python
   dm_key = models.CharField(max_length=73, null=True, blank=True, unique=True)
   ```
   (Group conversations leave `dm_key=None`).
3. During DM creation, we perform `Conversation.objects.get_or_create(dm_key=dm_key, defaults={'type': 'dm'})` inside an atomic transaction.

## Consequences
* **Pros**:
  - Eliminates duplicate DMs completely at the database constraint level.
  - Race conditions between concurrent DM initiations safely resolve to the same conversation.
* **Cons**:
  - Limits 1:1 conversations to at most one per pair of users (which is the intended product behavior).
