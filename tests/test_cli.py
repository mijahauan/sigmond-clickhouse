"""Tests for sigmond-clickhouse CLI shim.

The CLI imports clickhouse-connect lazily inside _connect(); tests
inject a fake by monkeypatching `_connect`, so a CH server is not
required.
"""

import io
import json
import sys
from pathlib import Path
from unittest import mock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from sigmond_clickhouse import cli, __version__, __contract_version__


class FakeQueryResult:
    def __init__(self, rows):
        self.result_rows = rows


class FakeClient:
    def __init__(self, databases=None, tables=None, fail=False):
        self._databases = databases or [
            ("wspr", 2, 1234, 100_000),
            ("psk",  1, 0,    0),
        ]
        self._tables = tables or {"wspr": {"spots", "noise"}}
        self.fail = fail
        self.commands_run = []
        self.closed = False

    def query(self, sql):
        if self.fail:
            raise RuntimeError("simulated CH unreachable")
        s = sql.strip().upper()
        if "SYSTEM.TABLES" in s and "GROUP BY DATABASE" in s:
            return FakeQueryResult(self._databases)
        if "SYSTEM.TABLES" in s and "DATABASE='WSPR'" in s.replace(" ", ""):
            return FakeQueryResult([(t,) for t in self._tables.get("wspr", set())])
        if s == "SELECT 1":
            return FakeQueryResult([(1,)])
        return FakeQueryResult([])

    def command(self, sql):
        self.commands_run.append(sql)

    def close(self):
        self.closed = True


def _capture_stdout(fn, *args, **kw):
    buf = io.StringIO()
    old = sys.stdout
    sys.stdout = buf
    try:
        rc = fn(*args, **kw)
    finally:
        sys.stdout = old
    return rc, buf.getvalue()


class TestVersion:
    def test_version_shape(self):
        rc, out = _capture_stdout(cli.cmd_version, mock.Mock())
        data = json.loads(out)
        assert rc == 0
        assert data["client"] == "clickhouse"
        assert data["version"] == __version__
        assert data["contract_version"] == __contract_version__
        assert "git" in data


class TestInventory:
    def test_inventory_with_reachable_ch(self):
        fake = FakeClient()
        with mock.patch.object(cli, "_connect", return_value=fake):
            rc, out = _capture_stdout(cli.cmd_inventory, mock.Mock(),
                                      env={"SIGMOND_CLICKHOUSE_URL": "http://localhost:8123"})
        data = json.loads(out)
        assert rc == 0
        assert data["client"] == "clickhouse"
        assert data["contract_version"] == __contract_version__
        assert len(data["instances"]) == 1
        inst = data["instances"][0]
        assert inst["instance"] == "default"
        assert inst["data_path"]["kind"] == "other"
        names = {db["name"] for db in inst["databases"]}
        assert names == {"wspr", "psk"}
        assert fake.closed

    def test_inventory_unreachable_still_emits_valid_json(self):
        fake = FakeClient(fail=True)
        with mock.patch.object(cli, "_connect",
                               side_effect=RuntimeError("boom")):
            rc, out = _capture_stdout(cli.cmd_inventory, mock.Mock(),
                                      env={"SIGMOND_CLICKHOUSE_URL": "http://x:1"})
        data = json.loads(out)
        assert rc == 0
        inst = data["instances"][0]
        assert inst.get("unreachable") is True
        assert inst["databases"] == []


class TestValidate:
    def test_validate_ok_when_wspr_tables_present(self):
        fake = FakeClient()
        with mock.patch.object(cli, "_connect", return_value=fake):
            rc, out = _capture_stdout(cli.cmd_validate, mock.Mock())
        data = json.loads(out)
        assert rc == 0
        assert data["ok"] is True
        assert data["issues"] == []

    def test_validate_warns_when_wspr_tables_missing(self):
        fake = FakeClient(tables={"wspr": set()})
        with mock.patch.object(cli, "_connect", return_value=fake):
            rc, out = _capture_stdout(cli.cmd_validate, mock.Mock())
        data = json.loads(out)
        assert rc == 0
        assert data["ok"] is True            # warns, not errors
        msgs = [i["message"] for i in data["issues"]]
        assert any("wspr.spots" in m for m in msgs)
        assert any("wspr.noise" in m for m in msgs)

    def test_validate_errors_when_unreachable(self):
        with mock.patch.object(cli, "_connect",
                               side_effect=RuntimeError("conn refused")):
            rc, out = _capture_stdout(cli.cmd_validate, mock.Mock())
        data = json.loads(out)
        assert rc == 1
        assert data["ok"] is False
        assert any(i["severity"] == "error" for i in data["issues"])


class TestMigrate:
    def test_migrate_runs_wsprdaemon_files(self, tmp_path):
        # Use the real schema/wsprdaemon/ directory shipped with the repo.
        fake = FakeClient()
        args = mock.Mock(database=None)
        with mock.patch.object(cli, "_connect", return_value=fake):
            rc, out = _capture_stdout(cli.cmd_migrate, args)
        data = json.loads(out)
        assert rc == 0
        # Three SQL files: 000_create_database, 001_create_spots, 002_create_noise.
        assert len(data["applied"]) == 3
        assert data["applied"][0].startswith("wsprdaemon/000_")
        assert any("001_create_spots" in p for p in data["applied"])
        assert any("002_create_noise" in p for p in data["applied"])
        assert len(fake.commands_run) == 3
