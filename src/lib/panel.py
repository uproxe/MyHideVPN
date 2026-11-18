#!/usr/bin/env python3
# Мини-панель vless-setup. Слушает ТОЛЬКО 127.0.0.1 — открывается через SSH-туннель:
#   ssh -L 8088:127.0.0.1:8088 root@СЕРВЕР   →   http://localhost:8088
import html, json, os, re, socket, subprocess, sys, tempfile, time, uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, quote

CFG = json.load(open(sys.argv[1] if len(sys.argv) > 1 else "/root/.vless-setup/panel.json"))
XDIR, STATE = CFG["xdir"], CFG["state_dir"]
XRAY, XCONF = os.path.join(XDIR, "xray"), os.path.join(XDIR, "config.json")
ENVFILE = os.path.join(STATE, CFG.get("env_file", "ru.env"))
CONN_PORT = int(CFG.get("conn_port", 443))
ENV = dict(os.environ, XRAY_LOCATION_ASSET=XDIR)


def sh(cmd, timeout=40):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=ENV)
        return p.returncode, (p.stdout + p.stderr).strip()
    except Exception as e:  # noqa
        return 1, str(e)


def keys():
    d = {}
    for line in open(ENVFILE):
        if "=" in line:
            k, v = line.strip().split("=", 1)
            d[k] = v
    return d


def cur_uuid():
    return json.load(open(XCONF))["inbounds"][0]["settings"]["clients"][0]["id"]


def link(uid=None):
    k = keys()
    return ("vless://%s@%s:%d?encryption=none&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s"
            "&type=xhttp&path=%s&mode=auto#%s") % (
        uid or cur_uuid(), CFG["srv_ip"], CONN_PORT, CFG["srv_domain"], CFG["fp"], k["K_PUB"], k["K_SID"],
        quote(k["K_PATH"], safe=""), CFG.get("link_tag", "vless"))


def active(unit):
    return sh(["systemctl", "is-active", unit])[1].splitlines()[-1:] == ["active"]


def rotate():
    new = str(uuid.uuid4())
    conf = json.load(open(XCONF))
    conf["inbounds"][0]["settings"]["clients"][0]["id"] = new
    tmp = os.path.join(XDIR, "config.new.json")
    with open(tmp, "w") as f:
        json.dump(conf, f, ensure_ascii=False, indent=2)
    rc, out = sh([XRAY, "run", "-test", "-config", tmp])
    if rc != 0:
        os.unlink(tmp)
        return "Xray не принял новый конфиг:\n" + out[-600:]
    st = os.stat(XCONF)
    os.chown(tmp, st.st_uid, st.st_gid)
    os.chmod(tmp, st.st_mode & 0o777)
    os.replace(tmp, XCONF)
    txt = re.sub(r"(?m)^K_UUID=.*$", "K_UUID=" + new, open(ENVFILE).read())
    open(ENVFILE, "w").write(txt)
    open(os.path.join(STATE, "link.txt"), "w").write(link(new) + "\n")
    sh(["systemctl", "restart", "vless-xray"])
    return "Готово: UUID заменён, старая ссылка больше не работает. Новая ссылка — выше."


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def chain_test():
    k, port = keys(), free_port()
    conf = {
        "log": {"loglevel": "warning"},
        "inbounds": [{"listen": "127.0.0.1", "port": port, "protocol": "socks", "settings": {"udp": False}}],
        "outbounds": [{
            "protocol": "vless",
            "settings": {"vnext": [{"address": "127.0.0.1", "port": CONN_PORT,
                                    "users": [{"id": cur_uuid(), "encryption": "none"}]}]},
            "streamSettings": {
                "network": "xhttp", "security": "reality",
                "realitySettings": {"serverName": CFG["srv_domain"], "fingerprint": CFG["fp"],
                                    "publicKey": k["K_PUB"], "shortId": k["K_SID"]},
                "xhttpSettings": {"path": k["K_PATH"], "mode": "auto"}}}]}
    fd, path = tempfile.mkstemp(suffix=".json")
    with os.fdopen(fd, "w") as f:
        json.dump(conf, f)
    proc = subprocess.Popen([XRAY, "run", "-config", path], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, env=ENV)
    lines = []
    warp_mode = CFG.get("exit_mode") == "warp"
    srv_ip = CFG["srv_ip"]
    relay_ip = CFG.get("relay_ip", "")
    try:
        time.sleep(2.5)
        px = ["curl", "-s", "--max-time", "25", "--socks5-hostname", "127.0.0.1:%d" % port]
        rc, out = sh(px + ["https://www.cloudflare.com/cdn-cgi/trace"])
        ip = re.search(r"(?m)^ip=(.+)$", out)
        warp = re.search(r"(?m)^warp=(.+)$", out)
        if not ip:
            lines.append("✗ Зарубежный сайт через VPN НЕ открылся. Если серверов два — проверь, не заблокирован ли IP второго сервера.")
        else:
            ipv = ip.group(1)
            lines.append("Зарубежные сайты видят адрес: %s (warp=%s)" % (ipv, warp.group(1) if warp else "?"))
            if warp_mode and ipv == srv_ip:
                lines.append("✗ Выход идёт с IP этого сервера — WARP не работает, адрес сервера светится.")
            elif relay_ip and warp_mode and ipv == relay_ip:
                lines.append("✗ Выход идёт с IP второго сервера — WARP не работает, его адрес светится.")
            elif not warp_mode and ipv == srv_ip and not relay_ip:
                lines.append("✓ Выход с IP сервера (режим direct, так и задумано).")
            else:
                lines.append("✓ Вход и выход — разные адреса.")
        rc, out = sh(px + ["-A", "curl", "https://2ip.ru"])
        out = out.strip()
        if out == srv_ip:
            lines.append("✓ Российские сайты видят адрес сервера-входа: " + out)
        elif out:
            lines.append("? Выход для рунета: ожидался %s, получено «%s»" % (srv_ip, out[:60]))
    finally:
        proc.terminate()
        try:
            proc.wait(5)
        except Exception:  # noqa
            proc.kill()
        os.unlink(path)
    return "\n".join(lines)


PAGE = """<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>VLESS — панель</title>
<style>
body{font-family:system-ui,sans-serif;max-width:46rem;margin:1.5rem auto;padding:0 1rem;color:#1c1c1c;background:#f6f6f4}
h1{font-size:1.2rem} .card{background:#fff;border:1px solid #ddd;border-radius:10px;padding:1rem;margin:1rem 0}
textarea{width:100%%;height:6.5rem;font:12px ui-monospace,monospace;box-sizing:border-box}
button{padding:.55rem .9rem;border-radius:8px;border:1px solid #888;background:#fff;cursor:pointer;margin:.2rem .3rem .2rem 0}
button.warn{border-color:#b33;color:#b33} .ok{color:#17803d} .bad{color:#b3261e}
pre{white-space:pre-wrap;background:#f0f0ee;padding:.7rem;border-radius:8px} td{padding:.15rem .8rem .15rem 0}
small{color:#666}
</style></head><body>
<h1>%(scheme)s</h1>
%(msg)s
<div class="card"><b>Ссылка</b><br><textarea id="l" readonly>%(link)s</textarea>
<button onclick="navigator.clipboard.writeText(document.getElementById('l').value);this.textContent='Скопировано'">Скопировать</button></div>
<div class="card"><b>Состояние</b><table>
<tr><td>Xray</td><td>%(xray)s</td></tr><tr><td>nginx (сайт-заглушка)</td><td>%(nginx)s</td></tr>
<tr><td>Версия</td><td>%(ver)s</td></tr><tr><td>Вход</td><td>%(srv_ip)s · %(srv_domain)s · порт %(conn_port)s</td></tr>
%(hop2_row)s</table></div>
<div class="card"><form method="post" action="/do">
<input type="hidden" name="t" value="%(token)s">
<button name="a" value="test">Проверить VPN</button>
<button name="a" value="restart">Перезапустить Xray</button>
<button name="a" value="log">Последние строки лога</button>
<button class="warn" name="a" value="rotate" onclick="return confirm('Старая ссылка перестанет работать. Продолжить?')">Сменить UUID (новая ссылка)</button>
</form><small>Проверка занимает до минуты.</small></div>
<small>Панель доступна только через SSH-туннель и наружу не открыта.</small>
</body></html>"""


def badge(ok):
    return '<span class="ok">работает</span>' if ok else '<span class="bad">не работает</span>'


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def page(self, msg=""):
        exit_lbl = "WARP" if CFG.get("exit_mode") == "warp" else "прямой выход"
        relay_ip = CFG.get("relay_ip", "")
        hop2_row = ""
        if relay_ip:
            hop2_row = "<tr><td>Второй сервер</td><td>%s · %s</td></tr>" % (
                html.escape(relay_ip), html.escape(CFG.get("relay_domain", "")))
        body = (PAGE % dict(
            scheme=html.escape(CFG.get("scheme_label", "VLESS") + " → " + exit_lbl),
            msg=('<div class="card"><pre>%s</pre></div>' % html.escape(msg)) if msg else "",
            link=html.escape(link()), xray=badge(active("vless-xray")), nginx=badge(active("nginx")),
            ver=html.escape(sh([XRAY, "version"])[1].splitlines()[0] if os.path.exists(XRAY) else "?"),
            srv_ip=html.escape(CFG["srv_ip"]), srv_domain=html.escape(CFG["srv_domain"]),
            conn_port=CONN_PORT, hop2_row=hop2_row, token=CFG["token"])).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/":
            self.page()
        else:
            self.send_error(404)

    def do_POST(self):
        host = (self.headers.get("Host") or "").split(":")[0]
        q = parse_qs(self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode())
        if self.path != "/do" or host not in ("localhost", "127.0.0.1") or q.get("t", [""])[0] != CFG["token"]:
            self.send_error(403)
            return
        a = q.get("a", [""])[0]
        if a == "restart":
            rc, out = sh(["systemctl", "restart", "vless-xray"])
            time.sleep(2)
            msg = "Xray перезапущен." if active("vless-xray") else "Xray не запустился:\n" + out
        elif a == "rotate":
            msg = rotate()
        elif a == "test":
            msg = chain_test()
        elif a == "log":
            msg = sh(["journalctl", "-u", "vless-xray", "-n", "40", "--no-pager"])[1]
        else:
            msg = ""
        self.page(msg)


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(CFG["port"])), H).serve_forever()
