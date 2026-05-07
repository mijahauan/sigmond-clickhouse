#!/usr/bin/env bash
# Standalone installer for sigmond-clickhouse.  Idempotent.  Uses the
# repo's deploy.toml as the source of truth for paths, which is also
# what `smd install clickhouse` reads — the two paths converge.
#
# This script is referenced by /etc/sigmond/catalog.toml's
# [client.clickhouse] install_script field.  Run as root.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="/opt/sigmond-clickhouse/venv"

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: $0 must run as root (try: sudo $0)" >&2
        exit 1
    fi
}

require_clickhouse_server() {
    if ! systemctl list-unit-files clickhouse-server.service >/dev/null 2>&1; then
        cat >&2 <<EOF
ERROR: clickhouse-server.service not installed.

  sigmond-clickhouse wraps the upstream Debian clickhouse-server package
  (we do not fork or replace it).  Install it first:

      sudo apt install clickhouse-server clickhouse-client

  Then re-run this script.
EOF
        exit 1
    fi
}

build_venv() {
    echo "==> building venv at $VENV"
    if [[ ! -d "$VENV" ]]; then
        python3 -m venv "$VENV"
    fi
    "$VENV/bin/pip" install --quiet --upgrade pip setuptools wheel
    "$VENV/bin/pip" install --quiet -e "$HERE"
}

link_binaries() {
    echo "==> linking sigmond-clickhouse → /usr/local/sbin"
    ln -sfn "$VENV/bin/sigmond-clickhouse" /usr/local/sbin/sigmond-clickhouse
}

install_systemd_unit() {
    echo "==> installing systemd unit"
    install -m 0644 "$HERE/systemd/sigmond-clickhouse.service" \
        /etc/systemd/system/sigmond-clickhouse.service
    systemctl daemon-reload
}

install_drop_in() {
    echo "==> installing clickhouse-server listen drop-in (loopback default)"
    mkdir -p /etc/clickhouse-server/config.d
    # Default render: loopback.  smd apply re-renders from coordination.env.
    cat > /etc/clickhouse-server/config.d/10-sigmond-listen.xml <<'EOF'
<?xml version="1.0"?>
<clickhouse>
    <listen_host>127.0.0.1</listen_host>
</clickhouse>
EOF
}

ensure_secrets_dir() {
    echo "==> ensuring /etc/sigmond/secrets/"
    mkdir -p /etc/sigmond/secrets
    chown sigmond:sigmond /etc/sigmond/secrets 2>/dev/null || true
    chmod 0750 /etc/sigmond/secrets
}

main() {
    require_root
    require_clickhouse_server
    build_venv
    link_binaries
    install_systemd_unit
    install_drop_in
    ensure_secrets_dir
    echo "==> sigmond-clickhouse installed."
    echo "    Next: enable [storage.clickhouse] in /etc/sigmond/coordination.toml,"
    echo "    then: sudo smd apply && sudo systemctl start sigmond-clickhouse"
}

main "$@"
