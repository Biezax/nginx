#!/usr/bin/env python3
import concurrent.futures
import http.client
import http.server
import pathlib
import subprocess
import sys
import threading
import time


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def wait_for(predicate, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("timed out waiting for the upgraded service")


def main():
    package = pathlib.Path(sys.argv[1]).resolve()
    entered = threading.Event()
    release = threading.Event()
    stop = threading.Event()
    failures = []
    probes = []
    body = b"in-flight request survived the package upgrade"

    class Backend(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            entered.set()
            if not release.wait(120):
                return
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    backend = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Backend)
    backend.daemon_threads = True
    backend_thread = threading.Thread(target=backend.serve_forever, daemon=True)
    backend_thread.start()
    port = 18080
    config = pathlib.Path("/etc/nginx/nginx.conf")
    original_config = config.read_bytes()
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=2)

    def request(path, timeout=5):
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
        try:
            connection.request("GET", path)
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def probe():
        while not stop.is_set():
            try:
                result = request("/health")
                if result != (200, b"ready"):
                    failures.append(repr(result))
                probes.append(result)
            except Exception as error:
                failures.append(repr(error))
            stop.wait(0.05)

    try:
        config.write_text(f"""
include /etc/nginx/modules-enabled/*.conf;
worker_processes 1;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log info;
events {{ worker_connections 128; }}
http {{
    access_log off;
    server {{
        listen 127.0.0.1:{port};
        location = /health {{ return 200 "ready"; }}
        location = /hold {{
            proxy_read_timeout 120s;
            proxy_buffering off;
            proxy_pass http://127.0.0.1:{backend.server_port};
        }}
    }}
}}
""")
        subprocess.run(["systemctl", "restart", "nginx"], check=True)
        assert request("/health") == (200, b"ready")
        old_pid = output("systemctl", "show", "--value", "-p", "MainPID", "nginx")
        old_inode = pathlib.Path(f"/proc/{old_pid}/exe").stat().st_ino
        held = pool.submit(request, "/hold", 120)
        assert entered.wait(10), "the in-flight request did not reach the backend"
        probing = pool.submit(probe)
        wait_for(lambda: len(probes) >= 2)

        subprocess.run(["apt-get", "install", "-y", str(package)], check=True, timeout=90)
        expected_version = output("dpkg-deb", "-f", str(package), "Version")
        assert output("dpkg-query", "-W", "-f=${Version}", "nginx-custom") == expected_version
        new_pid = pathlib.Path("/run/nginx.pid").read_text().strip()
        assert new_pid != old_pid, "the installed binary was not activated"
        assert pathlib.Path("/run/nginx.pid.oldbin").read_text().strip() == old_pid
        assert pathlib.Path(f"/proc/{old_pid}/exe").stat().st_ino == old_inode
        assert pathlib.Path(f"/proc/{new_pid}/exe").stat().st_ino == pathlib.Path("/usr/sbin/nginx").stat().st_ino
        assert pathlib.Path(f"/proc/{new_pid}/exe").stat().st_ino != old_inode
        assert not held.done(), "the old worker dropped the in-flight request"
        assert request("/health") == (200, b"ready")

        release.set()
        assert held.result(timeout=10) == (200, body)
        wait_for(lambda: not pathlib.Path("/run/nginx.pid.oldbin").exists())
        wait_for(lambda: output("systemctl", "show", "--value", "-p", "MainPID", "nginx") == new_pid)
        subprocess.run(["systemctl", "is-active", "--quiet", "nginx"], check=True)
        result = subprocess.run(["/usr/lib/nginx/nginx-upgrade"], check=False)
        assert result.returncode == 3, "repeating the upgrade should detect the running binary"
        assert pathlib.Path("/run/nginx.pid").read_text().strip() == new_pid
        stop.set()
        probing.result(timeout=10)
        assert not failures, failures
        print(f"Upgrade OK: master {old_pid} -> {new_pid}; {len(probes)} successful probes; in-flight request completed")
    finally:
        release.set()
        stop.set()
        pool.shutdown(wait=True)
        backend.shutdown()
        backend.server_close()
        backend_thread.join()
        config.write_bytes(original_config)
        subprocess.run(["systemctl", "stop", "nginx"], check=False)


if __name__ == "__main__":
    main()
