# Cloudflare Tunnel Setup

Bash scripts สำหรับตั้งค่า Cloudflare Tunnel บน Linux ที่ใช้ `systemd` รองรับ Debian/Ubuntu, Fedora/RHEL, Arch และ distribution อื่นที่ใช้ systemd โดยไม่ผูกกับ package manager ตัวใดตัวหนึ่ง

## ความสามารถ

- `setup-tunnel.sh` ใช้ `cloudflared` ที่ติดตั้งอยู่แล้ว หรือดาวน์โหลดไบนารีทางการของ Cloudflare หากยังไม่มี จากนั้นสร้างหรือใช้ Tunnel เดิม ตั้งค่า ingress สำหรับ 2 โดเมน และผูก DNS
- `setup-dynamic-tunnel.sh` เขียน ingress config ใหม่ตามจำนวนโดเมน/พอร์ตที่ระบุ สำรอง config เดิม ตรวจ config แล้วจึงนำไปใช้และ restart service

## รองรับระบบใดบ้าง

- Linux ที่บูตด้วย `systemd`
- CPU architecture: `x86_64`/`amd64`, `x86` 32-bit, `ARM64`/`aarch64` และ `ARMv6/ARMv7` ที่ Cloudflare มีไบนารีให้
- ต้องมี `curl` หรือ `wget` และเชื่อมต่ออินเทอร์เน็ตได้ หากเครื่องยังไม่มี `cloudflared`
- ต้องใช้สิทธิ์ `root` (เช่น `sudo -i`) เพราะสคริปต์สร้าง service และ config ใน `/etc`

สคริปต์ไม่ครอบคลุม Linux ที่ไม่มี systemd เช่น Alpine แบบ OpenRC, ระบบ container ที่ไม่มี systemd หรือ CPU architecture ที่ไม่มี cloudflared binary

## ติดตั้งและเริ่มใช้งาน

```bash
git clone https://github.com/saranse/cloudflare-tunnel-setup.git
cd cloudflare-tunnel-setup
chmod +x setup-tunnel.sh setup-dynamic-tunnel.sh
sudo ./setup-tunnel.sh
```

กรอกโดเมน 2 ชื่อ, พอร์ตภายในของแต่ละแอป และชื่อ Tunnel หากยังไม่ได้ login สคริปต์จะเรียก `cloudflared tunnel login` ให้ยืนยันบัญชี Cloudflare

หากขาด `curl` และ `wget` ให้ติดตั้งอย่างใดอย่างหนึ่งจาก package manager ของ distribution ก่อน ตัวอย่าง:

```bash
# Debian / Ubuntu
sudo apt install curl

# Fedora / RHEL
sudo dnf install curl

# Arch Linux
sudo pacman -S curl
```

## เพิ่มหรือแก้รายการโดเมนภายหลัง

```bash
sudo ./setup-dynamic-tunnel.sh
```

กรอก Tunnel ID จำนวนโดเมน แล้วกรอกโดเมนและพอร์ตของแต่ละรายการ สคริปต์จะสำรอง `/etc/cloudflared/config.yml` ก่อนเขียนไฟล์ใหม่ และตรวจ config ก่อน reload service

> สคริปต์ dynamic แทนที่ ingress config ทั้งไฟล์ด้วยรายการที่กรอก หากมี config เพิ่มเติมที่ต้องเก็บไว้ ให้รวมไว้ในรายการใหม่ก่อนดำเนินการ

## ตรวจสอบสถานะและ log

```bash
sudo systemctl status cloudflared --no-pager
sudo journalctl -u cloudflared -n 50 --no-pager
```

ไฟล์ config อยู่ที่ `/etc/cloudflared/config.yml` และ systemd unit อยู่ที่ `/etc/systemd/system/cloudflared.service`

## ความปลอดภัย

- ตรวจสอบสคริปต์และค่าที่จะใช้ก่อนรันด้วยสิทธิ์ root
- ห้าม commit `cert.pem`, credentials JSON, token หรือรหัสผ่านลง repository
- credentials อยู่ใน `/root/.cloudflared/`; ห้ามเปิดเผยหรืออัปโหลดไฟล์ดังกล่าว
- DNS route ต้องไม่ชนกับระเบียนเดิมใน Cloudflare
