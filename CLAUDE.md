# Location Rules
- The project lives ONLY in D:\pixel-chat (the current working directory).
  Create everything inside it. Never create, modify, or delete files outside it.
- Neat structure:
    D:\pixel-chat\
      backend\   (Django)
      app\       (Flutter)
      docs\      (brief, architecture)
      CLAUDE.md, NOTES.md, README.md, docker-compose.yml, .gitignore
- Keep dependencies inside the project: create the Python virtual environment
  at backend\.venv, not globally. Do not pip install globally.
- If a step would require writing outside D:\pixel-chat (global installs,
  system config), stop and tell me what and why instead of doing it.

# Windows Notes
- Use forward-slash-safe paths in code.
- Give PowerShell commands (not bash) in all instructions.

# Project Guidelines
- Backend: Django
- App: Flutter
- Use `.venv` for Python environments.

# Engineering Quality Rules
- Every significant design choice gets a short ADR in docs/adr/.
- GitHub Actions CI (free): backend tests, flutter analyze, flutter test on every push.
- Structured logging on the backend; a /health endpoint.
- Maintain docs/COST.md listing every service used and its free-tier limit.
- Prefer clean, well-tested, readable code over cleverness.
