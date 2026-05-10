# sigmond-clickhouse

Local ClickHouse staging tier for the HamSCI sigmond suite.  Provides
the §17 *output sink* that producer clients (wsprdaemon-client,
psk-recorder, hfdl-recorder, hf-timestd, codar-sounder) write to via
`sigmond.hamsci_ch.Writer`.  Future `hs-uploader` reads from these
tables to ship rows upstream (wsprdaemon.org, psws.eng.ua.edu).

## Status

**v0.1** — Phase A scaffold.  Owns the wire-pinned WSPR schema vendored
from `wsprdaemon-server`.  `sigmond-clickhouse inventory --json` and
`validate --json` shim land in this release; the `smd apply` migration
runner integration follows in Phase B.

## What this does

- Wraps the Debian `clickhouse-server.service` with sigmond conventions
  (loopback default, sigmond-managed user/password, listen-address
  drop-in via `coordination.toml`'s `[storage.clickhouse]`).
- Vendors `wspr.spots` and `wspr.noise` DDL verbatim from
  `wsprdaemon-server` so locally-written rows are byte-identical to the
  rows wsprdaemon.org expects.  See `SCHEMA_PROVENANCE`.
- Surfaces hosted databases (with row counts and bytes-on-disk) in
  `inventory --json` so sigmond's disk-budget machinery can account for
  CH storage alongside file sinks.

## What this does not do

- Does not fork or replace `clickhouse-server` — it configures it.
- Does not own per-mode schemas (`psk`, `hfdl`, `codar`, `timestd`);
  those live in each producer client's `clickhouse/schema/` tree.
- Does not ship data upstream — that is `hs-uploader`'s role.

## Install

Pattern A (sigmond-managed):

```
sudo smd install clickhouse
sudo smd apply
sudo systemctl start sigmond-clickhouse
```

Standalone (without sigmond):

```
sudo ./scripts/install.sh
sudo systemctl start sigmond-clickhouse
```

Sigmond's `[storage.clickhouse]` block in `/etc/sigmond/coordination.toml`
controls listen address (`loopback` vs `lan`), retention defaults, and
per-mode retention overrides.  Omit the block and CH stays unconfigured
— producer clients silently fall back to file sinks.

## SQLite alternative for client hosts

A host that is purely a sigmond *client* (recorders that feed an
upstream wsprdaemon/HamSCI server) does not need a local ClickHouse
instance.  The local sink there is just a store-and-forward buffer for
the future `hs-uploader` to drain.  Running ClickHouse for that role
burns 1-2 GB of RAM and several cores of background-merge CPU on a
host whose real job is the SDR pipeline.

For that case, set `SIGMOND_SQLITE_PATH` in `coordination.env` instead
of installing `sigmond-clickhouse`:

```
SIGMOND_SQLITE_PATH=/var/lib/sigmond/sink.db
```

`sigmond.hamsci_ch.Writer.from_env()` dispatches on which env var is
set: `SIGMOND_SQLITE_PATH` selects the SQLite FIFO queue backend;
`SIGMOND_CLICKHOUSE_URL` selects this package; neither → no-op.
Producer clients use the same API either way.  See
`sigmond/lib/sigmond/hamsci_ch/sqlite_writer.py` for the on-disk shape.

## License

MIT.
