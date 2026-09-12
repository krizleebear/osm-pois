#!/usr/bin/env python3
"""
Lightweight macOS clipboard server for Docker DevContainers.
Bridges the macOS host clipboard (text and images) to Docker containers via host.docker.internal:4215.
"""
import http.server
import os
import subprocess
import sys
import tempfile
import urllib.request

PORT = int(os.environ.get("MAC_CLIPBOARD_PORT", "4215"))

# Security: A random token generated per session ensures only this container can access the bridge
TOKEN_FILE = os.path.expanduser("~/.mac_clipboard_token")

def get_or_create_token():
    env_token = os.environ.get("MAC_CLIPBOARD_TOKEN")
    if env_token:
        return env_token
    if os.path.exists(TOKEN_FILE):
        try:
            with open(TOKEN_FILE, "r") as f:
                return f.read().strip()
        except OSError:
            pass
    import secrets
    token = secrets.token_hex(24)
    try:
        with open(TOKEN_FILE, "w") as f:
            f.write(token)
        os.chmod(TOKEN_FILE, 0o600)
    except OSError:
        pass
    return token

AUTH_TOKEN = get_or_create_token()

def is_server_running():
    try:
        req = urllib.request.Request(f"http://127.0.0.1:{PORT}/health")
        req.add_header("X-Clipboard-Token", AUTH_TOKEN)
        with urllib.request.urlopen(req, timeout=0.5) as resp:
            return resp.status == 200
    except Exception:
        return False

class ClipboardHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress logs

    def check_auth(self):
        token = self.headers.get("X-Clipboard-Token")
        if not token or token != AUTH_TOKEN:
            self.send_response(403)
            self.end_headers()
            self.wfile.write(b"Forbidden")
            return False
        return True

    def do_GET(self):
        if not self.check_auth():
            return

        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"OK")
            return

        # SECURITY: Strictly restricted to images only (PNG). No plain text / passwords!
        if self.path == "/targets":
            res = subprocess.run(
                ["osascript", "-e", 'the clipboard as "PNGf"'],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
            body = b"image/png\n" if res.returncode == 0 else b"\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path in ("/image", "/image/png"):
            with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
                tmp_path = tmp.name
            try:
                cmd = [
                    "osascript",
                    "-e", 'set imageData to the clipboard as "PNGf"',
                    "-e", f'set fileRef to open for access POSIX file "{tmp_path}" with write permission',
                    "-e", "set eof fileRef to 0",
                    "-e", "write imageData to fileRef",
                    "-e", "close access fileRef"
                ]
                res = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if res.returncode == 0 and os.path.exists(tmp_path) and os.path.getsize(tmp_path) > 0:
                    with open(tmp_path, "rb") as f:
                        data = f.read()
                    self.send_response(200)
                    self.send_header("Content-Type", "image/png")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                else:
                    self.send_response(404)
                    self.end_headers()
            finally:
                if os.path.exists(tmp_path):
                    try:
                        os.remove(tmp_path)
                    except OSError:
                        pass
            return

        self.send_response(404)
        self.end_headers()

def main():
    if "--daemon" in sys.argv:
        if is_server_running():
            sys.exit(0)
        # Fork daemon
        pid = os.fork()
        if pid > 0:
            sys.exit(0)
        os.setsid()
        # Redirect standard file descriptors
        with open(os.devnull, "r") as devnull_r, open(os.devnull, "a+") as devnull_w:
            os.dup2(devnull_r.fileno(), sys.stdin.fileno())
            os.dup2(devnull_w.fileno(), sys.stdout.fileno())
            os.dup2(devnull_w.fileno(), sys.stderr.fileno())

    if is_server_running():
        sys.exit(0)

    try:
        server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), ClipboardHandler)
        server.serve_forever()
    except (KeyboardInterrupt, SystemExit):
        pass
    except Exception as e:
        sys.stderr.write(f"[mac_clipboard_server] Error: {e}\n")
        sys.exit(1)

if __name__ == "__main__":
    main()
