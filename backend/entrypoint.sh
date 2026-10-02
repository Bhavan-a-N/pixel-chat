#!/bin/sh
# entrypoint.sh — container startup for pixel-chat backend (Render free tier).
#
# Runs database migrations non-destructively, then execs Daphne.
# The ALLOW_DESTRUCTIVE_MIGRATIONS safety gate is preserved: if any pending
# migration contains a RemoveField or DeleteModel operation, startup is aborted
# unless ALLOW_DESTRUCTIVE_MIGRATIONS=true is set (set it for one deploy only,
# after manual review and a pg_dump backup).
set -e

echo "[entrypoint] Running pre-startup migration check..."
python scripts/pre_deploy_migrate.py

echo "[entrypoint] Migrations applied. Starting Daphne..."
exec daphne -b 0.0.0.0 -p "${PORT:-8000}" config.asgi:application
