#!/usr/bin/env python
"""
Run pending migrations on deploy. Refuses unapplied *destructive* migrations
unless ALLOW_DESTRUCTIVE_MIGRATIONS=true (set only after manual review + backup).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BACKEND_DIR))

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings.prod")

import django  # noqa: E402

django.setup()

from django.core.management import call_command  # noqa: E402
from django.db import connection  # noqa: E402
from django.db.migrations.executor import MigrationExecutor  # noqa: E402

DESTRUCTIVE_OP_NAMES = frozenset(
    {
        "RemoveField",
        "DeleteModel",
    }
)


def pending_destructive_migrations() -> list[str]:
    executor = MigrationExecutor(connection)
    targets = executor.loader.graph.leaf_nodes()
    plan = executor.migration_plan(targets)
    destructive: list[str] = []
    for migration, backwards in plan:
        if backwards:
            continue
        for op in migration.operations:
            if type(op).__name__ in DESTRUCTIVE_OP_NAMES:
                label = f"{migration.app_label}.{migration.name}"
                destructive.append(label)
                break
    return destructive


def main() -> int:
    destructive = pending_destructive_migrations()
    if destructive:
        allow = os.getenv("ALLOW_DESTRUCTIVE_MIGRATIONS", "").lower() in (
            "1",
            "true",
            "yes",
        )
        if not allow:
            print(
                "Refusing to migrate: pending migrations include destructive "
                f"operations: {', '.join(destructive)}. "
                "Review, pg_dump backup, then set ALLOW_DESTRUCTIVE_MIGRATIONS=true "
                "for one deploy only.",
                file=sys.stderr,
            )
            return 1
        print(
            "WARNING: ALLOW_DESTRUCTIVE_MIGRATIONS is set; applying destructive "
            f"migrations: {', '.join(destructive)}",
            file=sys.stderr,
        )

    call_command("migrate", "--noinput", verbosity=1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
