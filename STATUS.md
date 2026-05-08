# Local ClickHouse Implementation — Status

**As of 2026-05-08: every numbered phase in the local-CH plan is complete.**
The only outstanding work is hardware-dependent live verification on
bee1 (described under [Live verification](#live-verification-on-bee1) below).

This document is the cross-repo snapshot of the work that ran from
2026-05-07 through 2026-05-08, spanning sigmond + sigmond-clickhouse
+ five producer client repos + the shared `sigmond.callhash` module.
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
   ┌────────────────────────────┼────────────────────────────┐
   ▼                            ▼                            ▼
producer client            producer client              producer client
(decode → file)            (decode → file)              (decode → file)
   + ChTailer / file-hook    + ChTailer / file-hook       + ChTailer
        │                          │                            │
        └────── sigmond.hamsci_ch.Writer  ──────────────────────┘
                                │
                  also: sigmond.callhash.CallHashTable
                  for compound-callsign resolution (psk + wspr)
                                │
                                ▼
                    http://localhost:8123
                    (sigmond-clickhouse component
                     wrapping clickhouse-server.service;
                     `smd apply` runs each client's
                     [clickhouse].schema_dir migrations)
                                │
                  ┌─────────────┼─────────────┬──────────┬──────────┐
                  ▼             ▼             ▼          ▼          ▼
              wspr.spots    psk.spots     hfdl.spots  codar.spots  timestd.events
              wspr.noise
                                │
                                ▼
                         hs-uploader
                  (separate library, deferred — this
                   implementation enables it but does
                   not build it)
                                │
                                ▼
              wsprdaemon.org / PSKReporter / airframes.io
              / psws.eng.ua.edu
```

## Status by phase

### Phase A — sigmond foundation + WSPR canary  ✅

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
  - `bin/wd-ch-write` CLI standalone-safe entrypoint, with
    `--callhash-path` flag for cross-invocation table persistence.
  - **`bin/wd-post` hooked**: when a `_wd_spots.txt` file is moved into
    the upload queue, `wd-ch-write` is invoked in parallel with the
    SFTP path.  Self-disabling without sigmond / without CH.

### Phase B — psk-recorder + hfdl-recorder  ✅

Both clients land independently, sibling pattern to Phase A.

- **psk-recorder** (now v0.4.0) —
  - Contract v0.6.
  - Greenfield `psk` schema at `clickhouse/schema/psk/{000,001,002}_*.sql`.
    `psk.spots` columns originally mirrored what `decode_ft8` (ka9q/
    ft8_lib) emits.  Migration `002_add_jt9_columns.sql` added
    `snr_db Nullable(Float32)`, `spectral_width_hz Nullable(Float32)`,
    and `decoder_kind LowCardinality(String) DEFAULT 'decode_ft8'`
    when v0.3.0 swapped the default decoder to WSJT-X's `jt9` (which
    reports a calibrated dB SNR instead of ft8_lib's opaque "score").
  - Bundled per-arch `jt9` binaries under `bin/decoders/jt9-{x86,
    arm64,arm32}-v27` (avoids pulling in the full `wsjtx` GUI
    package); `scripts/install.sh` arch-detect + symlink to
    `/opt/psk-recorder/bin/decoders/jt9`.
  - `data_sinks` in inventory.
  - `core/ch_tailer.py` — dual-format auto-detect parser (handles
    both decode_ft8 native lines and jt9's WSJT-X-canonical format
    that `slot.py` materialises with a `YYMMDD` prefix and `MODE`
    suffix).  Wired into `core/recorder.py` `_start_ch_tailers()`
    alongside the existing `PskReporterUploader`; both consume the
    same source-of-truth log file.
  - **`sigmond.callhash` integration**: ChTailer feeds each chunk
    of new log text to a per-radiod `CallHashTable` before parsing
    so `<call>` markers (compound first-occurrence announcements)
    accumulate.  Persists to `/var/lib/psk-recorder/<radiod>/callhash.json`
    across daemon restarts.  `_parse_message` strips `<>` brackets
    via `_strip_call_brackets()` so bracketed compound calls (e.g.
    `<K1ABC/QRP>`, `<VE3/W1XYZ>`) land as plaintext in `tx_call` /
    `rx_call` instead of being dropped.  The `_CALL_RE` regex also
    accepts prefix-form compounds.
- **hfdl-recorder** —
  - Contract v0.6.
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

### Phase C — hf-timestd L2 events  ✅ (shipped 2026-05-08 in v7.1.0)

L1 raw correlator output stays in HDF5 (canonical metrology
artefact, ~kHz rate, wrong shape for CH).  L2 fused detections
emitted by `L2CalibrationService._calibrate_measurement` (~1 row/
min/station) also land in `timestd.events` via a
`sigmond.hamsci_ch.Writer` constructed in
`L2CalibrationService.__init__`; per-station inserts fire right
after the canonical HDF5 `write_measurement` call.  CH failures are
non-fatal — the HDF5 path is unaffected.

Schema in `hf-timestd/clickhouse/schema/timestd/`: greenfield
`timestd.events` combining the plan's L2 fields with hf-timestd's
own `L2TimingMeasurement` record (`clock_offset_ms`,
`expanded_uncertainty_ms`, `propagation_mode`, `n_hops`,
`quality_grade`, `discrimination_method`).  Robust enum
serialisation maps `StationID`/`DiscriminationMethod`/`QualityFlag`/
`QualityGrade` to plain strings.  Contract v0.6, `data_sinks`
replacing `disk_writes` in inventory.

### Phase D — codar-sounder  ✅ (shipped in v0.4.0)

The FMCW dechirp engine landed in v0.3.  v0.4.0 wired the full CH
integration: `clickhouse/schema/codar/{000,001}_*.sql` (greenfield
`codar.spots` — ReplacingMergeTree, monthly-partitioned, ORDER BY
`(host_call, station_id, time, peak_index)`); `[clickhouse]` block
in `deploy.toml` (schema_version 1); `data_sinks` in inventory; per-
peak insert via `sigmond.hamsci_ch.Writer` from `SounderDaemon`.
v0.4.0 also added multi-peak detection (find_f_region_peaks plural,
up to 4 peaks per CPI) + layer classifier (`E`/`F1`/`F2`/
`F2_extreme`/`below_E`) + `tdma-scan --write-config` to persist
discovered TDMA offsets back into the operator's config TOML.

### Schema-migration runner  ✅

`sigmond.commands.ch_apply` walks every installed client's
`deploy.toml` for a `[clickhouse]` block, materialises the per-client
schema_dir, and runs the `[0-9]*.sql` migrations against the
configured CH server.  Hooked into `bin/smd cmd_apply` so
`sudo smd apply` brings every database to the schema version each
client expects.  Idempotent (uses `CREATE … IF NOT EXISTS`); per-
client failures don't abort sibling clients.  No-op when
`[storage.clickhouse]` is absent from coordination.toml (file-only
default preserved).

### `sigmond.callhash` shared library  ✅ (added 2026-05-08)

WSJT-X uses the same Bob Jenkins lookup3 hash function (seed 146)
in both `jt9` (FT4/FT8, 22-bit hashes) and `wsprd` (WSPR Type 3,
15-bit hashes) to compress compound callsigns into 77-bit / 50-bit
packets.  Per-slot decoder invocations (psk-recorder, wsprdaemon-
client) start with empty in-process tables, so most hashed
callsigns surface as the literal `<...>` placeholder in decoded
text.

`sigmond.callhash` is the single, shared module both clients import:

- `_nhash.py` — Bob Jenkins lookup3 port, **bit-exact** against
  WSJT-X's canonical `lib/wsprcode/nhash.c` for 23 reference
  vectors (verified during implementation including 11/12/13-byte
  boundary cases).  Exposes `nhash`, `hash22`, `hash15`, `hash12`,
  `hash10`.
- `table.py` — `CallHashTable` accumulates `<call>` markers from
  observed text, persists to JSON atomically (`.tmp` + `replace`),
  threadsafe, recovers cleanly from corrupt JSON / schema mismatch.
  Public method `normalise_brackets(token)` is used directly by
  wsprdaemon-client's `spot_to_ch_row` to strip `<>` from resolved
  compound calls and map `<...>` to empty.

64 tests cover hash-vector correctness, announcement parsing,
bracket normalisation, persistence (round-trip / no-op-when-clean
/ atomic-write / corrupt-recovery / schema-mismatch), thread-safety
stress, and stats.

## Test totals

All test suites pass (one pre-existing unrelated `test_wav` failure
in psk-recorder, unrelated to any CH work).

| Suite                            |  Passed | Skipped | Notes                                   |
|----------------------------------|--------:|--------:|-----------------------------------------|
| sigmond                          |     505 |      35 | +99 new (Storage, hamsci_ch, callhash, ch_apply)             |
| sigmond-clickhouse               |       7 |       0 | new repo                                |
| wsprdaemon-client                |      19 |       0 | new (+ callhash bracket normalisation)  |
| psk-recorder                     |     119 |       0 | +49 new across data_sinks / jt9 / callhash; 1 pre-existing test_wav failure |
| hfdl-recorder                    |      75 |       0 | +18 new                                 |
| codar-sounder                    |     158 |       0 | +41 new (filter + multi-peak + tdma-scan + CH writer)        |
| hf-timestd (CH-relevant subset)  |      10 |       0 | new — `tests/test_l2_clickhouse_wire.py` |

**Total: 893 tests passing across the touched suites**, with
**~230 new tests** added during the project.  No live ClickHouse
server is required — all tests use injected fake clients.

## File inventory (post-implementation)

### sigmond
```
docs/CLIENT-CONTRACT.md                     [v0.6, §17 added]
etc/catalog.toml                            [+[client.clickhouse]]
etc/coordination.example.toml               [+[storage.clickhouse] example]
lib/sigmond/coordination.py                 [+Storage, ClickHouseStorage, env]
lib/sigmond/hamsci_ch/__init__.py           [NEW]
lib/sigmond/hamsci_ch/writer.py             [NEW]
lib/sigmond/callhash/__init__.py            [NEW — public API]
lib/sigmond/callhash/_nhash.py              [NEW — Bob Jenkins port]
lib/sigmond/callhash/table.py               [NEW — CallHashTable]
lib/sigmond/commands/ch_apply.py            [NEW — schema runner]
bin/smd                                     [+ch_apply phase in cmd_apply]
pyproject.toml                              [+optional-deps[clickhouse]]
tests/test_catalog.py                       [+1 test]
tests/test_coordination.py                  [+TestClickHouseStorage]
tests/test_hamsci_ch.py                     [NEW: 17 tests]
tests/test_callhash_nhash.py                [NEW: ~24 tests]
tests/test_callhash_table.py                [NEW: ~40 tests]
tests/test_ch_apply.py                      [NEW: 14 tests]
```

### sigmond-clickhouse (NEW repo)
```
deploy.toml
pyproject.toml
LICENSE  README.md  SCHEMA_PROVENANCE  STATUS.md (this file)
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
lib/wdlib/ch_writer.py                      [NEW; +bracket normalisation
                                             via sigmond.callhash]
bin/wd-post                                 [+wd-ch-write hook with
                                             --callhash-path]
bin/wd-ch-write                             [NEW; --callhash-path flag]
tests/test_ch_writer.py                     [NEW: 19 tests]
```

### psk-recorder (now v0.4.0)
```
deploy.toml                                 [v0.6, +[clickhouse], v0.4.0]
pyproject.toml                              [v0.4.0]
config/psk-recorder-config.toml.template    [decoder_kind / decoder_jt9 keys]
src/psk_recorder/contract.py                [v0.6, +data_sinks]
src/psk_recorder/core/ch_tailer.py          [NEW; dual-format jt9+decode_ft8;
                                             callhash integration]
src/psk_recorder/core/recorder.py           [+_start_ch_tailers; +callhash_path]
src/psk_recorder/core/slot.py               [dual-decoder fork: jt9 default,
                                             decode_ft8 fallback]
src/psk_recorder/core/stream.py             [+decoder_kind / depth threading]
clickhouse/schema/psk/{000,001,002}_*.sql   [001 spots; 002 jt9 columns]
bin/decoders/jt9-{x86,arm64,arm32}-*        [bundled per-arch jt9]
scripts/install.sh                          [+Phase 4.5 bundled-jt9 install]
tests/test_contract.py                      [+data_sinks test]
tests/test_ch_tailer.py                     [20 tests]
tests/test_jt9.py                           [NEW: 28 tests]
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

### codar-sounder (now v0.4.0)
```
deploy.toml                                 [v0.6, +[clickhouse], v0.4.0]
pyproject.toml                              [v0.4.0]
README.md                                   [v0.4.0 status]
src/codar_sounder/contract.py               [v0.6, +data_sinks]
src/codar_sounder/core/stream.py            [+filter low/high edges via
                                             ka9q-python ≥3.11]
src/codar_sounder/core/trace.py             [find_f_region_peaks plural]
src/codar_sounder/core/invert.py            [+classify_layer]
src/codar_sounder/core/output.py            [+peak_index/peak_count/mode_layer]
src/codar_sounder/core/daemon.py            [+ch_writer + per-peak emission]
src/codar_sounder/tdma_config_writer.py     [NEW; tdma-scan --write-config]
clickhouse/schema/codar/{000,001}_*.sql     [NEW]
tasks/todo.md                               [v0.4.0 retrospective]
tests/test_contract.py                      [v0.6 contract + data_sinks]
tests/test_multi_peak.py                    [NEW: 25 tests]
tests/test_stream.py                        [NEW: 6 tests]
tests/test_tdma_config_writer.py            [NEW: 9 tests]
```

### hf-timestd (now v7.1.0)
```
deploy.toml                                 [v0.6, +[clickhouse], v7.1.0]
src/hf_timestd/cli.py                       [v0.6, +data_sinks]
src/hf_timestd/core/l2_calibration_service.py
                                            [+_build_ch_writer
                                             +_ch_row_from_l2 (staticmethods)
                                             +per-row insert after HDF5 write
                                             +CH close on stop]
clickhouse/schema/timestd/{000,001}_*.sql   [NEW; timestd.events]
tests/test_l2_clickhouse_wire.py            [NEW: 10 tests]
```

## Live verification on bee1

The only outstanding work — hardware-dependent — is to confirm the
end-to-end flow on a station with real radiod input.  Recommended
order:

1. **Install sigmond-clickhouse**.
   ```
   sudo smd install clickhouse           # or scripts/install.sh standalone
   ```
   Confirms apt-deps (clickhouse-server, clickhouse-client),
   installs the systemd unit, drops the listen-loopback config in
   `/etc/clickhouse-server/config.d/10-sigmond-listen.xml`.

2. **Enable the storage tier** in `/etc/sigmond/coordination.toml`:
   ```toml
   [storage.clickhouse]
   host                  = "localhost"
   listen                = "loopback"
   user                  = "sigmond"
   password_file         = "/etc/sigmond/secrets/clickhouse-sigmond.pass"
   default_retention_days = 30
   per_mode_retention    = { wspr = 90, psk = 14, hfdl = 14, codar = 30, timestd = 60 }
   ```

3. **Apply schemas**: `sudo smd apply` now walks every installed
   client's `[clickhouse].schema_dir` (sigmond-clickhouse's
   vendored WSPR DDL, plus psk / hfdl / codar / timestd) and
   materialises the databases.

4. **Restart producer clients** so they re-read coordination.env
   and pick up `SIGMOND_CLICKHOUSE_URL`:
   ```
   sudo smd restart wsprdaemon-client psk-recorder hfdl-recorder \
                    codar-sounder hf-timestd
   ```

5. **Verify rows land**, after a few minutes per cadence:
   ```sql
   SELECT count() FROM wspr.spots     WHERE time > now() - INTERVAL 10 MINUTE;
   SELECT count() FROM psk.spots      WHERE time > now() - INTERVAL 5  MINUTE;
   SELECT count() FROM hfdl.spots     WHERE time > now() - INTERVAL 5  MINUTE;
   SELECT count() FROM codar.spots    WHERE time > now() - INTERVAL 5  MINUTE;
   SELECT count() FROM timestd.events WHERE time > now() - INTERVAL 5  MINUTE;
   ```

6. **WSPR wire-compat check** — for any `<rx_sign>` recently active
   on this station, the row count in local `wspr.spots` over a 10-
   minute window should equal the row count in wsprdaemon.org's
   central CH for the same window (modulo upload latency).  The
   `cityHash64` dedup id (`id` ALIAS column in wspr.spots) should
   be byte-identical for byte-identical input rows — that's the
   schema-vendoring proof.

7. **Operator-side compound-callsign verification** (psk-recorder
   v0.4.0): after a few hours of FT8 traffic, inspect
   `/var/lib/psk-recorder/<radiod>/callhash.json` to confirm
   compound callsigns have accumulated.  Spot-check a few
   `psk.spots` rows where the message contained `<K1ABC/QRP>`-type
   markers and confirm `tx_call` is plain `K1ABC/QRP` (no
   brackets).

## Out of scope (intentional)

- **`hs-uploader` library design** — sibling to `hamsci_ch`, designed
  separately.  This implementation enables it (per-mode DBs, schema
  versioning, `data_sinks` surface, accumulated callhash tables) but
  does not build it.  Plan forbids `shipped_at` columns or sidecar
  shipping tables in any per-mode table during phases A–D so the
  uploader can choose its own progress-tracking strategy later.
- **Production deployment** — every change in this implementation is
  additive.  The existing file/SFTP/PSKReporter/airframes paths are
  unaffected when `SIGMOND_CLICKHOUSE_URL` is unset.  Operators opt
  in by adding `[storage.clickhouse]` to coordination.toml.
- **WSJT-X hashtable.txt seeding** — `sigmond.callhash` accumulates
  the compound-callsign cache on the consumer side, which is enough
  for ChTailer to extract resolved calls.  A future enhancement
  would write WSJT-X's `~/.config/WSJT-X/hashtable.txt` from the
  accumulated cache so jt9's NEXT invocation can resolve hashes
  proactively (currently each jt9 starts with empty session state).
  Not in scope for this implementation.
