-- sigmond-clickhouse: wspr.spots
--
-- VENDORED VERBATIM from wsprdaemon-server@374514ee
-- (wsprdaemon_server.py:286-333).  Modifying this DDL breaks
-- wire-compatibility with wsprdaemon.org's central CH instance.  See
-- SCHEMA_PROVENANCE for the update procedure.
--
-- Notes from upstream:
--   - azimuth/rx_azimuth are Int16 because -999 is the "no data"
--     sentinel; unsigned types would corrupt that value.
--   - id is an ALIAS (cityHash64) so wspr.rocks can run identical
--     SELECTs against wspr.rx and wsprdaemon.spots.
--   - ReplacingMergeTree so re-runs are idempotent.

CREATE TABLE IF NOT EXISTS wspr.spots
(
    time          DateTime                          CODEC(Delta(4), ZSTD(1)),
    band          Int16                             CODEC(T64, ZSTD(1)),
    rx_sign       LowCardinality(String)            CODEC(LZ4),
    rx_lat        Float32                           CODEC(Delta(4), ZSTD(3)),
    rx_lon        Float32                           CODEC(Delta(4), ZSTD(3)),
    rx_loc        LowCardinality(String)            CODEC(LZ4),
    tx_sign       LowCardinality(String)            CODEC(LZ4),
    tx_lat        Float32                           CODEC(Delta(4), ZSTD(3)),
    tx_lon        Float32                           CODEC(Delta(4), ZSTD(3)),
    tx_loc        LowCardinality(String)            CODEC(LZ4),
    distance      Int32                             CODEC(T64, ZSTD(1)),
    azimuth       Int16                             CODEC(T64, ZSTD(1)),
    rx_azimuth    Int16                             CODEC(T64, ZSTD(1)),
    frequency     UInt64                            CODEC(Delta(8), ZSTD(3)),
    power         Int8                              CODEC(T64, ZSTD(1)),
    snr           Int8                              CODEC(Delta(4), ZSTD(3)),
    drift         Int8                              CODEC(Delta(4), ZSTD(3)),
    version       LowCardinality(Nullable(String))  CODEC(LZ4),
    code          Int8                              CODEC(ZSTD(1)),
    frequency_mhz Float64                           CODEC(Delta(8), ZSTD(3)),
    rx_id         LowCardinality(String)            CODEC(LZ4),
    v_lat         Float32                           CODEC(Delta(4), ZSTD(3)),
    v_lon         Float32                           CODEC(Delta(4), ZSTD(3)),
    c2_noise      Float32                           CODEC(Delta(4), ZSTD(3)),
    sync_quality  UInt16                            CODEC(ZSTD(1)),
    dt            Float32                           CODEC(Delta(4), ZSTD(3)),
    decode_cycles UInt32                            CODEC(T64, ZSTD(1)),
    jitter        Int16                             CODEC(T64, ZSTD(1)),
    rms_noise     Float32                           CODEC(Delta(4), ZSTD(3)),
    blocksize     UInt16                            CODEC(T64, ZSTD(1)),
    metric        Int16                             CODEC(T64, ZSTD(1)),
    osd_decode    UInt8                             CODEC(T64, ZSTD(1)),
    nhardmin      UInt16                            CODEC(T64, ZSTD(1)),
    ipass         UInt8                             CODEC(T64, ZSTD(1)),
    proxy_upload  UInt8                             CODEC(T64, ZSTD(1)),
    ov_count      UInt32                            CODEC(T64, ZSTD(1)),
    rx_status     LowCardinality(String) DEFAULT 'No Info' CODEC(LZ4),
    band_m        Int16                             CODEC(T64, ZSTD(1)),
    id            UInt64 ALIAS cityHash64(rx_sign, tx_sign, band, rx_id, time, frequency)
)
ENGINE = ReplacingMergeTree()
PARTITION BY toYYYYMM(time)
ORDER BY (rx_sign, tx_sign, band, rx_id, time)
SETTINGS index_granularity = 32768, min_age_to_force_merge_seconds = 120;
