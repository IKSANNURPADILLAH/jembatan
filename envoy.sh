#!/usr/bin/env bash
set -euo pipefail

# =====================[ KONFIGURASI YANG BISA DIOPTIONKAN ]====================
LISTEN_PORT="${LISTEN_PORT:-80}"                             # port publik VPS
TARGET_HOST="${TARGET_HOST:-de.cortex.herominers.com}"       # host tujuan
TARGET_PORT="${TARGET_PORT:-1155}"                           # port tujuan
ENVOY_IMAGE="${ENVOY_IMAGE:-envoyproxy/envoy:v1.31-latest}"  # image Envoy
CONCURRENCY="${CONCURRENCY:-$(nproc)}"                       # worker = jumlah core
NOFILE_LIMIT="${NOFILE_LIMIT:-200000}"                       # ulimit FD untuk banyak koneksi
# Naikkan kapasitas conntrack (penting untuk koneksi bejibun). 524288 ~ 512k entri.
CONNTRACK_MAX="${CONNTRACK_MAX:-524288}"                     # contoh: 262144 / 524288 / 1048576
# ==============================================================================

require_root() {
  if [[ "$(id -u)" != "0" ]]; then
    echo "Jalankan sebagai root: sudo bash $0"; exit 1
  fi
}
pkg_install() {
  apt-get update -y
  apt-get install -y curl ca-certificates gnupg lsb-release
}
install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "==> Menginstal Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
  else
    echo "==> Docker sudah terpasang."
  fi
}
apply_sysctl() {
  echo "==> Menerapkan kernel/network tuning (TCP & buffers)..."
  cat >/etc/sysctl.d/99-envoy-highconn.conf <<'EOF'
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
  sysctl --system
}
apply_conntrack() {
  echo "==> Mengaktifkan & menaikkan nf_conntrack_max = ${CONNTRACK_MAX} ..."
  # load modul (biasanya sudah built-in, tapi aman kita panggil)
  modprobe nf_conntrack 2>/dev/null || true
  # set persist
  cat >/etc/sysctl.d/98-conntrack.conf <<EOF
net.netfilter.nf_conntrack_max = ${CONNTRACK_MAX}
EOF
  sysctl --system
}
apply_limits() {
  echo "==> Menaikkan limit file descriptor (nofile) ..."
  if ! grep -q "envoy-nofile.conf" /etc/security/limits.conf 2>/dev/null; then
    cat >>/etc/security/limits.conf <<EOF

# envoy-nofile.conf
* soft nofile ${NOFILE_LIMIT}
* hard nofile ${NOFILE_LIMIT}
root soft nofile ${NOFILE_LIMIT}
root hard nofile ${NOFILE_LIMIT}
EOF
  fi
}
write_envoy_yaml() {
  echo "==> Menulis /etc/envoy/envoy.yaml (mining mode: exact_balance + idle_timeout: 0s) ..."
  mkdir -p /etc/envoy
  cat >/etc/envoy/envoy.yaml <<EOF
static_resources:
  listeners:
  - name: listener_tcp_${LISTEN_PORT}
    address:
      socket_address:
        address: 0.0.0.0
        port_value: ${LISTEN_PORT}
    enable_reuse_port: true
    connection_balance_config:
      exact_balance: {}                 # distribusi koneksi merata antar worker
    filter_chains:
    - filters:
      - name: envoy.filters.network.tcp_proxy
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy
          stat_prefix: tcp_forward
          cluster: herominers_sg
          idle_timeout: 0s              # jangan putuskan koneksi mining yang idle lama
          max_connect_attempts: 3

  clusters:
  - name: herominers_sg
    type: STRICT_DNS
    connect_timeout: 1s
    lb_policy: ROUND_ROBIN
    circuit_breakers:
      thresholds:
      - priority: DEFAULT
        max_connections: 100000
    upstream_connection_options:
      tcp_keepalive: {}
    load_assignment:
      cluster_name: herominers_sg
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: ${TARGET_HOST}
                port_value: ${TARGET_PORT}

admin:
  address:
    socket_address:
      address: 127.0.0.1
      port_value: 9901
EOF
}
stop_web_servers_if_any() {
  # Hentikan web server umum di port 80 jika ada (opsional)
  systemctl stop nginx apache2 2>/dev/null || true
  systemctl disable nginx apache2 2>/dev/null || true
}
pull_image() {
  echo "==> Menarik image ${ENVOY_IMAGE} ..."
  docker pull "${ENVOY_IMAGE}"
}
write_systemd() {
  echo "==> Membuat systemd service: envoy-proxy.service ..."
  cat >/etc/systemd/system/envoy-proxy.service <<EOF
[Unit]
Description=Envoy TCP Proxy (:${LISTEN_PORT} -> ${TARGET_HOST}:${TARGET_PORT})
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=simple
Environment=CONTAINER_NAME=envoy-tcp${LISTEN_PORT}
Environment=ENVOY_IMAGE=${ENVOY_IMAGE}
Environment=LISTEN_PORT=${LISTEN_PORT}
Environment=NOFILE_LIMIT=${NOFILE_LIMIT}
Environment=CONCURRENCY=${CONCURRENCY}
# Hapus container lama bila ada
ExecStartPre=-/usr/bin/docker rm -f \${CONTAINER_NAME}
# Jalankan container (host network agar bisa bind port <1024)
ExecStart=/usr/bin/docker run \\
  --name \${CONTAINER_NAME} \\
  --ulimit nofile=\${NOFILE_LIMIT}:\${NOFILE_LIMIT} \\
  --network host \\
  -v /etc/envoy/envoy.yaml:/etc/envoy/envoy.yaml:ro \\
  -e ENVOY_UID=0 \\
  \${ENVOY_IMAGE} \\
  --concurrency \${CONCURRENCY} \\
  -c /etc/envoy/envoy.yaml
ExecStop=/usr/bin/docker stop \${CONTAINER_NAME}
Restart=always
RestartSec=2
LimitNOFILE=\${NOFILE_LIMIT}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now envoy-proxy.service
}
print_summary() {
  echo
  echo "=== SELESAI ==="
  echo "- Envoy listen :${LISTEN_PORT} -> ${TARGET_HOST}:${TARGET_PORT}"
  echo "- exact_balance aktif, idle_timeout: 0s (mining-friendly)"
  echo "- Conntrack max: ${CONNTRACK_MAX} (ubah via CONNTRACK_MAX=...)"
  echo "- Admin (lokal): curl 127.0.0.1:9901/stats"
  echo "- Status: systemctl status envoy-proxy.service --no-pager"
  echo "- Log   : journalctl -u envoy-proxy.service -f"
  echo
  ss -ltnp | grep ":${LISTEN_PORT}" || true
}

main() {
  require_root
  pkg_install
  install_docker
  apply_sysctl
  apply_conntrack
  apply_limits
  write_envoy_yaml
  stop_web_servers_if_any
  pull_image
  write_systemd
  print_summary
}

main "$@"
