#!/usr/bin/env python3
import contextlib
import http.client
import http.server
import json
import os
import pathlib
import re
import signal
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest

import h2.config
import h2.connection
import h2.events


NGINX = os.environ.get("TEST_NGINX_BINARY", "/usr/sbin/nginx")
ID_A = "a123456789abcdef0123456789abcdef"
ID_B = "b123456789abcdef0123456789abcdef"
HEX_ID = re.compile(r"^[0-9a-fA-F]{32}$")


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_for(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.01)
    raise AssertionError("timed out waiting for nginx")


class Backend(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/slow"):
            time.sleep(0.5)
        body = self.headers.get("X-Request-ID", "").encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            self.wfile.write(body)

    def log_message(self, *args):
        pass


class RequestIDTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="nginx-request-id-")
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.root = pathlib.Path(cls.tmp.name)
        # The packaged binary can drop privileges when the test runs as root.
        cls.root.chmod(0o755)
        cls.backend = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Backend)
        cls.backend.daemon_threads = True
        cls.addClassCleanup(cls.backend.server_close)
        threading.Thread(target=cls.backend.serve_forever, daemon=True).start()
        cls.addClassCleanup(cls.backend.shutdown)
        cls.backend_port = cls.backend.server_port
        cls.ports = {}
        for name in ("edge", "middle", "last", "frozen", "off", "tls", "untrusted",
                     "realip", "location_realip", "regex_captures", "capture_source",
                     "invalid_redirect", "dead"):
            port = free_port()
            while port in cls.ports.values() or port == cls.backend_port:
                port = free_port()
            cls.ports[name] = port
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-days", "1", "-subj", "/CN=localhost",
             "-keyout", str(cls.root / "key.pem"),
             "-out", str(cls.root / "cert.pem")],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        p = cls.ports
        relay = """
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header X-Request-ID $correlation_id;
            proxy_set_header X-Forwarded-For $http_x_forwarded_for;
        """
        routes = f"""
            location /ok {{ return 200 "$correlation_id"; }}
            location /fail {{
                proxy_pass http://127.0.0.1:{p['dead']};
            }}
            location /slow {{
                proxy_read_timeout 100ms;
                proxy_pass http://127.0.0.1:{cls.backend_port};
            }}
            location /redirect {{
                error_page 418 = /fail;
                return 418;
            }}
            location /subrequest {{
                auth_request /_auth;
                proxy_pass http://127.0.0.1:{cls.backend_port};
            }}
            location = /_auth {{
                internal;
                proxy_pass http://127.0.0.1:{p['dead']};
            }}
            location /retry {{
                proxy_pass http://retry;
                proxy_next_upstream error timeout;
                proxy_next_upstream_tries 2;
            }}
            location /log-error {{
                root {cls.root};
                access_log {cls.root}/access.log ids;
                access_log {cls.root}/missing/$correlation_id/access.log ids;
                return 200 "$correlation_id";
            }}
            location / {{
                proxy_pass http://127.0.0.1:{cls.backend_port};
            }}
        """
        cls.config = f"""
            daemon off;
            master_process off;
            pid {cls.root}/nginx.pid;
            error_log {cls.root}/error.log info;
            events {{ worker_connections 128; }}
            http {{
                log_format ids escape=json
                    '{{"node":"$server_port","uri":"$request_uri",'
                    '"id":"$correlation_id","local":"$request_id",'
                    '"status":$status,"connection":"$connection",'
                    '"peer":"$realip_remote_addr","remote":"$remote_addr",'
                    '"upstream":"$upstream_addr"}}';
                access_log {cls.root}/access.log ids;
                log_subrequest on;
                client_header_timeout 300ms;
                send_timeout 1s;
                proxy_connect_timeout 200ms;
                proxy_read_timeout 1s;
                set_real_ip_from 127.0.0.1;
                real_ip_header X-Forwarded-For;
                geo $realip_remote_addr $trusted_peer {{
                    default 0;
                    127.0.0.1/32 1;
                }}
                map $trusted_peer $candidate_id {{
                    default "";
                    1 $http_x_request_id;
                }}
                geo $realip_remote_addr $nonlocal_peer {{
                    default 0;
                    192.0.2.0/24 1;
                }}
                map $nonlocal_peer $untrusted_candidate {{
                    default "";
                    1 $http_x_request_id;
                }}
                map $uri $changing_id {{
                    default {ID_A};
                    /fail {ID_B};
                }}
                map $remote_addr $remote_candidate {{
                    default {ID_B};
                    203.0.113.9 {ID_A};
                }}
                map $http_x_request_id $regex_candidate {{
                    "~^([0-9a-f]{{32}})$" $1;
                }}
                map $host $server_capture_candidate {{
                    default $1;
                }}
                error_log_request_id $candidate_id;
                upstream retry {{
                    server 127.0.0.1:{p['dead']} max_fails=0;
                    server 127.0.0.1:{cls.backend_port} backup;
                }}
                server {{
                    listen 127.0.0.1:{p['edge']};
                    error_log_request_id $request_id;
                    {relay}
                    location / {{ proxy_pass http://127.0.0.1:{p['middle']}; }}
                }}
                server {{
                    listen 127.0.0.1:{p['middle']};
                    http2 on;
                    {relay}
                    location / {{ proxy_pass http://127.0.0.1:{p['last']}; }}
                }}
                server {{
                    listen 127.0.0.1:{p['last']};
                    http2 on;
                    {relay}
                    {routes}
                }}
                server {{
                    listen 127.0.0.1:{p['frozen']};
                    error_log_request_id $changing_id;
                    {relay}
                    {routes}
                }}
                server {{
                    listen 127.0.0.1:{p['off']};
                    error_log_request_id off;
                    {routes}
                }}
                server {{
                    listen 127.0.0.1:{p['untrusted']};
                    error_log_request_id $untrusted_candidate;
                    {routes}
                }}
                server {{
                    listen 127.0.0.1:{p['realip']};
                    error_log_request_id $remote_candidate;
                    set $rewrite_id $correlation_id;
                    location /echo {{
                        proxy_set_header X-Request-ID
                            "$correlation_id:$remote_addr:$rewrite_id";
                        proxy_pass http://127.0.0.1:{cls.backend_port};
                    }}
                    {routes}
                }}
                server {{
                    listen 127.0.0.1:{p['location_realip']};
                    set_real_ip_from 192.0.2.1;
                    error_log_request_id $remote_candidate;
                    location /echo {{
                        set_real_ip_from 127.0.0.1;
                        proxy_set_header X-Request-ID
                            "$correlation_id:$remote_addr:$remote_candidate:$request_id";
                        proxy_pass http://127.0.0.1:{cls.backend_port};
                    }}
                    location /fail {{
                        set_real_ip_from 127.0.0.1;
                        proxy_pass http://127.0.0.1:{p['dead']};
                    }}
                }}
                server {{
                    listen 127.0.0.1:{p['regex_captures']};
                    server_name ~^([a-z]+)[.]([a-z]+)[.]test$;
                    error_log_request_id $regex_candidate;
                    return 200 "$1:$2:$correlation_id";
                }}
                server {{
                    listen 127.0.0.1:{p['capture_source']};
                    server_name "~^([0-9a-f]{{32}})[.]test$";
                    error_log_request_id $server_capture_candidate;
                    return 200 "$1:$correlation_id";
                }}
                server {{
                    listen 127.0.0.1:{p['invalid_redirect']};
                    error_page 400 = /fail;
                    {routes}
                }}
                server {{
                    listen 127.0.0.1:{p['tls']} ssl;
                    ssl_certificate {cls.root}/cert.pem;
                    ssl_certificate_key {cls.root}/key.pem;
                    {routes}
                }}
            }}
        """
        (cls.root / "nginx.conf").write_text(cls.config)
        cls.stderr = (cls.root / "stderr.log").open("w+")
        cls.addClassCleanup(cls.stderr.close)
        cls.process = subprocess.Popen(
            [NGINX, "-p", str(cls.root) + "/", "-c", str(cls.root / "nginx.conf")],
            stdout=cls.stderr, stderr=cls.stderr,
        )
        cls.addClassCleanup(cls.stop_nginx)

        def ready():
            if cls.process.poll() is not None:
                raise AssertionError((cls.root / "stderr.log").read_text())
            try:
                with socket.create_connection(("127.0.0.1", p["edge"]), 0.1):
                    return True
            except OSError:
                return False

        wait_for(ready)

    @classmethod
    def stop_nginx(cls):
        if cls.process.poll() is None:
            cls.process.send_signal(signal.SIGQUIT)
            try:
                cls.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                cls.process.kill()
                cls.process.wait()
        text = (cls.root / "stderr.log").read_text()
        if cls.process.returncode != 0 or "Sanitizer" in text or "runtime error:" in text:
            raise AssertionError(text)

    def setUp(self):
        self.error_offset = (self.root / "error.log").stat().st_size
        self.marker = self._testMethodName

    def rows(self, minimum=1, marker=None):
        marker = marker or self.marker

        def read():
            rows = [json.loads(line) for line in
                    (self.root / "access.log").read_text().splitlines()]
            rows = [row for row in rows if marker in row["uri"]]
            return rows if len(rows) >= minimum else None

        return wait_for(read)

    def errors(self):
        with (self.root / "error.log").open("rb") as log:
            log.seek(self.error_offset)
            return log.read().decode(errors="replace")

    def request(self, node="last", path="/fail", headers=None, connection=None):
        own_connection = connection is None
        conn = connection or http.client.HTTPConnection(
            "127.0.0.1", self.ports[node], timeout=3
        )
        try:
            conn.request("GET", path + "?case=" + self.marker, headers=headers or {})
            response = conn.getresponse()
            return response.status, response.read().decode()
        finally:
            if own_connection:
                conn.close()

    def raw(self, data, node="last", source_address=None):
        with socket.create_connection(
            ("127.0.0.1", self.ports[node]), 3, source_address=source_address
        ) as sock:
            sock.sendall(data)
            output = bytearray()
            while True:
                chunk = sock.recv(65536)
                if not chunk:
                    return bytes(output)
                output.extend(chunk)

    def assert_ids(self, row, correlation=None):
        self.assertRegex(row["local"], HEX_ID)
        self.assertRegex(row["id"], HEX_ID)
        if correlation:
            self.assertEqual(row["id"], correlation)
        errors = self.errors()
        local = 'local_request_id: "' + row["local"] + '"'
        shared = ', request_id: "' + row["id"] + '"'
        self.assertTrue(
            any(local in line and shared in line for line in errors.splitlines()),
            errors,
        )

    def test_cascade_replaces_external_id(self):
        status, _ = self.request("edge", headers={"X-Request-ID": ID_A})
        self.assertEqual(status, 502)
        rows = self.rows(3)
        self.assertEqual(len({row["id"] for row in rows}), 1)
        self.assertEqual(len({row["local"] for row in rows}), 3)
        edge = next(row for row in rows if row["node"] == str(self.ports["edge"]))
        self.assertEqual(edge["id"], edge["local"])
        self.assertNotEqual(edge["id"], ID_A)
        last = next(row for row in rows if row["node"] == str(self.ports["last"]))
        self.assert_ids(last, edge["id"])

    def test_inherited_id_survives_realip(self):
        self.request("middle", headers={
            "X-Request-ID": ID_A, "X-Forwarded-For": "203.0.113.9"
        })
        rows = self.rows(2)
        for row in rows:
            self.assertEqual(row["id"], ID_A)
            self.assertEqual(row["remote"], "203.0.113.9")
            self.assertEqual(row["peer"], "127.0.0.1")
        self.assert_ids(rows[0], ID_A)

    def test_remote_addr_source_runs_after_realip(self):
        headers = {"X-Forwarded-For": "203.0.113.9"}
        status, body = self.request("realip", "/echo", headers=headers)
        self.assertEqual(status, 200)
        self.assertEqual(body, f"{ID_A}:203.0.113.9:{ID_A}")
        status, _ = self.request("realip", "/fail", headers=headers)
        self.assertEqual(status, 502)
        rows = self.rows(2)
        for row in rows:
            self.assertEqual(row["remote"], "203.0.113.9")
            self.assertEqual(row["peer"], "127.0.0.1")
            self.assertEqual(row["id"], ID_A)
        failed = next(row for row in rows if row["status"] == 502)
        self.assert_ids(failed, ID_A)
        self.assertIn("client: 203.0.113.9,", self.errors())

    def test_missing_and_invalid_id_fall_back(self):
        for i, value in enumerate(("", "short", "g" * 32, "a" * 33, "a" * 256)):
            with self.subTest(value=value):
                self.request(path="/fail/" + str(i), headers={"X-Request-ID": value})
        for row in self.rows(5):
            self.assert_ids(row, row["local"])

    def test_source_does_not_cache_location_realip_dependencies(self):
        headers = {"X-Forwarded-For": "203.0.113.9"}
        status, body = self.request("location_realip", "/echo", headers=headers)
        self.assertEqual(status, 200)
        row = self.rows()[0]
        self.assertEqual(body, f"{ID_B}:203.0.113.9:{ID_A}:{row['local']}")
        status, _ = self.request("location_realip", "/fail", headers=headers)
        self.assertEqual(status, 502)
        rows = self.rows(2)
        for row in rows:
            self.assertEqual(row["remote"], "203.0.113.9")
            self.assertEqual(row["peer"], "127.0.0.1")
            self.assertEqual(row["id"], ID_B)
        failed = next(row for row in rows if row["status"] == 502)
        self.assert_ids(failed, ID_B)
        self.assertIn("client: 203.0.113.9,", self.errors())

    def test_uppercase_id_is_preserved(self):
        self.request(headers={"X-Request-ID": ID_A.upper()})
        self.assert_ids(self.rows()[0], ID_A.upper())

    def test_source_preserves_server_name_regex_captures(self):
        status, body = self.request("regex_captures", "/echo", headers={
            "Host": "tenant.example.test", "X-Request-ID": ID_A,
        })
        self.assertEqual(status, 200)
        self.assertEqual(body, f"tenant:example:{ID_A}")

    def test_source_can_read_server_name_regex_capture(self):
        status, body = self.request("capture_source", "/echo", headers={
            "Host": f"{ID_A}.test",
        })
        self.assertEqual(status, 200)
        self.assertEqual(body, f"{ID_A}:{ID_A}")

    def test_duplicate_header_falls_back(self):
        self.raw((
            f"GET /fail?case={self.marker} HTTP/1.1\r\nHost: localhost\r\n"
            f"X-Request-ID: {ID_A}\r\nX-Request-ID: {ID_B}\r\n"
            "Connection: close\r\n\r\n"
        ).encode())
        row = self.rows()[0]
        self.assert_ids(row, row["local"])

    def test_untrusted_peer_cannot_supply_id(self):
        self.request("untrusted", headers={
            "X-Request-ID": ID_A, "X-Forwarded-For": "192.0.2.1"
        })
        row = self.rows()[0]
        self.assert_ids(row, row["local"])

    def test_headers_rejected_before_id_selection(self):
        response = self.raw((
            f"GET /ok?case={self.marker} HTTP/1.1\r\nHost: localhost\r\n"
            f"X-Request-ID: {ID_A}\r\nContent-Length: invalid\r\n"
            "Connection: close\r\n\r\n"
        ).encode())
        self.assertIn(b"400 Bad Request", response)
        row = self.rows()[0]
        self.assertEqual(row["id"], "")
        self.assertIn('local_request_id: "' + row["local"] + '"', self.errors())
        self.assertNotIn(', request_id:', self.errors())

    def test_early_warning_does_not_freeze_missing_header(self):
        with socket.create_connection(("127.0.0.1", self.ports["last"]), 3) as sock:
            sock.sendall((
                f"GET /ok?case={self.marker} HTTP/1.1\r\nHost: localhost\r\n"
                "Bad_Header: ignored\r\n"
            ).encode())
            wait_for(lambda: "invalid header line" in self.errors())
            self.assertNotIn(', request_id:', self.errors())
            sock.sendall((
                f"X-Request-ID: {ID_A}\r\nConnection: close\r\n\r\n"
            ).encode())
            while sock.recv(65536):
                pass
        row = self.rows()[0]
        self.assertEqual(row["id"], ID_A)
        self.assertIn('local_request_id: "' + row["local"] + '"', self.errors())

    def test_invalid_headers_redirect_has_only_local_id(self):
        response = self.raw((
            f"GET /ok?case={self.marker} HTTP/1.1\r\nHost: localhost\r\n"
            f"X-Request-ID: {ID_A}\r\nContent-Length: invalid\r\n"
            "Connection: close\r\n\r\n"
        ).encode(), node="invalid_redirect")
        self.assertIn(b"502 Bad Gateway", response)
        row = self.rows()[0]
        self.assertEqual(row["id"], "")
        self.assertIn('local_request_id: "' + row["local"] + '"', self.errors())
        self.assertNotIn(', request_id:', self.errors())

    def test_partial_headers_timeout_has_only_local_id(self):
        self.raw((
            f"GET /ok?case={self.marker} HTTP/1.1\r\nHost: localhost\r\n"
            f"X-Request-ID: {ID_A}\r\n"
        ).encode())
        row = self.rows()[0]
        self.assertEqual(row["status"], 408)
        self.assertEqual(row["id"], "")
        self.assertIn('local_request_id: "' + row["local"] + '"', self.errors())
        self.assertNotIn(', request_id:', self.errors())

    def test_redirect_does_not_recompute_source(self):
        self.request("frozen", "/redirect")
        self.assert_ids(self.rows()[0], ID_A)

    def test_subrequest_uses_main_request_id(self):
        self.request(path="/subrequest", headers={"X-Request-ID": ID_A})
        self.assert_ids(self.rows()[0], ID_A)
        errors = self.errors()
        self.assertIn('subrequest: "/_auth"', errors)
        ids = re.findall(r', request_id: "([^"]+)"', errors)
        self.assertTrue(ids)
        self.assertEqual(set(ids), {ID_A})

    def test_upstream_retry_preserves_id(self):
        status, body = self.request(path="/retry", headers={"X-Request-ID": ID_A})
        self.assertEqual((status, body), (200, ID_A))
        row = self.rows()[0]
        self.assertIn(", ", row["upstream"])
        self.assert_ids(row, ID_A)

    def test_upstream_timeout(self):
        status, _ = self.request("edge", "/slow")
        self.assertEqual(status, 504)
        rows = self.rows(3)
        self.assertEqual(len({row["id"] for row in rows}), 1)
        self.assert_ids(rows[0])

    def test_keepalive_does_not_reuse_ids(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.ports["last"], timeout=3)
        self.addCleanup(conn.close)
        for value in (ID_A, ID_B):
            self.request(headers={"X-Request-ID": value}, connection=conn)
        rows = self.rows(2)
        self.assertEqual([row["id"] for row in rows], [ID_A, ID_B])
        self.assertEqual(len({row["connection"] for row in rows}), 1)
        self.assertEqual(len({row["local"] for row in rows}), 2)
        for row in rows:
            self.assert_ids(row)

    def test_pipelined_requests_are_isolated(self):
        messages = []
        for value, close in ((ID_A, "keep-alive"), (ID_B, "close")):
            messages.append(
                f"GET /fail?case={self.marker} HTTP/1.1\r\nHost: localhost\r\n"
                f"X-Request-ID: {value}\r\nConnection: {close}\r\n\r\n"
            )
        response = self.raw("".join(messages).encode())
        self.assertEqual(response.count(b"HTTP/1.1 502"), 2)
        rows = self.rows(2)
        self.assertEqual([row["id"] for row in rows], [ID_A, ID_B])
        self.assertEqual(len({row["local"] for row in rows}), 2)

    def assert_http2_streams_isolated(self, node, hops):
        conn = h2.connection.H2Connection(config=h2.config.H2Configuration(
            client_side=True, header_encoding="utf-8"
        ))
        conn.initiate_connection()
        expected = {}
        for index in range(8):
            stream = index * 2 + 1
            value = format(index + 1, "032x")
            expected[stream] = value
            conn.send_headers(stream, [
                (":method", "GET"), (":scheme", "http"),
                (":authority", "localhost"),
                (":path", f"/fail/{stream}?case={self.marker}"),
                ("x-request-id", value),
            ], end_stream=True)
        completed = set()
        with socket.create_connection(("127.0.0.1", self.ports[node]), 3) as sock:
            sock.sendall(conn.data_to_send())
            while len(completed) < len(expected):
                data = sock.recv(65536)
                self.assertTrue(data, "HTTP/2 connection closed early")
                for event in conn.receive_data(data):
                    if isinstance(event, h2.events.ResponseReceived):
                        self.assertEqual(dict(event.headers)[":status"], "502")
                    if isinstance(event, h2.events.DataReceived):
                        conn.acknowledge_received_data(
                            event.flow_controlled_length, event.stream_id
                        )
                    if isinstance(event, h2.events.StreamEnded):
                        completed.add(event.stream_id)
                pending = conn.data_to_send()
                if pending:
                    sock.sendall(pending)
        rows = self.rows(8 * hops)
        self.assertEqual(len({row["local"] for row in rows}), 8 * hops)
        for stream, value in expected.items():
            matches = [row for row in rows if row["uri"].startswith(f"/fail/{stream}?")]
            self.assertEqual(len(matches), hops)
            for row in matches:
                self.assertEqual(row["id"], value)
            self.assert_ids(next(row for row in matches
                                 if row["node"] == str(self.ports["last"])), value)

    def test_http2_cascade_streams_are_isolated(self):
        self.assert_http2_streams_isolated("middle", 2)

    def test_http2_error_contexts_are_isolated(self):
        self.assert_http2_streams_isolated("last", 1)

    def test_off_disables_context_and_correlation(self):
        self.request("off", headers={"X-Request-ID": ID_A})
        row = self.rows()[0]
        self.assertEqual(row["id"], "")
        self.assertNotIn("request_id:", self.errors())

    def test_plain_http_to_https_has_validated_id(self):
        status, _ = self.request("tls", "/ok", headers={"X-Request-ID": ID_A})
        self.assertEqual(status, 400)
        self.assert_ids(self.rows()[0], ID_A)

    def test_tls_handshake_has_no_request_id(self):
        context = ssl.create_default_context()
        with socket.create_connection(("127.0.0.1", self.ports["tls"]), 3) as sock:
            with self.assertRaises(ssl.SSLError):
                context.wrap_socket(sock, server_hostname="localhost")
        wait_for(lambda: "SSL_do_handshake()" in self.errors())
        self.assertNotIn("request_id:", self.errors())

    def test_long_uri_keeps_ids_before_request_context(self):
        self.request(path="/fail/" + "x" * 1800, headers={"X-Request-ID": ID_A})
        self.assert_ids(self.rows()[0], ID_A)

    def test_error_after_access_log_keeps_ids(self):
        status, body = self.request(path="/log-error", headers={"X-Request-ID": ID_A})
        self.assertEqual((status, body), (200, ID_A))
        wait_for(lambda: "while logging request" in self.errors())
        self.assert_ids(self.rows()[0], ID_A)
        self.assertIn("/missing/" + ID_A + "/access.log", self.errors())

    def test_configuration_validation(self):
        for value in ("on", "$correlation_id", "$does_not_exist", "$request_id-suffix"):
            with self.subTest(value=value):
                path = self.root / "invalid.conf"
                path.write_text(
                    "events {} http { error_log_request_id " + value + "; }"
                )
                result = subprocess.run(
                    [NGINX, "-t", "-p", str(self.root) + "/", "-c", str(path)],
                    capture_output=True,
                )
                self.assertNotEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
