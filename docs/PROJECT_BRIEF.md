(same brief as before)

## Decisions

1. Login: email + password. Username is unique and is what friends use to
   find each other. No phone numbers.
2. Signup: invite-code only (a single shared code in .env), since the backend
   will be on a public URL and only my friends should get in.
3. Messages: text only for v1. No images, files, voice, edit, or delete.
   Typing indicators are in scope (they fit the WebSocket protocol).
4. Platform: Android only. No iOS, no web.
5. Avatars: generated from avatar_seed, no uploads.
6. Storage: currently 3 users, so a free Postgres tier is plenty
   (~1KB/message incl. indexes, roughly 50-100MB/year at heavy use).
   Keep all messages, with no retention job for now. Do NOT build retention
   or DB-size monitoring yet. Instead:
   - Write an ADR documenting that retention is deferred, with the trigger
     to revisit it (DB usage above ~70% of the tier, or user count growth)
     and a sketch of how it would be added.
   - Keep the schema growth-friendly: indexes on (conversation, created_at),
     no unbounded per-request queries, all list endpoints paginated.
   - Include a periodic cleanup of expired JWT blacklist rows.
   - Record the size estimate in docs/COST.md.
7. Encryption: none beyond HTTPS/WSS. No end-to-end encryption.
8. Hosting: free now, upgradeable later. One Dockerfile, all config via env
   vars, DB and Redis only via URLs, so moving to a paid database or larger
   host later is a config change, not a code change. Assume the free host may
   idle-sleep, so design for cold starts. No paid service is used today.
   Write docs/UPGRADE.md describing what to change when going to production
   (managed DB, backups, host size, monitoring), including a simple pg_dump
   backup script.
9. Timestamps: store UTC, display in the device's local time.
10. Versions: latest stable Django, Channels, and Flutter. Pin exact versions
    in requirements and pubspec.

Scale: 3 users now. Design simply for that, but keep the architecture able
to grow (stateless ASGI workers, Redis channel layer, paginated APIs) so a
production upgrade needs no rewrite.
