#!/usr/bin/env bash
# Muse CN 电脑底座 · 一键安装（v0.2.0）
# 在 Ubuntu / Debian 电脑上粘贴运行：
#   curl -fsSL https://raw.githubusercontent.com/zhangweiy77/muse-cn-releases/main/install.sh | bash
# 做四件事：把底座程序放进 ~/.musecn、设成开机自启的常驻服务、启动它、打印 6 位配对码。
# 重复运行 = 升级并重启服务，已配对的令牌不会丢、不用重新配对。
set -uo pipefail

DIR="$HOME/.musecn"
PORT="${MUSECN_PORT:-18790}"
say() { printf '%s\n' "$*"; }
fail() { say "没装成：$*"; exit 1; }

# ---------- 1. 确保 python3 在 ----------
if ! command -v python3 >/dev/null 2>&1; then
    say "这台电脑还没装 Python3，试着自动装一下…"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq && sudo apt-get install -y -qq python3 || true
    fi
fi
command -v python3 >/dev/null 2>&1 || fail "自动安装 Python3 没成功。请先手动运行：sudo apt install python3 ，装好后把这条命令再粘一次。"

mkdir -p "$DIR" || fail "建不了目录 $DIR"

# ---------- 2. 落底座程序 ----------
cat > "$DIR/musecn_pc.py" <<'MUSECN_PC_PY_EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Muse CN 电脑底座（musecn-pc）v0.2.0

纯 Python 标准库、零依赖的小服务，形态学 mac-hand：
- HTTP JSON 接口（状态 / 执行命令 / 读文件），令牌鉴权，无令牌一律拒绝
- UDP 广播发现：手机在同一局域网里能找到这台电脑
- 配对：服务启动时生成 6 位配对码（终端大字打印 + 写 ~/.musecn/pairing.txt），
  手机输码换长期令牌，配对只做一次，令牌落盘、重启不丢

状态目录：~/.musecn/（state.json 存令牌与配对状态，权限 600）
监听：0.0.0.0:18790（HTTP），UDP 18791（发现）。可用环境变量 MUSECN_PORT 改 HTTP 端口。
"""

import json
import os
import platform
import secrets
import shutil
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "0.2.0"
DEFAULT_PORT = int(os.environ.get("MUSECN_PORT", "18790"))
DISCOVERY_PORT = 18791
DISCOVERY_MAGIC = "MUSECN_DISCOVER_V1"

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(HOME, ".musecn")
STATE_FILE = os.path.join(STATE_DIR, "state.json")
PAIR_FILE = os.path.join(STATE_DIR, "pairing.txt")

MAX_OUTPUT_CHARS = 8000       # 命令输出截断上限（单流）
MAX_READ_CHARS = 16000        # 读文件截断上限
MAX_RUN_TIMEOUT = 120         # 命令超时上限（秒）
MAX_PAIR_ATTEMPTS = 10        # 配对码输错次数上限，超了换新码

# ---------------- 大字渲染（3x5 点阵） ----------------

_FONT = {
    "0": ["###", "# #", "# #", "# #", "###"],
    "1": [" # ", "## ", " # ", " # ", "###"],
    "2": ["###", "  #", "###", "#  ", "###"],
    "3": ["###", "  #", "###", "  #", "###"],
    "4": ["# #", "# #", "###", "  #", "  #"],
    "5": ["###", "#  ", "###", "  #", "###"],
    "6": ["###", "#  ", "###", "# #", "###"],
    "7": ["###", "  #", "  #", " # ", " # "],
    "8": ["###", "# #", "###", "# #", "###"],
    "9": ["###", "# #", "###", "  #", "###"],
}


def big_text(text):
    lines = []
    for row in range(5):
        cells = []
        for ch in text:
            glyph = _FONT.get(ch, ["   "] * 5)[row]
            cells.append("".join("██" if c == "#" else "  " for c in glyph))
        lines.append("  ".join(cells))
    return "\n".join(lines)


# ---------------- 状态与配对 ----------------


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.token = ""
        self.paired = False
        self.pair_code = ""
        self.pair_attempts = 0
        self._load()
        if not self.paired:
            self._new_pair_code(save=False)
        self._save()

    def _load(self):
        try:
            with open(STATE_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
            self.token = str(data.get("token", ""))
            self.paired = bool(data.get("paired", False))
        except Exception:
            self.token = ""
            self.paired = False
        if not self.token:
            self.token = secrets.token_urlsafe(32)
            self.paired = False

    def _save(self):
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"token": self.token, "paired": self.paired}, f)
        os.chmod(tmp, 0o600)
        os.replace(tmp, STATE_FILE)

    def _new_pair_code(self, save=True):
        self.pair_code = "%06d" % secrets.randbelow(1000000)
        self.pair_attempts = 0
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(PAIR_FILE, "w", encoding="utf-8") as f:
            f.write(self.pair_code + "\n")
        os.chmod(PAIR_FILE, 0o600)
        if save:
            self._save()

    def try_pair(self, code):
        """返回 (ok, message)。"""
        with self.lock:
            if self.paired:
                return False, "这台电脑已经配对过了，不用再配。"
            if self.pair_attempts >= MAX_PAIR_ATTEMPTS:
                self._new_pair_code()
                print_pair_banner("配对码输错太多次，已换新码：")
                return False, "输错太多次，电脑上已经换了一个新配对码，看电脑屏幕输入新码。"
            if secrets.compare_digest(str(code or "").strip(), self.pair_code):
                self.paired = True
                self._save()
                try:
                    os.remove(PAIR_FILE)
                except OSError:
                    pass
                return True, ""
            self.pair_attempts += 1
            left = MAX_PAIR_ATTEMPTS - self.pair_attempts
            return False, "配对码不对，再对着电脑屏幕核对一下（还能试 %d 次）。" % left

    def check_token(self, provided):
        return bool(provided) and secrets.compare_digest(provided, self.token)


STATE = None  # 在 main 里初始化


def print_pair_banner(prefix="配对码（在手机 App 的「电脑」页输入它）："):
    print("", flush=True)
    print("=" * 56, flush=True)
    print(prefix, flush=True)
    print(big_text(STATE.pair_code), flush=True)
    print("配对码：%s" % STATE.pair_code, flush=True)
    print("=" * 56, flush=True)
    print("", flush=True)


# ---------------- 系统信息 ----------------


def os_pretty_name():
    try:
        with open("/etc/os-release", "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("PRETTY_NAME="):
                    return line.split("=", 1)[1].strip().strip('"')
    except Exception:
        pass
    return "%s %s" % (platform.system(), platform.release())


def lan_ips():
    ips = []
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if not ip.startswith("127.") and ip not in ips:
                ips.append(ip)
    except Exception:
        pass
    return ips


def collect_status():
    mem_total = mem_avail = None
    try:
        info = {}
        with open("/proc/meminfo", "r", encoding="utf-8") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2:
                    info[parts[0].rstrip(":")] = int(parts[1]) * 1024
        mem_total = info.get("MemTotal")
        mem_avail = info.get("MemAvailable")
    except Exception:
        pass
    uptime = None
    try:
        with open("/proc/uptime", "r", encoding="utf-8") as f:
            uptime = float(f.read().split()[0])
    except Exception:
        pass
    disk = shutil.disk_usage(HOME)
    return {
        "name": socket.gethostname(),
        "os": os_pretty_name(),
        "kernel": platform.release(),
        "arch": platform.machine(),
        "uptime_seconds": uptime,
        "mem_total_bytes": mem_total,
        "mem_available_bytes": mem_avail,
        "disk_total_bytes": disk.total,
        "disk_free_bytes": disk.free,
        "home": HOME,
        "service_version": VERSION,
    }


# ---------------- 工具实现 ----------------


def run_command(command, timeout):
    timeout = max(1, min(int(timeout or 30), MAX_RUN_TIMEOUT))
    proc = subprocess.Popen(
        ["/bin/bash", "-c", command],
        cwd=HOME,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    timed_out = False
    try:
        out_b, err_b = proc.communicate(timeout=timeout)
        exit_code = proc.returncode
    except subprocess.TimeoutExpired:
        timed_out = True
        exit_code = None
        try:
            os.killpg(os.getpgid(proc.pid), 9)
        except Exception:
            pass
        out_b, err_b = proc.communicate()
    out = out_b.decode("utf-8", errors="replace")
    err = err_b.decode("utf-8", errors="replace")
    return {
        "exit_code": exit_code,
        "timed_out": timed_out,
        "stdout": out[:MAX_OUTPUT_CHARS],
        "stderr": err[:MAX_OUTPUT_CHARS],
        "truncated": len(out) > MAX_OUTPUT_CHARS or len(err) > MAX_OUTPUT_CHARS,
    }


def read_path(raw_path):
    """只许读家目录内。返回 (http_code, payload)。"""
    if not raw_path:
        return 400, {"ok": False, "error": "没给路径。"}
    path = os.path.realpath(os.path.expanduser(raw_path))
    home_real = os.path.realpath(HOME)
    if path != home_real and not path.startswith(home_real + os.sep):
        return 403, {"ok": False, "error": "只能读家目录里的文件，这个路径在外面。"}
    if not os.path.exists(path):
        return 404, {"ok": False, "error": "这个文件或文件夹不存在。"}
    if os.path.isdir(path):
        entries = []
        try:
            names = sorted(os.listdir(path))
        except OSError as e:
            return 403, {"ok": False, "error": "打不开这个文件夹：%s" % e}
        for name in names[:200]:
            full = os.path.join(path, name)
            try:
                size = os.path.getsize(full) if os.path.isfile(full) else None
            except OSError:
                size = None
            entries.append({
                "name": name,
                "type": "dir" if os.path.isdir(full) else "file",
                "size": size,
            })
        return 200, {"ok": True, "path": path, "type": "dir", "entries": entries}
    # 文件：先探二进制
    try:
        with open(path, "rb") as f:
            raw = f.read(MAX_READ_CHARS * 2 + 4096)
    except OSError as e:
        return 403, {"ok": False, "error": "读不了这个文件：%s" % e}
    if b"\x00" in raw[:1024]:
        return 415, {"ok": False, "error": "这是一个二进制文件（图片/程序之类），没法当文字读。"}
    text = raw.decode("utf-8", errors="replace")
    return 200, {
        "ok": True,
        "path": path,
        "type": "file",
        "content": text[:MAX_READ_CHARS],
        "truncated": len(text) > MAX_READ_CHARS,
    }


# ---------------- HTTP 接口 ----------------


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "musecn-pc/" + VERSION

    def log_message(self, fmt, *args):  # 只记路径与状态，不记令牌与正文
        sys.stderr.write("[musecn-pc] %s %s\n" % (self.command, self.path))

    def _send_json(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        raw = self.rfile.read(length) if length > 0 else b""
        try:
            return json.loads(raw.decode("utf-8")) if raw else {}
        except Exception:
            return {}

    def _authed(self):
        auth = self.headers.get("Authorization") or ""
        token = auth[7:] if auth.startswith("Bearer ") else (self.headers.get("X-MuseCN-Token") or "")
        return STATE.check_token(token.strip())

    def _deny(self):
        self._send_json(401, {"ok": False, "error": "没有令牌或令牌不对，拒绝执行。"})

    def do_GET(self):
        if self.path == "/health":
            self._send_json(200, {
                "ok": True,
                "app": "musecn-pc",
                "name": socket.gethostname(),
                "os": os_pretty_name(),
                "version": VERSION,
                "paired": STATE.paired,
            })
            return
        if self.path == "/status":
            if not self._authed():
                return self._deny()
            payload = {"ok": True}
            payload.update(collect_status())
            self._send_json(200, payload)
            return
        self._send_json(404, {"ok": False, "error": "没有这个接口。"})

    def do_POST(self):
        if self.path == "/pair":
            body = self._read_body()
            ok, msg = STATE.try_pair(body.get("code"))
            if ok:
                self._send_json(200, {
                    "ok": True,
                    "token": STATE.token,
                    "name": socket.gethostname(),
                    "os": os_pretty_name(),
                })
            else:
                self._send_json(403, {"ok": False, "error": msg})
            return
        if not self._authed():
            return self._deny()
        if self.path == "/run":
            body = self._read_body()
            command = str(body.get("command") or "").strip()
            if not command:
                self._send_json(400, {"ok": False, "error": "没给要运行的命令。"})
                return
            result = {"ok": True}
            result.update(run_command(command, body.get("timeout")))
            self._send_json(200, result)
            return
        if self.path == "/read":
            body = self._read_body()
            code, payload = read_path(str(body.get("path") or ""))
            self._send_json(code, payload)
            return
        self._send_json(404, {"ok": False, "error": "没有这个接口。"})


# ---------------- UDP 发现 ----------------


def discovery_loop(http_port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    except OSError:
        pass
    sock.bind(("", DISCOVERY_PORT))
    while True:
        try:
            data, addr = sock.recvfrom(2048)
        except OSError:
            continue
        if data.decode("utf-8", errors="ignore").strip().startswith(DISCOVERY_MAGIC):
            reply = json.dumps({
                "app": "musecn-pc",
                "name": socket.gethostname(),
                "os": os_pretty_name(),
                "http_port": http_port,
                "version": VERSION,
            }).encode("utf-8")
            try:
                sock.sendto(reply, addr)
            except OSError:
                pass


def main():
    global STATE
    port = DEFAULT_PORT
    if len(sys.argv) > 2 and sys.argv[1] == "--port":
        port = int(sys.argv[2])
    STATE = State()
    threading.Thread(target=discovery_loop, args=(port,), daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print("Muse CN 电脑底座已启动（版本 %s）" % VERSION, flush=True)
    print("电脑名：%s，系统：%s" % (socket.gethostname(), os_pretty_name()), flush=True)
    ips = lan_ips()
    if ips:
        print("局域网地址：%s（端口 %d）" % ("、".join(ips), port), flush=True)
    if STATE.paired:
        print("这台电脑已经和手机配对过了，手机可以直接下令，不用再配对。", flush=True)
    else:
        print_pair_banner()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
MUSECN_PC_PY_EOF
chmod 600 "$DIR/musecn_pc.py"

cat > "$DIR/start.sh" <<EOF2
#!/bin/sh
# Muse CN 电脑底座启动脚本（安装器生成）
exec /usr/bin/env python3 "$DIR/musecn_pc.py"
EOF2
chmod +x "$DIR/start.sh"

# ---------- 3. 停旧实例 ----------
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user stop musecn.service >/dev/null 2>&1 || true
fi
pkill -f "musecn_pc[.]py" >/dev/null 2>&1 || true
sleep 1

# ---------- 4. 常驻：优先 systemd 用户服务，否则 nohup + 开机自启 ----------
USE_SYSTEMD=0
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    USE_SYSTEMD=1
fi

if [ "$USE_SYSTEMD" = "1" ]; then
    UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/musecn.service" <<EOF3
[Unit]
Description=Muse CN PC base (musecn-pc)
After=network.target

[Service]
ExecStart=/usr/bin/env python3 $DIR/musecn_pc.py
WorkingDirectory=$DIR
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF3
    systemctl --user daemon-reload || fail "systemd 配置重载失败。"
    systemctl --user enable --now musecn.service || fail "服务启动失败。用 systemctl --user status musecn.service 看原因。"
    # 让服务在未登录时也能开机自启（需要一次 sudo，失败不拦路）
    loginctl enable-linger "${USER:-$(id -un)}" >/dev/null 2>&1 || sudo -n loginctl enable-linger "${USER:-$(id -un)}" >/dev/null 2>&1 || true
    say "已设成系统服务：开机自启、崩了自动拉起。"
else
    nohup "$DIR/start.sh" >> "$DIR/service.log" 2>&1 &
    if command -v crontab >/dev/null 2>&1; then
        ( crontab -l 2>/dev/null | grep -v "musecn_pc" || true
          echo "@reboot $DIR/start.sh >> $DIR/service.log 2>&1" ) | crontab - || true
    fi
    say "已在后台启动（这台机器没有可用的 systemd 用户服务，用了降级常驻方式）。"
fi

# ---------- 5. 等它活过来 ----------
OK=0
for i in $(seq 1 30); do
    if python3 - "$PORT" <<'PYEOF'
import sys, urllib.request
try:
    urllib.request.urlopen("http://127.0.0.1:%s/health" % sys.argv[1], timeout=2)
    sys.exit(0)
except Exception:
    sys.exit(1)
PYEOF
    then OK=1; break; fi
    sleep 0.5
done
[ "$OK" = "1" ] || fail "服务没起来。看日志找原因：$DIR/service.log 或 systemctl --user status musecn.service"

# ---------- 6. 报告：配对码大字打印 ----------
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
say ""
say "=================================================="
say "Muse CN 电脑底座装好了，正在运行。"
[ -n "$IP" ] && say "这台电脑的局域网地址：$IP"
if [ -f "$DIR/pairing.txt" ]; then
    say ""
    say "下一步：打开手机上的 Muse CN App →「电脑」页 → 点「查找家里的电脑」，"
    say "然后把下面这个 6 位配对码输进去（只输这一次，以后自动连）："
    say ""
    python3 - "$DIR/pairing.txt" <<'PYEOF'
import sys
FONT = {
    "0": ["###", "# #", "# #", "# #", "###"], "1": [" # ", "## ", " # ", " # ", "###"],
    "2": ["###", "  #", "###", "#  ", "###"], "3": ["###", "  #", "###", "  #", "###"],
    "4": ["# #", "# #", "###", "  #", "  #"], "5": ["###", "#  ", "###", "  #", "###"],
    "6": ["###", "#  ", "###", "# #", "###"], "7": ["###", "  #", "  #", " # ", " # "],
    "8": ["###", "# #", "###", "# #", "###"], "9": ["###", "# #", "###", "  #", "###"],
}
code = open(sys.argv[1], encoding="utf-8").read().strip()
for row in range(5):
    cells = []
    for ch in code:
        glyph = FONT.get(ch, ["   "] * 5)[row]
        cells.append("".join("██" if c == "#" else "  " for c in glyph))
    print("  ".join(cells))
print("")
print("配对码：" + code)
PYEOF
else
    say ""
    say "这台电脑之前已经和手机配对过了，不用再输配对码，手机可以直接下令。"
fi
say "=================================================="
