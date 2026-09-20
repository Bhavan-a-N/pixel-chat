# Notes

Backend authentication has been implemented successfully!

- The custom `User` model is created, UUIDv4-backed, and migrations are applied.
- SimpleJWT is setup with a 15-minute rotation for access tokens and blacklisting for refresh tokens.
- Tests are comprehensive (15 tests passing, including isolated throttle testing).
- `docker-compose` successfully spun up Postgres on port 5432.
- The repository `.github/workflows/backend.yml` handles CI checks on every push to master.
- Quickstart instructions have been added to the README.
