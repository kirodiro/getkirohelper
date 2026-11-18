#!/usr/bin/env bash
# Kiros helper: move the bot onto its own server (Ubuntu 22.04 or 24.04, e.g. Amazon Lightsail in Ohio, next to Kalshi).
# Run it in the server's terminal:   curl -fsSL https://getkirohelper.com/server_setup.sh -o setup.sh && bash setup.sh
# What it does:
#   1. installs Python and what the bot needs (in its own folder, ~/kiros),
#   2. opens a one-time upload page so you can send your bot folder from your phone (an encrypted https page with a secret link; it closes itself after the upload),
#   3. runs the bot as a service: it starts by itself when the server boots and restarts if it ever stops.
# It never prints your keys or tokens. Run it again any time to upload newer files (it keeps everything that is already there).
set -euo pipefail

DIR="${KIROS_DIR:-$HOME/kiros}"
PORT="${KIROS_PORT:-80}"                # https on port 80: Lightsail's firewall already allows it, nothing to open
TEST="${KIROS_TEST:-0}"            # 1 = only the upload page and the unpacking (no installs, no service), for testing
SVC="kiros-bot"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

mkdir -p "$DIR"
cd "$DIR"

if [ "$TEST" != "1" ]; then
  say "1/3  Installing Python and the tools the bot needs (takes a minute or two)..."
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 python3-venv python3-pip unzip openssl chrony fonts-dejavu-core >/dev/null
  sudo systemctl enable --now chrony >/dev/null 2>&1 || true        # an exact clock: Kalshi refuses signed requests from a clock that is off
  if [ ! -x "$DIR/venv/bin/python" ]; then
    python3 -m venv "$DIR/venv"
  fi
  "$DIR/venv/bin/pip" install -q --upgrade pip
  "$DIR/venv/bin/pip" install -q "requests>=2.31" "Pillow>=10.1" "discord.py>=2.3" tzdata "cryptography>=42"
  echo "Done."
fi

# ---------------------------------------------------------------- 2. the one-time upload page
say "2/3  Upload your bot folder"
TOKEN="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 22)"
CERT="$DIR/.upload_cert.pem"; KEY="$DIR/.upload_key.pem"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=kiros-upload" -keyout "$KEY" -out "$CERT" >/dev/null 2>&1
IP="${KIROS_IP:-$(curl -fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null || hostname -I | awk '{print $1}')}"
IP="$(echo "$IP" | tr -d '[:space:]')"
if [ "$PORT" = "443" ]; then URL="https://$IP/$TOKEN"; else URL="https://$IP:$PORT/$TOKEN"; fi
cat <<EOF

On SillyDev: open your server's Files, select every file (kalshi15_bot.py, config.json, vault_key.pem, the .json files...), choose Archive,
then download the archive to your phone.

Now open this link on your phone (copy it exactly):

    $URL

Your browser will warn that the page "isn't private" or the certificate isn't trusted: that is expected for this one-time page
(it is still encrypted). Tap "Advanced" / "Show details", then "Proceed" / "visit this website".
Pick the archive (or several single files) and tap Upload. This page closes itself after the upload.
(If the link doesn't load at all, the server's firewall blocks port $PORT: allow it in your provider's Networking/Firewall page and try again.)

Waiting for the upload...
EOF

SUDO=""
if [ "$PORT" -lt 1024 ] && [ "$(id -u)" != "0" ]; then SUDO="sudo"; fi
$SUDO python3 - "$DIR" "$PORT" "$TOKEN" "$CERT" "$KEY" "$(id -u)" "$(id -g)" <<'PYEOF'
import http.server, io, os, ssl, sys, tarfile, zipfile, threading
from email.parser import BytesParser
from email.policy import default as email_policy
folder, port, token, cert, key, uid, gid = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6]), int(sys.argv[7])
DONE = threading.Event()
PAGE = """<!doctype html><meta name=viewport content="width=device-width,initial-scale=1"><title>Upload the bot</title>
<body style="font:17px system-ui;margin:24px;max-width:560px"><h2>Upload your bot folder</h2>
<p>Pick the archive you downloaded from SillyDev (.zip or .tar.gz), or several single files.</p>
<form method=post enctype=multipart/form-data><input type=file name=f multiple style="font-size:17px"><br><br>
<button style="font-size:18px;padding:10px 22px">Upload</button></form>"""


def safe(name):
    parts = [p for p in name.replace("\\", "/").split("/") if p not in ("", ".")]
    if not parts or ".." in parts or any(p in ("venv", "__pycache__") for p in parts) or parts[-1].startswith(".upload_"):
        return None
    return os.path.join(folder, *parts)


def put(name, data, saved):
    path = safe(name)
    if not path:
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)
    os.chmod(path, 0o600 if name.endswith((".pem", ".json", ".key")) else 0o644)
    saved.append(os.path.relpath(path, folder))


def root_of(names):
    """The folder inside the archive that holds the bot (so 'myserver/kalshi15_bot.py' lands as 'kalshi15_bot.py')."""
    for n in names:
        if n.replace("\\", "/").split("/")[-1] == "kalshi15_bot.py":
            return n[: len(n) - len("kalshi15_bot.py")]
    return ""


def unpack(fname, data, saved):
    low = fname.lower()
    if low.endswith(".zip"):
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            items = [i for i in z.infolist() if not i.is_dir()]
            root = root_of([i.filename for i in items])
            for i in items:
                if i.filename.startswith(root):
                    put(i.filename[len(root):], z.read(i), saved)
    elif low.endswith((".tar.gz", ".tgz", ".tar")):
        with tarfile.open(fileobj=io.BytesIO(data)) as t:
            items = [i for i in t.getmembers() if i.isfile()]
            names = [i.name[2:] if i.name.startswith("./") else i.name for i in items]
            root = root_of(names)
            for i, n in zip(items, names):
                if n.startswith(root):
                    put(n[len(root):], t.extractfile(i).read(), saved)
    else:
        put(os.path.basename(fname.replace("\\", "/")), data, saved)


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _ok(self):
        return self.path.split("?")[0].strip("/") == token

    def do_GET(self):
        if not self._ok():
            self.send_error(404); return
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8"); self.end_headers()
        self.wfile.write(PAGE.encode())

    def do_POST(self):
        if not self._ok():
            self.send_error(404); return
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > 200 * 1024 * 1024:
            self.send_error(413); return
        body = self.rfile.read(n)
        msg = BytesParser(policy=email_policy).parsebytes(b"Content-Type: " + self.headers["Content-Type"].encode() + b"\r\n\r\n" + body)
        saved, bad = [], []
        for part in (msg.iter_parts() if msg.is_multipart() else []):
            fname = part.get_filename()
            if not fname:
                continue
            try:
                unpack(fname, part.get_payload(decode=True) or b"", saved)
            except Exception as e:
                bad.append(f"{fname}: {type(e).__name__}")
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8"); self.end_headers()
        note = f"<h2>Got {len(saved)} file(s).</h2><p>Go back to the server's terminal to finish.</p>" + (f"<p>Couldn't read: {', '.join(bad)}</p>" if bad else "")
        self.wfile.write((PAGE.split("<form")[0] + note).encode())
        print("Received:", ", ".join(sorted(saved)) or "nothing", flush=True)
        if bad:
            print("Couldn't read:", ", ".join(bad), flush=True)
        if saved:
            DONE.set()


httpd = http.server.ThreadingHTTPServer(("0.0.0.0", port), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
threading.Thread(target=httpd.serve_forever, daemon=True).start()
DONE.wait()
httpd.shutdown()
PYEOF
rm -f "$CERT" "$KEY"
if [ -n "$SUDO" ]; then sudo chown -R "$(id -u):$(id -g)" "$DIR"; fi

if [ ! -f "$DIR/kalshi15_bot.py" ]; then
  echo "kalshi15_bot.py wasn't in the upload. Run this script again and upload the whole folder."; exit 1
fi
for f in config.json vault_key.pem; do
  [ -f "$DIR/$f" ] || echo "Note: $f wasn't uploaded. The bot can't run without config.json; without vault_key.pem, Auto-trader users must save their Kalshi keys again."
done

if [ "$TEST" = "1" ]; then say "Test mode: files unpacked, stopping here."; exit 0; fi

# ---------------------------------------------------------------- 3. the bot as a service
say "3/3  Starting the bot"
echo "IMPORTANT: the bot must run in ONE place only. Two copies would post twice and could place real trades twice."
read -r -p "Is the bot on SillyDev stopped? Type YES once it is: " ans </dev/tty
if [ "$ans" != "YES" ]; then echo "Not started. Stop it on SillyDev, then run: sudo systemctl enable --now $SVC"; fi
sudo tee /etc/systemd/system/$SVC.service >/dev/null <<EOF
[Unit]
Description=Kiros helper bot
After=network-online.target
Wants=network-online.target

[Service]
User=$(id -un)
WorkingDirectory=$DIR
ExecStart=$DIR/venv/bin/python -u $DIR/kalshi15_bot.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
if [ "$ans" = "YES" ]; then
  sudo systemctl enable --now $SVC
  sleep 8
  sudo systemctl --no-pager --lines=25 status $SVC || true
fi
cat <<EOF

Speed from this server to Kalshi:
$(for i in 1 2 3; do curl -o /dev/null -s -w '  %{time_total}s\n' https://api.elections.kalshi.com/trade-api/v2/exchange/status; done)

Handy commands (paste into this terminal):
  See the bot's messages live:   sudo journalctl -u $SVC -f
  Restart after uploading files: sudo systemctl restart $SVC
  Stop it:                       sudo systemctl stop $SVC
  Upload newer files later:      bash setup.sh   (then restart)
EOF
