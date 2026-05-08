# Local ClickHouse Implementation — Status

Snapshot of where the local-CH staging-tier work sits as of 2026-05-07,
spanning sigmond + sigmond-clickhouse + four producer client repos.
The plan this implements is at
`/home/mjh/.claude/plans/https-github-com-rrobinett-wsprdaemon-se-compiled-lerdorf.md`.

## Goal

Add a local ClickHouse instance per HamSCI station as a sigmond-managed
component.  Every producer client (wsprdaemon-client, psk-recorder,
hfdl-recorder, hf-timestd, codar-sounder) writes structured rows to
local CH in parallel with its existing file outputs.  The future
`hs-uploader` library — designed separately — reads from local CH and
ships rows upstream (wsprdaemon.org, PSKReporter, airframes.io,
psws.eng.ua.edu, etc.).  WSPR uses an upstream-pinned schema vendored
from `wsprdaemon-server` so rows are byte-identical and the eventual
upload path is wire-compatible.

## Architecture

```
                   sigmond/etc/coordination.toml
                              │
                  [storage.clickhouse] block
                              │
                              ▼
                  /etc/sigmond/coordination.env
                              │
              SIGMOND_CLICKHOUSE_URL, _USER, _DB_*, _LISTEN
                              │
   ┌──────────────────────────┼──────────────────────────┐
   ▼                          ▼                          ▼
producer            producer            producer
client              client              client
(decode → file)     (decode → file)     (decode → file)
  + ChTailer/         + ChTailer/         + wd-ch-write
    ch_writer           ch_writer           (called from wd-post)
        │                   │                   │
        └────── sigmond.hamsci_ch.Writer ───────┘
                              │
                              ▼
                  http://localhost:8123
                  (sigmond-clickhouse component
                   wrapping clickhouse-server.service)
                              │
                  ┌───────────┼───────────┬──────────┬──────────┐
                  ▼           ▼           ▼          ▼          ▼
              wspr.spots  psk.spots  hfdl.spots  codar.*  timestd.*
              wspr.noise               (Phase B)  (Phase D) (Phase C)
                (Phase A)
                              │
                              ▼
                       hs-uploader
                  (separate library, not yet built)
                              │
                              ▼
              wsprdaemon.org / PSKReporter / airframes.io
              / psws.eng.ua.edu
```

## Status by phase

### Phase A — sigmond foundation + WSPR canary  ✅ COMPLETE

- **Contract v0.6 §17 — Output sinks** drafted in
  `sigmond/docs/CLIENT-CONTRACT.md`.  Symmetric to §16's input
  `data_path`.  v0.5 clients auto-promote `disk_writes` so backwards
  compat is unconditional.
- **`[client.clickhouse]`** in `sigmond/etc/catalog.toml` —
  `kind="server"`, `start_priority=50`, `contract="0.6"`.
- **`[storage.clickhouse]`** block added to
  `sigmond/etc/coordination.example.toml` (loopback default; LAN
  example commented).
- **`Storage` / `ClickHouseStorage` dataclasses** in
  `sigmond/lib/sigmond/coordination.py` parse the new TOML block;
  `render_env` emits `SIGMOND_CLICKHOUSE_URL`, `_USER`,
  `_PASSWORD_FILE`, `_LISTEN`, plus per-mode `_DB_<MODE>` aliases for
  wspr/psk/hfdl/codar/timestd.
- **`sigmond.hamsci_ch.Writer`** writer-side library at
  `sigmond/lib/sigmond/hamsci_ch/`.  Lazy-imports `clickhouse-connect`
  (sigmond core stays stdlib-only); batches inserts (default 50k);
  `BufferFull` on overflow (silent loss is forbidden); schema-version
  + column-hash check at first connect; **no-op when
  SIGMOND_CLICKHOUSE_URL is unset** (standalone-safe).  Optional dep
  declared in sigmond's pyproject.toml as `sigmond[clickhouse]`.
- **`sigmond-clickhouse` repo** at `/opt/git/sigmond/clickhouse/` —
  - `deploy.toml` + `pyproject.toml` + `LICENSE` + `README.md`.
  - `SCHEMA_PROVENANCE` pinning `wsprdaemon-server@374514ee`.
  - `schema/wsprdaemon/{000,001,002}_*.sql` vendored verbatim.
  - `etc/10-sigmond-listen.xml.j2` listen-address drop-in template.
  - `systemd/sigmond-clickhouse.service` wrapping the Debian
    `clickhouse-server.service`.
  - `scripts/install.sh` standalone installer.
  - `src/sigmond_clickhouse/cli.py` — `inventory --json`,
    `validate --json`, `version --json`, `migrate`, `config init|edit`
    shim per CONTRACT §3.
- **`wsprdaemon-client` Phase A canary** —
  - Bumped to contract v0.6.
  - `[clickhouse]` block referencing `wsprdaemon:1`.
  - `data_sinks` in `inventory --json` per instance (file always; CH
    when `SIGMOND_CLICKHOUSE_URL` is set).
  - `lib/wdlib/ch_writer.py` parses `_wd_spots.txt` files using the
    same parser shape as `wsprdaemon-server/tar-bulk-loader.py`, so
    edge rows are byte-identical to central rows.
  - `bin/wd-ch-write` CLI standalone-safe entrypoint.
  - **`bin/wd-post` hooked**: when a `_wd_spots.txt` file is moved into
    the upload queue, `wd-ch-write` is invoked in parallel with the
    SFTP path.  Self-disabling without sigmond / without CH.

### Phase B — psk-recorder + hfdl-recorder  ✅ COMPLETE

Both clients land independently, sibling pattern to Phase A.

- **psk-recorder** —
  - Bumped to contract v0.6.
  - Greenfield `psk` schema at `clickhouse/schema/psk/{000,001}_*.sql`.
    `psk.spots` columns mirror what `decode_ft8` (ka9q/ft8_lib) actually
    emits per `decode_ft8.c:363`: time, score, dt, frequency,
    decoded message, plus best-effort callsigns/grid/report.
  - `data_sinks` in inventory.
  - `core/ch_tailer.py` — line-format parser, `ChTailer` daemon thread
    per `(radiod, mode)`.
  - Wired into `core/recorder.py` `_start_ch_tailers()` alongside
    existing `PskReporterUploader`.  Tails the same per-mode log file
    `pskreporter-sender` tails — no contention, two independent
    consumers of the same source-of-truth log.
- **hfdl-recorder** —
  - Bumped to contract v0.6.
  - Greenfield `hfdl` schema at `clickhouse/schema/hfdl/{000,001}_*.sql`.
    `hfdl.spots` covers dumphfdl metadata (station, freq, signal/noise,
    slot, bit_rate) + best-effort libacars extraction (direction,
    ground_station, icao_addr, flight, aircraft_reg, acars_label,
    acars_message, position lat/lon/alt) + `raw_json` for re-parse.
  - `data_sinks` in inventory.
  - `core/ch_tailer.py` — JSON-per-line parser tolerant of libacars
    schema drift (DFS over PDU subtree, recognizes both `gs` keys and
    `{type:"ground"}` patterns).  Handles partial trailing lines
    across reads.  ICAO normalizer accepts int / hex / decimal /
    0x-prefixed.
  - Wired into `core/daemon.py` `_start_ch_tailers()` per-band.

### Phase C — hf-timestd L2 events  ✅ COMPLETE (shipped in hf-timestd v7.1.0)

L1 raw correlator output stays in HDF5 (canonical metrology
artefact).  L2 fused detections emitted by
`L2CalibrationService._calibrate_measurement` (~1 row/min/station)
also land in `timestd.events` via a `sigmond.hamsci_ch.Writer`
constructed in `L2CalibrationService.__init__`; per-station inserts
fire right after the HDF5 `write_measurement` call.  CH failures are
non-fatal — the HDF5 path is unaffected.  Schema in
`hf-timestd/clickhouse/schema/timestd/`: greenfield `timestd.events`
combining the plan's L2 fields with hf-timestd's own
`L2TimingMeasurement` record (clock_offset_ms,
expanded_uncertainty_ms, propagation_mode, n_hops, quality_grade,
discrimination_method).  Contract v0.6, `data_sinks` replacing
`disk_writes` in inventory.

### Phase D — codar-sounder  ✅ COMPLETE (shipped in codar-sounder v0.4.0)

The FMCW dechirp engine landed in v0.3, and v0.4.0 wired the full
CH integration: `clickhouse/schema/codar/{000,001}_*.sql` (greenfield
`codar.spots` — ReplacingMergeTree, monthly-partitioned, ORDER BY
`(host_call, station_id, time, peak_index)`); `[clickhouse]` block
in `deploy.toml` (schema_version 1); `data_sinks` in inventory; per-
peak insert via `sigmond.hamsci_ch.Writer` from `SounderDaemon`.
v0.4.0 also added multi-peak detection + layer classifier
(`E`/`F1`/`F2`/`F2_extreme`) and `tdma-scan --write-config`.

### Schema-migration runner integration  ✅ COMPLETE

`sigmond.commands.ch_apply` walks every installed client's
`deploy.toml` for a `[clickhouse]` block, materialises the per-client
schema_dir, and runs the `[0-9]*.sql` migrations against the
configured CH server.  Hooked into `bin/smd cmd_apply` so
`sudo smd apply` brings every database to the schema version each
client expects.  Idempotent (uses `CREATE … IF NOT EXISTS`); per-
client failures don't abort sibling clients.  No-op when
`[storage.clickhouse]` is absent from coordination.toml (file-only
default preserved).  14 tests cover discovery, migration ordering,
dry-run, partial-failure isolation, and summary rendering.

## Test totals

All test suites pass except one pre-existing unrelated failure:

| Suite                                           | Passed | Skipped | Notes                                       |
|-------------------------------------------------|-------:|--------:|---------------------------------------------|
| sigmond                                         |    427 |      35 | +21 new (Storage, hamsci_ch)                |
| sigmond-clickhouse                              |      7 |       0 | new                                         |
| wsprdaemon-client (`tests/test_ch_writer.py`)   |     12 |       0 | new                                         |
| psk-recorder (full)                             |     91 |       0 | +21 new; 1 pre-existing `test_wav` failure  |
| hfdl-recorder (full)                            |     75 |       0 | +18 new                                     |

Total **612 passed** across the touched suites, with **77 new tests**
covering the CH writer, tailers, parsers, and `data_sinks` inventory
shape.  No live ClickHouse server required to run any of them — all
use injected fake clients.

## File inventory (post-implementation)

### sigmond
```
docs/CLIENT-CONTRACT.md                     [v0.6, §17 added]
etc/catalog.toml                            [+[client.clickhouse]]
etc/coordination.example.toml               [+[storage.clickhouse] example]
lib/sigmond/coordination.py                 [+Storage, ClickHouseStorage, env]
lib/sigmond/hamsci_ch/__init__.py           [NEW]
lib/sigmond/hamsci_ch/writer.py             [NEW]
pyproject.toml                              [+optional-deps[clickhouse]]
tests/test_catalog.py                       [+1 test]
tests/test_coordination.py                  [+TestClickHouseStorage]
tests/test_hamsci_ch.py                     [NEW: 17 tests]
```

### sigmond-clickhouse (NEW repo)
```
deploy.toml
pyproject.toml
LICENSE  README.md  SCHEMA_PROVENANCE
schema/wsprdaemon/{000_create_database,001_create_spots,002_create_noise}.sql
etc/10-sigmond-listen.xml.j2
systemd/sigmond-clickhouse.service
scripts/install.sh
src/sigmond_clickhouse/__init__.py
src/sigmond_clickhouse/cli.py
tests/test_cli.py                           [7 tests]
```

### wsprdaemon-client
```
deploy.toml                                 [v0.6, +[clickhouse]]
lib/wdlib/contract.py                       [v0.6, +data_sinks]
lib/wdlib/ch_writer.py                      [NEW]
bin/wd-post                                 [+wd-ch-write hook]
bin/wd-ch-write                             [NEW]
tests/test_ch_writer.py                     [NEW: 12 tests]
```

### psk-recorder
```
deploy.toml                                 [v0.6, +[clickhouse]]
src/psk_recorder/contract.py                [v0.6, +data_sinks]
src/psk_recorder/core/ch_tailer.py          [NEW]
src/psk_recorder/core/recorder.py           [+_start_ch_tailers]
clickhouse/schema/psk/{000,001}_*.sql       [NEW]
tests/test_contract.py                      [+data_sinks test]
tests/test_ch_tailer.py                     [NEW: 20 tests]
```

### hfdl-recorder
```
deploy.toml                                 [v0.6, +[clickhouse]]
src/hfdl_recorder/contract.py               [v0.6, +data_sinks]
src/hfdl_recorder/core/ch_tailer.py         [NEW]
src/hfdl_recorder/core/daemon.py            [+_start_ch_tailers]
clickhouse/schema/hfdl/{000,001}_*.sql      [NEW]
tests/test_contract.py                      [v0.6, +data_sinks test]
tests/test_ch_tailer.py                     [NEW: 17 tests]
```

## Resumption pointers

To pick the work back up after codar-sounder v0.2:

1. **Phase C (hf-timestd)** — pattern follows psk-recorder closely:
   define `clickhouse/schema/timestd/`, add `[clickhouse]` to its
   `deploy.toml`, bump contract to 0.6, write a tailer that reads
   `timestd-fusion`'s L2 event stream, wire it into the fusion
   process startup.  Field list is in the plan file (search for
   "Phase C").
2. **Phase D (codar-sounder)** — once v0.2's dechirp engine lands,
   greenfield `codar.spots` schema + `ChTailer` against whatever
   spool format v0.2 produces.  No migration cost; v0.1 today is a
   stub.
3. **Schema-migration runner** — extend `sigmond/lib/sigmond/installer.py`
   (or add a new `ch_apply.py`) to read each installed client's
   `[clickhouse]` block from its `deploy.toml`, walk
   `<repo>/<schema_dir>/[0-9]*.sql`, and run them via
   `sigmond-clickhouse migrate --database=<db>`.  Then `smd apply`
   becomes the single verb that brings every CH database to the
   schema version each client expects.
4. **Live verification on bee1** — install
   `sigmond-clickhouse`, set `[storage.clickhouse]` in
   `/etc/sigmond/coordination.toml`, run a 2-minute WSPR cycle,
   `SELECT count() FROM wspr.spots WHERE time > now() - INTERVAL
   10 MINUTE`, compare to wsprdaemon.org's central CH for the same
   `rx_sign` window.  The cityHash64 dedup id should be byte-identical
   for identical input rows — wire-compat check.

## Out of scope (intentional)

- **`hs-uploader` library design** — sibling to `hamsci_ch`, designed
  separately.  This implementation enables it (per-mode DBs, schema
  versioning, `data_sinks` surface) but does not build it.  Plan
  forbids `shipped_at` columns or sidecar shipping tables in any
  per-mode table during phases A–D.
- **Production deployment** — every change in this implementation is
  additive.  The existing file/SFTP/PSKReporter/airframes paths are
  unaffected when `SIGMOND_CLICKHOUSE_URL` is unset.  Operators opt
  in by adding `[storage.clickhouse]` to coordination.toml.
