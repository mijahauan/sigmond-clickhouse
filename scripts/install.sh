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

ensure_clickhouse_server() {
    # ClickHouse isn't in Debian's default repos — we have to add the
    # upstream APT source first.  Idempotent: every step short-circuits
    # when its artifact is already present, so re-running is a no-op
    # once installed.
    if systemctl list-unit-files clickhouse-server.service >/dev/null 2>&1; then
        return 0
    fi
    echo "==> clickhouse-server not installed; adding upstream APT repo"
    apt-get install -y -qq apt-transport-https ca-certificates curl gnupg \
        >/dev/null
    if [[ ! -s /usr/share/keyrings/clickhouse-keyring.gpg ]]; then
        curl -fsSL https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key \
            | gpg --batch --yes --dearmor \
              -o /usr/share/keyrings/clickhouse-keyring.gpg
        chmod 0644 /usr/share/keyrings/clickhouse-keyring.gpg
    fi
    if [[ ! -f /etc/apt/sources.list.d/clickhouse.list ]]; then
        echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg] \
https://packages.clickhouse.com/deb stable main" \
            > /etc/apt/sources.list.d/clickhouse.list
    fi
    apt-get update -qq
    # DEBIAN_FRONTEND=noninteractive: the clickhouse-server postinst
    # otherwise prompts for the default-user password through debconf
    # and hangs forever when stdin is closed (which it is when smd
    # invokes us under sudo).
    echo "==> installing clickhouse-server + clickhouse-client"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        clickhouse-server clickhouse-client >/dev/null
}

ensure_clickhouse_user() {
    # Generate a random password (saved at the path coordination.toml's
    # [storage.clickhouse].password_file points at) and create a
    # `sigmond` ClickHouse user with the privileges the schema migrator
    # needs.  Idempotent: skip everything when the password file is
    # already present (operator may have rotated it manually).
    local pw_file="/etc/sigmond/secrets/clickhouse-sigmond.pass"
    if [[ -s "$pw_file" ]]; then
        echo "==> $pw_file already populated; not regenerating"
        return 0
    fi
    echo "==> generating clickhouse-sigmond password + bootstrapping user"

    # Make sure clickhouse-server is up so we can talk to it.  systemd
    # may not have started it on a fresh install.  Brief retry covers
    # the ~1-2s the daemon needs to start accepting connections.
    systemctl is-active --quiet clickhouse-server.service \
        || systemctl start clickhouse-server.service
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        clickhouse-client --query "SELECT 1" >/dev/null 2>&1 && break
        sleep 1
    done

    local pw
    pw="$(openssl rand -hex 24)"
    umask 077
    printf '%s\n' "$pw" > "$pw_file"
    # Owned by sigmond, readable by the clickhouse group so the server
    # postinst's `clickhouse` user can read it for password-file auth
    # when we later switch to that mode.  Falls back to sigmond:sigmond
    # if the clickhouse group isn't present (rare; postinst creates it).
    if getent group clickhouse >/dev/null 2>&1; then
        chown sigmond:clickhouse "$pw_file" 2>/dev/null \
            || chown root:root "$pw_file"
    else
        chown sigmond:sigmond "$pw_file" 2>/dev/null \
            || chown root:root "$pw_file"
    fi
    chmod 0640 "$pw_file"

    # `GRANT ALL` requires WITH GRANT OPTION which the default user
    # lacks for some privileges (notably SHOW NAMED COLLECTIONS
    # SECRETS); enumerate the privileges schema migrations actually
    # need instead.
    clickhouse-client -q "
        CREATE USER IF NOT EXISTS sigmond IDENTIFIED WITH plaintext_password BY '$pw';
        GRANT CREATE, ALTER, DROP, SELECT, INSERT, OPTIMIZE ON *.* TO sigmond;
    " >/dev/null
    echo "==> sigmond user created in ClickHouse with required grants"
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
    ensure_clickhouse_server
    build_venv
    link_binaries
    install_systemd_unit
    install_drop_in
    ensure_secrets_dir
    ensure_clickhouse_user
    echo "==> sigmond-clickhouse installed."
    echo "    Next: enable [storage.clickhouse] in /etc/sigmond/coordination.toml,"
    echo "    then: sudo smd apply && sudo systemctl start sigmond-clickhouse"
}

main "$@"
