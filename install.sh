#!/usr/bin/env bash
# Muse CN 电脑底座 · 一键安装（v0.4.0）
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
Muse CN 电脑底座（musecn-pc）v0.4.0

纯 Python 标准库、零依赖的小服务，形态学 mac-hand：
- HTTP JSON 接口（状态 / 执行命令 / 读文件 / 长期记忆 / 电脑浏览器），令牌鉴权，无令牌一律拒绝
- UDP 广播发现：手机在同一局域网里能找到这台电脑
- 配对：服务启动时生成 6 位配对码（终端大字打印 + 写 ~/.musecn/pairing.txt），
  手机输码换长期令牌，配对只做一次，令牌落盘、重启不丢
- 长期记忆（v0.3 新增）：~/.musecn/memory/ 下两个文件——SOUL.md 是助手的
  「性格说明书」（用户可改），MEMORY.md 是蒸馏过的长期记忆条目（每行一条）。
  与聊天记录分工：记录是流水、留手机本地；这里存的是提炼后要长期用的。
- 电脑浏览器（v0.4 新增）：底座自带一个最小 CDP 驱动，驱动系统里的
  Chrome/Chromium（独立资料夹 ~/.musecn/browser-profile，不动用户自己的
  浏览器与登录态），给手机上的「脑」开页 / 读正文 / 点按钮 / 填表单 / 滚动。
  CDP 只绑 127.0.0.1。付款确认、密码框这类步骤不代办，明确回绝让用户本人来。

状态目录：~/.musecn/（state.json 存令牌与配对状态，权限 600）
监听：0.0.0.0:18790（HTTP），UDP 18791（发现）。可用环境变量 MUSECN_PORT 改 HTTP 端口。
"""

import atexit
import base64
import hashlib
import http.client
import json
import os
import platform
import secrets
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "0.4.0"
DEFAULT_PORT = int(os.environ.get("MUSECN_PORT", "18790"))
DISCOVERY_PORT = 18791
DISCOVERY_MAGIC = "MUSECN_DISCOVER_V1"

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(HOME, ".musecn")
STATE_FILE = os.path.join(STATE_DIR, "state.json")
PAIR_FILE = os.path.join(STATE_DIR, "pairing.txt")
MEMORY_DIR = os.path.join(STATE_DIR, "memory")
SOUL_FILE = os.path.join(MEMORY_DIR, "SOUL.md")
MEMORY_FILE = os.path.join(MEMORY_DIR, "MEMORY.md")

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


# ---------------- 长期记忆（SOUL + MEMORY） ----------------

DEFAULT_SOUL = """【先说清这一页】这是住在这台电脑里的助手 Muse CN 的「性格说明书」：它怎么说话、怎么做事，都照这里写的来。你把这里改了，它下次跟你说话就会照新的来。

# 我是谁

我是 Muse CN，住在你这台电脑里的助手。你在手机上给我下令，我在这台电脑上帮你干活，办完把结果带回来给你。

# 我怎么说话

- 说人话，说大白话，不绕弯子，不用你听不懂的词。
- 先说结果，再说细节；能一句话说清的，不说三句。
- 不说客套话，不拍马屁，也不用吓唬人的口气。
- 不确定的事就说不确定，不编。

# 我怎么做事

- 你交代的事，我先想清楚最短的路，再动手。
- 拿不准、怕弄坏的事，先问你再动。
- 办完事把结果说清楚：做了什么、成了没有、有什么要注意的。
- 值得长期记住的事，我会记到长期记忆里，下次不用你重复说。

（这一页是写给我的「性格说明书」，就放在你电脑里，你随时可以改——改成什么样，我就照着什么样来。）
"""

# MEMORY 文件的第一行固定是这句说明（以 # 开头，App 与系统提示都会跳过它、不当条目）
MEMORY_HEADER = "# 这是我的长期记忆：我记住的、以后还用得上的事都在这里，一行一条，前面带日期。你可以改、可以删——删掉哪条，我就忘掉哪条。"

MAX_MEMORY_CHARS = 200000  # SOUL / MEMORY 单个文件的写入上限（字数）

_memory_lock = threading.Lock()


def _atomic_write(path, text):
    """原子写：先把旧内容留一份 .bak，再写临时文件、改名替换，写一半断电也不坏。"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        try:
            shutil.copyfile(path, path + ".bak")
        except OSError:
            pass
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def ensure_memory():
    """首次启动时把记忆目录与两个文件建好；已有的内容一个字都不动。"""
    with _memory_lock:
        os.makedirs(MEMORY_DIR, exist_ok=True)
        if not os.path.exists(SOUL_FILE):
            _atomic_write(SOUL_FILE, DEFAULT_SOUL)
        if not os.path.exists(MEMORY_FILE):
            _atomic_write(MEMORY_FILE, MEMORY_HEADER + "\n")


def _read_text(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def memory_snapshot():
    ensure_memory()
    with _memory_lock:
        return _read_text(SOUL_FILE), _read_text(MEMORY_FILE)


def memory_save_soul(text):
    ensure_memory()
    with _memory_lock:
        _atomic_write(SOUL_FILE, text)


def memory_replace(text):
    ensure_memory()
    with _memory_lock:
        _atomic_write(MEMORY_FILE, text)


def memory_append(entry):
    """追加一条记忆：一事一条、占一行，统一成「- 日期 内容」的样子
    （条目内部的换行压成空格，保证按行可删；日期取这台电脑的当天）。"""
    import datetime
    core = " ".join(str(entry or "").split())
    if core.startswith("- "):
        core = core[2:].lstrip()
    if not core:
        return False
    line = "- %s %s" % (datetime.date.today().isoformat(), core)
    ensure_memory()
    with _memory_lock:
        current = _read_text(MEMORY_FILE)
        if current and not current.endswith("\n"):
            current += "\n"
        _atomic_write(MEMORY_FILE, current + line + "\n")
    return True


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


# ---------------- 电脑浏览器（v0.4 新增） ----------------
#
# 底座自带的最小 CDP 驱动：找系统里的 Chrome/Chromium，用独立资料夹
# ~/.musecn/browser-profile 启动（不动用户自己的浏览器与登录态），
# CDP 只绑 127.0.0.1。WebSocket 客户端是纯标准库手写的最小实现。
# 边界：付款确认按钮不点、密码框不填——明确回 refused，让用户本人来。

BROWSER_PROFILE_DIR = os.path.join(STATE_DIR, "browser-profile")
BROWSER_LOG = os.path.join(STATE_DIR, "browser.log")
BROWSER_BIN_NAMES = [
    "google-chrome", "google-chrome-stable",
    "chromium", "chromium-browser", "chromium-browser-stable",
]
MAX_PAGE_TEXT = 12000  # 读正文截断上限

# 页面正文提取：标题 / 网址 / 正文 / 有没有密码框（手机侧同名标记、同形状）
_JS_EXTRACT = r"""(() => { /*MUSECN_EXTRACT*/
  const body = document.body;
  const text = body ? (body.innerText || '') : '';
  return {
    url: location.href,
    title: document.title || '',
    text: text.slice(0, 12000),
    hasPassword: !!document.querySelector('input[type="password"]')
  };
})()"""

# 按可见文字点击：完全相等优先，其次开头对上、其次包含；付款确认类按钮回绝
_JS_CLICK = r"""(() => { /*MUSECN_CLICK*/
  const target = __MUSECN_TARGET__;
  const payRe = /确认付款|确认支付|立即付款|立即支付|付款确认|pay now|confirm payment/i;
  const norm = (s) => (s || '').replace(/\s+/g, ' ').trim();
  const visible = (el) => {
    if (!el.getClientRects || el.getClientRects().length === 0) return false;
    const st = window.getComputedStyle(el);
    return st.visibility !== 'hidden' && st.display !== 'none';
  };
  const label = (el) => norm(el.innerText || el.value || el.getAttribute('aria-label') || '');
  const sels = 'a, button, input[type="submit"], input[type="button"], [role="button"]';
  const els = Array.from(document.querySelectorAll(sels)).filter(visible);
  let best = null, bestScore = -1;
  for (const el of els) {
    const lab = label(el);
    if (!lab) continue;
    let score = -1;
    if (lab === target) score = 1000 - lab.length;
    else if (lab.startsWith(target)) score = 500 - lab.length;
    else if (lab.includes(target)) score = 100 - lab.length;
    if (score > bestScore) { bestScore = score; best = el; }
  }
  if (!best) return { ok: false, refused: null, text: '' };
  const lab = label(best);
  if (payRe.test(lab)) return { ok: false, refused: 'pay', text: lab };
  best.scrollIntoView({ block: 'center' });
  best.click();
  return { ok: true, refused: null, text: lab };
})()"""

# 按字段提示填字：用原生 setter 写值再补 input/change 事件（框架表单才认）；
# 密码框回绝；给了提示却找不到字段时报 notfound，不乱填第一个
_JS_FILL = r"""(() => { /*MUSECN_FILL*/
  const hint = __MUSECN_HINT__;
  const value = __MUSECN_VALUE__;
  const norm = (s) => (s || '').replace(/\s+/g, ' ').trim().toLowerCase();
  const visible = (el) => {
    if (!el.getClientRects || el.getClientRects().length === 0) return false;
    const st = window.getComputedStyle(el);
    return st.visibility !== 'hidden' && st.display !== 'none';
  };
  const labelOf = (el) => {
    const parts = [el.getAttribute('placeholder'), el.getAttribute('name'), el.getAttribute('id'), el.getAttribute('aria-label')];
    if (el.labels) { for (const l of el.labels) parts.push(l.innerText); }
    return norm(parts.filter(Boolean).join(' '));
  };
  const badTypes = ['hidden', 'submit', 'button', 'checkbox', 'radio', 'file'];
  const els = Array.from(document.querySelectorAll('input, textarea')).filter((el) => {
    const t = (el.getAttribute('type') || 'text').toLowerCase();
    return visible(el) && badTypes.indexOf(t) < 0;
  });
  let best = null;
  if (hint) {
    const h = norm(hint);
    best = els.find((el) => labelOf(el).includes(h)) || null;
    if (!best) return { ok: false, refused: null, notfound: true, value: '', type: '' };
  } else if (els.length > 0) {
    best = els[0];
  }
  if (!best) return { ok: false, refused: null, notfound: true, value: '', type: '' };
  const type = (best.getAttribute('type') || 'text').toLowerCase();
  if (type === 'password') return { ok: false, refused: 'password', notfound: false, value: '', type: type };
  const proto = best.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
  const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
  setter.call(best, value);
  best.dispatchEvent(new Event('input', { bubbles: true }));
  best.dispatchEvent(new Event('change', { bubbles: true }));
  return { ok: true, refused: null, notfound: false, value: best.value, type: type };
})()"""

_JS_SCROLL = r"""(() => { /*MUSECN_SCROLL*/
  const dir = __MUSECN_DIR__;
  const dy = Math.floor(window.innerHeight * 0.85) * (dir === 'up' ? -1 : 1);
  window.scrollBy(0, dy);
  return { y: window.scrollY };
})()"""


class BrowserError(Exception):
    """浏览器层错误：message 是给人看的大白话。"""


def find_browser_binary():
    for name in BROWSER_BIN_NAMES:
        path = shutil.which(name)
        if path:
            return path
    return None


class _WsClient:
    """最小 WebSocket 客户端（RFC 6455）：只做 CDP 需要的文本消息收发。"""

    def __init__(self, url, timeout=15):
        parsed = urllib.parse.urlparse(url)
        self.host = parsed.hostname or "127.0.0.1"
        self.port = parsed.port or 80
        path = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query
        self.sock = socket.create_connection((self.host, self.port), timeout=timeout)
        self.sock.settimeout(timeout)
        self._buf = b""
        key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
        req = (
            "GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n"
            % (path, self.host, self.port, key)
        )
        self.sock.sendall(req.encode("ascii"))
        head = self._read_until(b"\r\n\r\n").decode("iso-8859-1", errors="replace")
        if " 101" not in head.split("\r\n", 1)[0]:
            raise BrowserError("浏览器调试通道没连上。")
        expect = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
        ).decode("ascii")
        if expect not in head:
            raise BrowserError("浏览器调试通道握手对不上。")

    def _read_until(self, marker):
        while marker not in self._buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise BrowserError("浏览器调试通道断了。")
            self._buf += chunk
        idx = self._buf.index(marker) + len(marker)
        out, self._buf = self._buf[:idx], self._buf[idx:]
        return out

    def _read_exact(self, n):
        while len(self._buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise BrowserError("浏览器调试通道断了。")
            self._buf += chunk
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def send_text(self, text):
        data = text.encode("utf-8")
        mask = secrets.token_bytes(4)
        header = bytearray([0x81])
        n = len(data)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        self.sock.sendall(bytes(header) + mask + masked)

    def _send_pong(self, data):
        mask = secrets.token_bytes(4)
        body = data[:125]
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(body))
        self.sock.sendall(bytes([0x8A, 0x80 | len(masked)]) + mask + masked)

    def recv_text(self):
        payload = b""
        while True:
            h = self._read_exact(2)
            fin = h[0] & 0x80
            opcode = h[0] & 0x0F
            masked = h[1] & 0x80
            length = h[1] & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read_exact(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read_exact(8))[0]
            mask = self._read_exact(4) if masked else None
            data = self._read_exact(length) if length else b""
            if mask:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            if opcode == 0x8:
                raise BrowserError("浏览器把调试通道关了。")
            if opcode == 0x9:
                self._send_pong(data)
                continue
            if opcode in (0x0, 0x1, 0x2):
                payload += data
                if fin:
                    return payload.decode("utf-8", errors="replace")

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class PcBrowser:
    """底座自带的浏览器：懒启动、单实例、操作串行；动作后回读验证状态。"""

    def __init__(self):
        self.lock = threading.Lock()
        self.proc = None
        self.port = None
        self.ws = None
        self.msg_id = 0

    # ---- 进程与连接管理 ----

    def _http_json(self, method, path, timeout=5):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=timeout)
        try:
            conn.request(method, path)
            resp = conn.getresponse()
            raw = resp.read()
            if resp.status >= 400:
                raise BrowserError("浏览器调试接口回了 %d。" % resp.status)
            return json.loads(raw.decode("utf-8", errors="replace") or "{}")
        finally:
            conn.close()

    def _port_alive(self, port):
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            conn.request("GET", "/json/version")
            resp = conn.getresponse()
            resp.read()
            return resp.status == 200
        except Exception:
            return False

    def _read_active_port(self):
        try:
            with open(os.path.join(BROWSER_PROFILE_DIR, "DevToolsActivePort"),
                      "r", encoding="utf-8") as f:
                return int(f.read().splitlines()[0].strip())
        except Exception:
            return None

    def _launch(self, binary):
        os.makedirs(BROWSER_PROFILE_DIR, exist_ok=True)
        args = [
            binary,
            "--user-data-dir=" + BROWSER_PROFILE_DIR,
            "--remote-debugging-address=127.0.0.1",
            "--remote-debugging-port=0",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-dev-shm-usage",
            "--disable-gpu",
            "--window-size=1280,900",
        ]
        if not os.environ.get("DISPLAY"):
            args.append("--headless=new")
        if hasattr(os, "geteuid") and os.geteuid() == 0:
            args.append("--no-sandbox")
        args.append("about:blank")
        log = open(BROWSER_LOG, "ab")
        self.proc = subprocess.Popen(args, stdout=log, stderr=log, start_new_session=True)
        deadline = time.time() + 20
        while time.time() < deadline:
            port = self._read_active_port()
            if port and self._port_alive(port):
                self.port = port
                return
            if self.proc.poll() is not None:
                break
            time.sleep(0.25)
        raise BrowserError("浏览器启动失败，看日志：~/.musecn/browser.log")

    def _connect(self):
        targets = self._http_json("GET", "/json/list")
        page = None
        if isinstance(targets, list):
            for t in targets:
                if isinstance(t, dict) and t.get("type") == "page" and t.get("webSocketDebuggerUrl"):
                    page = t
                    break
        if page is None:
            created = self._http_json("PUT", "/json/new?about:blank")
            if isinstance(created, dict) and created.get("webSocketDebuggerUrl"):
                page = created
        if page is None:
            raise BrowserError("浏览器里没有可用的页面。")
        self.ws = _WsClient(page["webSocketDebuggerUrl"])
        self.msg_id = 0

    def ensure(self):
        if self.ws is not None and self.port and self._port_alive(self.port):
            return
        self._drop_connection()
        binary = find_browser_binary()
        if not binary:
            raise BrowserError("这台电脑上没找到能用的浏览器（Chrome 或 Chromium），先装一个浏览器再试。")
        port = self._read_active_port()
        if port and self._port_alive(port):
            self.port = port  # 复用还活着的旧实例（底座重启过、浏览器没关）
        else:
            self._launch(binary)
        self._connect()

    def _drop_connection(self):
        if self.ws is not None:
            self.ws.close()
            self.ws = None

    def shutdown(self):
        self._drop_connection()
        if self.proc is not None and self.proc.poll() is None:
            try:
                self.proc.terminate()
            except Exception:
                pass
        self.proc = None

    # ---- CDP 调用 ----

    def call(self, method, params=None):
        if self.ws is None:
            raise BrowserError("浏览器还没连上。")
        self.msg_id += 1
        mid = self.msg_id
        try:
            self.ws.send_text(json.dumps({"id": mid, "method": method, "params": params or {}}))
            while True:
                msg = json.loads(self.ws.recv_text())
                if msg.get("id") != mid:
                    continue  # 事件通知，跳过
                if "error" in msg:
                    raise BrowserError("浏览器执行这一步时出错了。")
                return msg.get("result") or {}
        except BrowserError:
            raise
        except Exception:
            self._drop_connection()
            raise BrowserError("浏览器没回话，可能已经关了，下一步会自动重开。")

    def evaluate(self, expr):
        result = self.call("Runtime.evaluate", {
            "expression": expr,
            "returnByValue": True,
            "awaitPromise": True,
        })
        if result.get("exceptionDetails"):
            raise BrowserError("页面里的脚本出错了，这一步没做成。")
        inner = result.get("result") or {}
        return inner.get("value")

    def _wait_ready(self, timeout=10):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                if self.evaluate("document.readyState") in ("complete", "interactive"):
                    return
            except BrowserError:
                pass
            time.sleep(0.2)

    def extract(self):
        value = self.evaluate(_JS_EXTRACT)
        if not isinstance(value, dict):
            raise BrowserError("没读到页面内容。")
        return {
            "url": str(value.get("url") or ""),
            "title": str(value.get("title") or ""),
            "text": str(value.get("text") or "")[:MAX_PAGE_TEXT],
            "has_password": bool(value.get("hasPassword")),
        }

    # ---- 对外操作（端点调用，自带锁串行） ----

    def open(self, url):
        with self.lock:
            self.ensure()
            self.call("Page.enable")
            self.call("Page.navigate", {"url": url})
            self._wait_ready()
            return self.extract()

    def read(self):
        with self.lock:
            self.ensure()
            return self.extract()

    def click(self, text):
        with self.lock:
            self.ensure()
            expr = _JS_CLICK.replace("__MUSECN_TARGET__", json.dumps(text, ensure_ascii=False))
            value = self.evaluate(expr)
            if not isinstance(value, dict):
                raise BrowserError("点击这一步没做成。")
            if value.get("ok"):
                time.sleep(0.5)
                self._wait_ready(timeout=5)
            return {
                "clicked": bool(value.get("ok")),
                "refused": value.get("refused"),
                "clicked_text": str(value.get("text") or ""),
                "page": self.extract(),
            }

    def fill(self, field, text):
        with self.lock:
            self.ensure()
            expr = (_JS_FILL
                    .replace("__MUSECN_HINT__", json.dumps(field, ensure_ascii=False))
                    .replace("__MUSECN_VALUE__", json.dumps(text, ensure_ascii=False)))
            value = self.evaluate(expr)
            if not isinstance(value, dict):
                raise BrowserError("填表这一步没做成。")
            return {
                "filled": bool(value.get("ok")),
                "refused": value.get("refused"),
                "notfound": bool(value.get("notfound")),
                "value": str(value.get("value") or ""),
                "field_type": str(value.get("type") or ""),
            }

    def scroll(self, direction):
        with self.lock:
            self.ensure()
            self.evaluate(_JS_SCROLL.replace("__MUSECN_DIR__", json.dumps(direction)))
            time.sleep(0.3)
            return {"page": self.extract()}


BROWSER = PcBrowser()


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
            binary = find_browser_binary()
            payload["browser_available"] = binary is not None
            payload["browser_binary"] = os.path.basename(binary) if binary else None
            self._send_json(200, payload)
            return
        if self.path == "/memory":
            if not self._authed():
                return self._deny()
            soul, memory = memory_snapshot()
            self._send_json(200, {"ok": True, "soul": soul, "memory": memory})
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
        if self.path == "/browser/open":
            body = self._read_body()
            url = str(body.get("url") or "").strip()
            if not url:
                self._send_json(400, {"ok": False, "error": "没给要打开的网址。"})
                return
            if "://" not in url:
                url = "https://" + url
            try:
                payload = {"ok": True}
                payload.update(BROWSER.open(url))
            except BrowserError as e:
                payload = {"ok": False, "error": str(e)}
            self._send_json(200, payload)
            return
        if self.path == "/browser/read":
            try:
                payload = {"ok": True}
                payload.update(BROWSER.read())
            except BrowserError as e:
                payload = {"ok": False, "error": str(e)}
            self._send_json(200, payload)
            return
        if self.path == "/browser/click":
            body = self._read_body()
            text = str(body.get("text") or "").strip()
            if not text:
                self._send_json(400, {"ok": False, "error": "没给要点哪个按钮（写着什么字）。"})
                return
            try:
                payload = {"ok": True}
                payload.update(BROWSER.click(text))
            except BrowserError as e:
                payload = {"ok": False, "error": str(e)}
            self._send_json(200, payload)
            return
        if self.path == "/browser/fill":
            body = self._read_body()
            field = str(body.get("field") or "").strip()
            text = str(body.get("text") or "")
            try:
                payload = {"ok": True}
                payload.update(BROWSER.fill(field, text))
            except BrowserError as e:
                payload = {"ok": False, "error": str(e)}
            self._send_json(200, payload)
            return
        if self.path == "/browser/scroll":
            body = self._read_body()
            direction = "up" if str(body.get("direction") or "").lower() == "up" else "down"
            try:
                payload = {"ok": True}
                payload.update(BROWSER.scroll(direction))
            except BrowserError as e:
                payload = {"ok": False, "error": str(e)}
            self._send_json(200, payload)
            return
        if self.path == "/memory/soul":
            body = self._read_body()
            text = body.get("soul")
            if not isinstance(text, str):
                self._send_json(400, {"ok": False, "error": "没给要保存的内容。"})
                return
            if len(text) > MAX_MEMORY_CHARS:
                self._send_json(413, {"ok": False, "error": "内容太长了，超过 %d 字。" % MAX_MEMORY_CHARS})
                return
            memory_save_soul(text)
            self._send_json(200, {"ok": True})
            return
        if self.path == "/memory/append":
            body = self._read_body()
            text = str(body.get("text") or "")
            if len(text) > MAX_MEMORY_CHARS:
                self._send_json(413, {"ok": False, "error": "这一条太长了，超过 %d 字。" % MAX_MEMORY_CHARS})
                return
            if not memory_append(text):
                self._send_json(400, {"ok": False, "error": "这条是空的，没记成。"})
                return
            self._send_json(200, {"ok": True})
            return
        if self.path == "/memory/replace":
            body = self._read_body()
            text = body.get("memory")
            if not isinstance(text, str):
                self._send_json(400, {"ok": False, "error": "没给要保存的内容。"})
                return
            if len(text) > MAX_MEMORY_CHARS:
                self._send_json(413, {"ok": False, "error": "内容太长了，超过 %d 字。" % MAX_MEMORY_CHARS})
                return
            memory_replace(text)
            self._send_json(200, {"ok": True})
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
    ensure_memory()
    atexit.register(BROWSER.shutdown)
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
