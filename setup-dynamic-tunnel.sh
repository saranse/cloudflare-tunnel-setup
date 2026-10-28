#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "กรุณารันด้วย root เช่น sudo ./setup-dynamic-tunnel.sh" >&2
  exit 1
fi
if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
  echo "สคริปต์นี้ต้องใช้ Linux ที่บูตด้วย systemd" >&2
  exit 1
fi
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "ไม่พบ cloudflared กรุณารัน setup-tunnel.sh ก่อน" >&2
  exit 1
fi

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}====================================================${NC}"
echo -e "${GREEN}   Cloudflare Tunnel Dynamic Config Generator${NC}"
echo -e "${CYAN}====================================================${NC}"

# 1. รับค่า Tunnel ID
read -e -p "กรอก Tunnel ID: " TUNNEL_ID

if [[ -z "$TUNNEL_ID" ]]; then
  echo -e "${YELLOW}✖ คุณไม่ได้กรอก Tunnel ID สคริปต์หยุดทำงาน${NC}"
  exit 1
fi
if ! [[ "$TUNNEL_ID" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]]; then
  echo "Tunnel ID ต้องอยู่ในรูปแบบ UUID เช่น 12345678-1234-1234-1234-123456789abc" >&2
  exit 1
fi

# 2. รับจำนวนโดเมนที่ต้องการ
read -e -p "จำนวนโดเมนที่ต้องการผูก (เช่น 1, 2, 3...): " DOMAIN_COUNT

if ! [[ "$DOMAIN_COUNT" =~ ^[0-9]+$ ]] || [[ "$DOMAIN_COUNT" -le 0 ]]; then
  echo -e "${YELLOW}✖ กรุณากรอกตัวเลขจำนวนเต็มที่มากกว่า 0${NC}"
  exit 1
fi
DOMAIN_COUNT=$((10#$DOMAIN_COUNT))
if (( DOMAIN_COUNT > 100 )); then
  echo "รองรับได้ไม่เกิน 100 โดเมนต่อการตั้งค่า" >&2
  exit 1
fi

# 3. วนลูปรับค่า โดเมน และ พอร์ต ตามจำนวนที่ระบุ
DOMAINS=()
PORTS=()

echo -e "\n${CYAN}--- กรุณากรอกข้อมูลโดเมนและพอร์ต ---${NC}"
for (( i=1; i<=DOMAIN_COUNT; i++ )); do
  read -e -p "โดเมนที่ $i (เช่น app$i.example.com): " domain
  read -e -p "พอร์ตของโดเมนที่ $i (เช่น 80, 8080): " port

  if ! [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || [[ "$domain" == .* || "$domain" == *..* || "$domain" == *. ]]; then
    echo "โดเมนไม่ถูกต้อง: $domain" >&2
    exit 1
  fi
  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
    echo "พอร์ตต้องเป็นตัวเลข 1-65535" >&2
    exit 1
  fi
  for existing in "${DOMAINS[@]:-}"; do
    if [[ "$existing" == "$domain" ]]; then
      echo "โดเมนซ้ำ: $domain" >&2
      exit 1
    fi
  done

  DOMAINS+=("$domain")
  PORTS+=("$port")
done

# 4. สำรอง config เก่า แล้วเตรียมไฟล์ใหม่แบบ atomic
CONFIG_DIR=/etc/cloudflared
CONFIG_FILE="$CONFIG_DIR/config.yml"
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
if [[ -f "$CONFIG_FILE" ]]; then
  backup="$CONFIG_FILE.$(date +%Y%m%d-%H%M%S).bak"
  cp -p "$CONFIG_FILE" "$backup"
  echo "สำรอง config เดิมไว้ที่ $backup"
fi
tmp_config="$(mktemp "$CONFIG_DIR/.config.yml.XXXXXX")"
trap 'rm -f "$tmp_config"' EXIT

# 5. สร้างไฟล์ config.yml แบบอัตโนมัติตามจำนวนโดเมน
echo -e "กำลังสร้างไฟล์ $CONFIG_FILE..."
{
  echo "tunnel: ${TUNNEL_ID}"
  echo "credentials-file: /root/.cloudflared/${TUNNEL_ID}.json"
  echo ""
  echo "ingress:"
  
  # วนลูปสร้างค่า ingress ให้ครบทุกโดเมน (Array เริ่มที่ index 0)
  for (( i=0; i<DOMAIN_COUNT; i++ )); do
    echo "  - hostname: ${DOMAINS[$i]}"
    echo "    service: http://localhost:${PORTS[$i]}"
  done
  
  echo "  - service: http_status:404"
} > "$tmp_config"
chmod 600 "$tmp_config"
cloudflared tunnel --config "$tmp_config" ingress validate
mv -f "$tmp_config" "$CONFIG_FILE"
trap - EXIT

# 6. รีสตาร์ท Service
echo -e "กำลังตรวจและรีสตาร์ท cloudflared service..."
systemctl restart cloudflared
systemctl --no-pager --full status cloudflared || true

# 7. วนลูปผูกโดเมน
echo -e "กำลังผูกโดเมนเข้ากับ Tunnel..."
for (( i=0; i<DOMAIN_COUNT; i++ )); do
  echo -e "   -> ผูกโดเมน: ${DOMAINS[$i]}"
  cloudflared tunnel route dns -f "${TUNNEL_ID}" "${DOMAINS[$i]}" || true
done

echo -e "\n${GREEN}ตั้งค่าเสร็จสมบูรณ์!${NC}"
echo -e "ตรวจสอบสถานะ Service: systemctl status cloudflared"
