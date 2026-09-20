# ADR 0001: Defer Message Retention

## Status
Accepted

## Context
The application currently serves a small user base (approximately 3 users). We estimate storage requirements at ~1KB/message including indexes, meaning heavy use will only consume roughly 50-100MB/year. A free Postgres tier is currently sufficient. Implementing a message retention or cleanup job introduces unnecessary complexity for the current scale.

## Decision
We will defer implementing a message retention policy and database size monitoring for now. We will keep all messages indefinitely.
However, we will design the schema to be growth-friendly:
- Add indexes on `(conversation, created_at)`.
- Ensure no unbounded per-request queries exist (all list endpoints will be paginated).
- Include a periodic cleanup of expired JWT blacklist rows to prevent unbound growth of auth data.

## Consequences
- Less upfront engineering effort.
- Database size will grow monotonically over time.
- We must monitor database size manually or rely on hosting provider limits.

## Trigger for Revisit
We will revisit this decision and implement a retention job when:
- Database usage reaches ~70% of the free tier limit.
- User count growth indicates the free tier will be exhausted soon.

## Future Implementation Sketch
When required, message retention can be added via:
1. A celery beat task or a simple cron job hitting a custom Django management command.
2. The job will delete messages older than a configured threshold (e.g., 90 days).
3. The query will use the `created_at` index to quickly identify and bulk-delete old rows efficiently in chunks to prevent locking.
