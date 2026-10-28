#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
err()  { echo -e "${RED}$*${NC}"; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    err "✖ กรุณารันเป็น root (เช่น sudo -i แล้วรันใหม่)"
    exit 1
  fi
}

install_cloudflared() {
  if need_cmd cloudflared; then
    log "✔ พบ cloudflared แล้ว: $(cloudflared --version | head -n 1)"
    return
  fi

  local arch downloader url tmp_file
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    i386|i486|i586|i686|x86) arch=386 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7l|armv6l|arm) arch=arm ;;
    *) err "✖ ไม่รองรับสถาปัตยกรรม: $(uname -m)"; exit 1 ;;
  esac

  if need_cmd curl; then
    downloader=curl
  elif need_cmd wget; then
    downloader=wget
  else
    err "✖ ต้องมี curl หรือ wget ก่อนติดตั้ง cloudflared (ติดตั้งด้วย package manager ของ Linux ที่ใช้)"
    exit 1
  fi

  log "⚙ ดาวน์โหลด cloudflared สำหรับ Linux/${arch} จาก Cloudflare..."
  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"' RETURN
  if [[ "$downloader" == curl ]]; then
    curl --fail --silent --show-error --location "$url" --output "$tmp_file"
  else
    wget --https-only --quiet "$url" --output-document="$tmp_file"
  fi

  install -m 0755 "$tmp_file" /usr/local/bin/cloudflared
  hash -r

  log "✔ ติดตั้งเสร็จ: $(cloudflared --version | head -n 1)"
}

ensure_login_cert() {
  log "ตรวจสอบ Cloudflare login cert..."
  if [[ -f /root/.cloudflared/cert.pem ]]; then
    log "✔ พบ /root/.cloudflared/cert.pem แล้ว -> ข้าม tunnel login"
  else
    warn "⚠ ยังไม่มี cert.pem -> จะเปิด login"
    cloudflared tunnel login
    log "✔ Login สำเร็จ (cert.pem ถูกดาวน์โหลดแล้ว)"
  fi
}

get_tunnel_id_by_name() {
  local name="$1"
  cloudflared tunnel list 2>/dev/null | awk -v n="$name" '$2==n {print $1; exit}'
}

create_or_reuse_tunnel() {
  local name="$1"
  local existing_id=""
  existing_id="$(get_tunnel_id_by_name "$name" || true)"

  if [[ -n "$existing_id" ]]; then
    warn "ℹ Tunnel name '$name' มีอยู่แล้ว -> ใช้ของเดิม: $existing_id" >&2
    echo "$existing_id"
    return
  fi

  log "สร้าง Tunnel: $name"
  cloudflared tunnel create "$name" >/dev/null

  local new_id=""
  new_id="$(get_tunnel_id_by_name "$name" || true)"
  if [[ -z "$new_id" ]]; then
    err "✖ สร้าง tunnel แล้วแต่หา Tunnel ID ไม่เจอ"
    cloudflared tunnel list || true
    exit 1
  fi

  log "✔ Created tunnel id: $new_id" >&2
  echo "$new_id"
}

ensure_credentials_file() {
  local tunnel_id="$1"
  local cred="/root/.cloudflared/${tunnel_id}.json"

  if [[ -f "$cred" ]]; then
    echo "$cred"
    return
  fi

  local maybe
  maybe="$(ls -1 /root/.cloudflared/*.json 2>/dev/null | grep -F "$tunnel_id" || true)"
  if [[ -n "$maybe" && -f "$maybe" ]]; then
    echo "$maybe"
    return
  fi

  err "✖ ไม่พบ credentials file: $cred"
  exit 1
}

write_config() {
  local tunnel_id="$1"
  local cred_path="$2"
  local domain1="$3"
  local port1="$4"
  local domain2="$5"
  local port2="$6"

  log "เขียน /etc/cloudflared/config.yml (รองรับ 2 โดเมน)"
  mkdir -p /etc/cloudflared

  cat >/etc/cloudflared/config.yml <<CONFIG_EOF
tunnel: ${tunnel_id}
credentials-file: ${cred_path}

ingress:
  - hostname: ${domain1}
    service: http://localhost:${port1}
  - hostname: ${domain2}
    service: http://localhost:${port2}
  - service: http_status:404
CONFIG_EOF
}

install_systemd_service() {
  local cloudflared_bin
  cloudflared_bin="$(command -v cloudflared)"
  log "ติดตั้ง systemd service cloudflared"
  cat >/etc/systemd/system/cloudflared.service <<'SERVICE_EOF'
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=__CLOUDFLARED_BIN__ --config /etc/cloudflared/config.yml tunnel run
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
SERVICE_EOF
  sed -i "s|__CLOUDFLARED_BIN__|${cloudflared_bin}|" /etc/systemd/system/cloudflared.service

  systemctl daemon-reload
  systemctl enable --now cloudflared
  log "✔ service started"
}

route_dns_with_fix() {
  local tunnel_id="$1"
  local domain="$2"

  log "ผูกโดเมน ${domain} -> tunnel ${tunnel_id}"
  set +e
  local out
  out="$(cloudflared tunnel route dns "$tunnel_id" "$domain" 2>&1)"
  local rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    log "✔ Route DNS สำเร็จ"
    return 0
  fi

  if echo "$out" | grep -q "code: 1003"; then
    warn "⚠ DNS ชน (code 1003): มี A/AAAA/CNAME ชื่อ ${domain} อยู่แล้วในระบบ Cloudflare"
    warn ">> กรุณาเข้าไปลบในหน้าจัดการ DNS ของ Cloudflare แล้วรันสคริปต์นี้อีกครั้ง"
    return 1
  fi

  err "✖ Route DNS ไม่สำเร็จ:"
  err "$out"
  return 1
}

main() {
  require_root
  if ! need_cmd systemctl || [[ ! -d /run/systemd/system ]]; then
    err "✖ สคริปต์นี้ต้องใช้ Linux ที่บูตด้วย systemd"
    exit 1
  fi
  install_cloudflared

  log "Cloudflare Tunnel Setup Script (Linux/systemd) - รองรับ 2 โดเมน"
  
  read -rp "Domain 1 (เช่น app1.example.com): " DOMAIN1
  read -rp "Local Port 1 (เช่น 5678): " PORT1
  
  read -rp "Domain 2 (เช่น app2.example.com): " DOMAIN2
  read -rp "Local Port 2 (เช่น 8080): " PORT2
  
  read -rp "Tunnel Name (เช่น my-server-tunnel): " TUNNEL_NAME

  if [[ -z "$DOMAIN1" || -z "$PORT1" || -z "$DOMAIN2" || -z "$PORT2" || -z "$TUNNEL_NAME" ]]; then
    err "✖ กรอกข้อมูลไม่ครบ"
    exit 1
  fi
  for domain in "$DOMAIN1" "$DOMAIN2"; do
    if ! [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || [[ "$domain" == .* || "$domain" == *..* || "$domain" == *. ]]; then
      err "✖ โดเมนไม่ถูกต้อง: $domain"
      exit 1
    fi
  done
  for port in "$PORT1" "$PORT2"; do
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
      err "✖ พอร์ตต้องเป็นตัวเลข 1-65535"
      exit 1
    fi
  done
  if [[ "$DOMAIN1" == "$DOMAIN2" ]] || ! [[ "$TUNNEL_NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
    err "✖ โดเมนต้องไม่ซ้ำ และชื่อ Tunnel ใช้ได้เฉพาะ A-Z, a-z, 0-9, _ และ -"
    exit 1
  fi

  ensure_login_cert

  local TUNNEL_ID
  TUNNEL_ID="$(create_or_reuse_tunnel "$TUNNEL_NAME")"

  local CRED_PATH
  CRED_PATH="$(ensure_credentials_file "$TUNNEL_ID")"

  write_config "$TUNNEL_ID" "$CRED_PATH" "$DOMAIN1" "$PORT1" "$DOMAIN2" "$PORT2"
  install_systemd_service

  route_dns_with_fix "$TUNNEL_ID" "$DOMAIN1" || true
  route_dns_with_fix "$TUNNEL_ID" "$DOMAIN2" || true

  log "เสร็จสิ้น!"
  echo "URL 1: https://${DOMAIN1} -> localhost:${PORT1}"
  echo "URL 2: https://${DOMAIN2} -> localhost:${PORT2}"
  echo "Tunnel ID: ${TUNNEL_ID}"
}

main "$@"
