-- sigmond-clickhouse: wspr.noise
--
-- VENDORED VERBATIM from wsprdaemon-server@374514ee
-- (wsprdaemon_server.py:344-360).  See SCHEMA_PROVENANCE.
--
-- Notes from upstream:
--   site     = rx callsign from RX_SITE directory  (e.g. AC0G/ND)
--   receiver = rx device from RECEIVER directory   (e.g. KA9Q_DXE)
--   rx_loc   = Maidenhead grid from RX_SITE suffix (e.g. EN16ov)
--   band     = band string from BAND directory     (e.g. '17', '60eu')

CREATE TABLE IF NOT EXISTS wspr.noise
(
    time       DateTime                CODEC(Delta(4), ZSTD(1)),
    site       LowCardinality(String)  CODEC(LZ4),
    receiver   LowCardinality(String)  CODEC(LZ4),
    rx_loc     LowCardinality(String)  CODEC(LZ4),
    band       LowCardinality(String)  CODEC(LZ4),
    rms_level  Float32                 CODEC(Delta(4), ZSTD(3)),
    c2_level   Float32                 CODEC(Delta(4), ZSTD(3)),
    ov         Int32                   CODEC(T64, ZSTD(1))
)
ENGINE = ReplacingMergeTree()
PARTITION BY toYYYYMM(time)
ORDER BY (time, site, receiver, band)
SETTINGS index_granularity = 8192;
