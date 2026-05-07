"""sigmond-clickhouse CLI shim — implements CONTRACT §3 surfaces.

Subcommands:
  inventory --json   — what databases/tables this CH instance hosts
  validate --json    — connectivity + required schemas + permissions
  version --json     — package and contract versions
  migrate            — apply schema/<db>/*.sql migrations (idempotent)
  config init        — first-run setup (password file, listen drop-in)
  config edit        — open [storage.clickhouse] block in $EDITOR

Stdout cleanliness (CONTRACT §3): JSON commands emit JSON only.  All
human-readable text goes to stderr.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from pathlib import Path
from typing import Any, Optional

from . import __contract_version__, __version__

# Stderr-only logger — matches §10's logging discipline.
logging.basicConfig(
    stream=sys.stderr,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("sigmond-clickhouse")


# ----- helpers ---------------------------------------------------------------

def _git_short() -> Optional[str]:
    """Best-effort git short hash for the repo this script lives in."""
    repo = Path(__file__).resolve().parent.parent.parent
    head = repo / ".git" / "HEAD"
    if not head.exists():
        return None
    try:
        ref_line = head.read_text().strip()
        if ref_line.startswith("ref: "):
            ref_path = repo / ".git" / ref_line[5:]
            if ref_path.exists():
                return ref_path.read_text().strip()[:7]
        return ref_line[:7]
    except OSError:
        return None


def _connect(env: Optional[dict] = None):
    """Connect to CH using SIGMOND_CLICKHOUSE_* env (or the local default)."""
    e = env if env is not None else os.environ
    url = e.get("SIGMOND_CLICKHOUSE_URL", "http://127.0.0.1:8123")
    user = e.get("SIGMOND_CLICKHOUSE_USER", "default")
    password_file = e.get("SIGMOND_CLICKHOUSE_PASSWORD_FILE")
    password = ""
    if password_file:
        try:
            password = Path(password_file).read_text().strip()
        except OSError:
            pass
    import clickhouse_connect
    from urllib.parse import urlparse
    u = urlparse(url)
    return clickhouse_connect.get_client(
        host=u.hostname or "127.0.0.1",
        port=u.port or 8123,
        username=user,
        password=password,
    )


# ----- inventory -------------------------------------------------------------

def _list_databases(client) -> list[dict]:
    """Return per-database stats from system.tables."""
    out: list[dict] = []
    rows = client.query(
        "SELECT database, "
        "count() AS table_count, "
        "sum(total_rows) AS total_rows, "
        "sum(total_bytes) AS total_bytes "
        "FROM system.tables "
        "WHERE database NOT IN ('system','INFORMATION_SCHEMA','information_schema') "
        "GROUP BY database "
        "ORDER BY database"
    ).result_rows
    for db, tcount, rcount, bcount in rows:
        out.append({
            "name":          db,
            "table_count":   int(tcount or 0),
            "rows":          int(rcount or 0),
            "bytes_on_disk": int(bcount or 0),
        })
    return out


def cmd_inventory(args, env=None) -> int:
    """Emit inventory per CONTRACT §3.  JSON only on stdout."""
    e = env if env is not None else os.environ
    instance = {
        "instance":     "default",
        "host":         e.get("SIGMOND_CLICKHOUSE_URL", "http://127.0.0.1:8123"),
        "listen":       e.get("SIGMOND_CLICKHOUSE_LISTEN", "loopback"),
        "data_path":    {"kind": "other",
                         "details": {"description": "ClickHouse server (storage tier)"}},
        "databases":    [],
    }

    try:
        client = _connect(e)
        instance["databases"] = _list_databases(client)
        client.close()
    except Exception as exc:
        # Server not running or unreachable — surface as an issue but emit
        # valid JSON so callers can still parse.
        log.warning("inventory: CH unreachable: %s", exc)
        instance["databases"] = []
        instance["unreachable"] = True

    inv = {
        "client":            "clickhouse",
        "version":           __version__,
        "contract_version":  __contract_version__,
        "git":               {"short": _git_short()},
        "instances":         [instance],
        "issues":            [],
    }
    json.dump(inv, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


# ----- validate --------------------------------------------------------------

def cmd_validate(args, env=None) -> int:
    """Self-validate per CONTRACT §3.  JSON only on stdout."""
    e = env if env is not None else os.environ
    issues: list[dict] = []
    ok = True

    try:
        client = _connect(e)
        client.query("SELECT 1")
        # Required wire-pinned WSPR tables.  Missing means migrations
        # haven't run, not a bug — flag as warn.
        rows = client.query(
            "SELECT name FROM system.tables WHERE database='wspr'"
        ).result_rows
        wspr_tables = {r[0] for r in rows}
        if "spots" not in wspr_tables:
            issues.append({"severity": "warn", "instance": "default",
                           "message": "wspr.spots not present (run smd apply)"})
        if "noise" not in wspr_tables:
            issues.append({"severity": "warn", "instance": "default",
                           "message": "wspr.noise not present (run smd apply)"})
        client.close()
    except Exception as exc:
        ok = False
        issues.append({"severity": "error", "instance": "default",
                       "message": f"clickhouse unreachable: {exc}"})

    out = {"ok": ok, "issues": issues}
    json.dump(out, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0 if ok else 1


# ----- version ---------------------------------------------------------------

def cmd_version(args, env=None) -> int:
    out = {
        "client":           "clickhouse",
        "version":          __version__,
        "contract_version": __contract_version__,
        "git":              {"short": _git_short()},
    }
    json.dump(out, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


# ----- migrate ---------------------------------------------------------------

def _schema_dir() -> Path:
    return Path(__file__).resolve().parent.parent.parent / "schema"


def _run_migrations(client, schema_root: Path, db_filter: Optional[str] = None) -> list[str]:
    """Run every NNN_*.sql under schema/<db>/ in order.  Idempotent (uses
    CREATE ... IF NOT EXISTS).  Returns list of applied migration names.
    """
    applied: list[str] = []
    if not schema_root.exists():
        return applied
    for db_dir in sorted(schema_root.iterdir()):
        if not db_dir.is_dir():
            continue
        if db_filter and db_dir.name != db_filter:
            continue
        for sql_file in sorted(db_dir.glob("[0-9]*.sql")):
            sql = sql_file.read_text()
            try:
                client.command(sql)
                applied.append(f"{db_dir.name}/{sql_file.name}")
                log.info("applied %s/%s", db_dir.name, sql_file.name)
            except Exception as exc:
                log.error("failed %s/%s: %s", db_dir.name, sql_file.name, exc)
                raise
    return applied


def cmd_migrate(args, env=None) -> int:
    """Apply schema migrations.  Runs schema/wsprdaemon/ here, plus any
    other databases that have registered their schema/ tree (via
    `--include-clients` walking each client's deploy.toml — Phase B)."""
    client = _connect(env)
    try:
        applied = _run_migrations(client, _schema_dir(), db_filter=args.database)
        out = {"applied": applied}
        json.dump(out, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0
    finally:
        client.close()


# ----- config (skeleton) -----------------------------------------------------

def cmd_config(args, env=None) -> int:
    """Stub for `config init|edit` (CONTRACT §14).  Phase A leaves these
    as no-ops that print guidance to stderr so the contract surface is
    declared; Phase B implements the password-generation and editor flow."""
    if args.action == "init":
        print("config init: (Phase A stub — manual steps below)", file=sys.stderr)
        print("  1. ensure /etc/sigmond/secrets/clickhouse-sigmond.pass exists", file=sys.stderr)
        print("  2. add [storage.clickhouse] to /etc/sigmond/coordination.toml", file=sys.stderr)
        print("  3. run: sudo smd apply", file=sys.stderr)
        return 0
    elif args.action == "edit":
        editor = os.environ.get("EDITOR", "vi")
        coord = "/etc/sigmond/coordination.toml"
        if not Path(coord).exists():
            print(f"config edit: {coord} not found", file=sys.stderr)
            return 1
        os.execvp(editor, [editor, coord])  # noqa: replaces process
    return 0


# ----- main ------------------------------------------------------------------

def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="sigmond-clickhouse")
    sub = p.add_subparsers(dest="cmd", required=True)

    inv = sub.add_parser("inventory")
    inv.add_argument("--json", action="store_true", default=True)
    inv.set_defaults(fn=cmd_inventory)

    val = sub.add_parser("validate")
    val.add_argument("--json", action="store_true", default=True)
    val.set_defaults(fn=cmd_validate)

    ver = sub.add_parser("version")
    ver.add_argument("--json", action="store_true", default=True)
    ver.set_defaults(fn=cmd_version)

    mig = sub.add_parser("migrate")
    mig.add_argument("--database", default=None,
                     help="apply only this database's migrations")
    mig.set_defaults(fn=cmd_migrate)

    cfg = sub.add_parser("config")
    cfg.add_argument("action", choices=["init", "edit"])
    cfg.set_defaults(fn=cmd_config)

    args = p.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
