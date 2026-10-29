# Building Nginx with Additional Modules

This project builds the `nginx-custom` Debian package for Ubuntu **20.04 (focal), 22.04 (jammy), and 24.04 (noble)**. Each Ubuntu release has its own build; all packages target **amd64**. The package includes additional dynamic modules, a bundled OpenResty LuaJIT, request ID correlation, and a helper for upgrading a running Nginx binary.

Docker Compose and CI default to **Nginx 1.30.6**. This is also the minimum version accepted by the build script and request ID patch. Newer releases must still pass patch application, compilation, and tests.

## Building Packages

Run commands from the repository root with Docker Engine and the Docker Compose plugin available. Builds download sources and dependencies from public repositories. Non-amd64 build hosts need amd64 emulation; the output is still amd64.

Select a profile from [docker-compose.yml](docker-compose.yml). Without a profile, no services are selected.

```bash
# Build Ubuntu 24.04 and propagate the build container's exit code.
docker compose --profile ubuntu24 up --build \
  --abort-on-container-failure --exit-code-from nginx-build-ubuntu24 \
  nginx-build-ubuntu24

# Build every Ubuntu target.
docker compose --profile all up --build

# Build selected targets.
docker compose --profile ubuntu20 --profile ubuntu22 up --build

# Set the version or package name for a local build.
NGINX_VERSION=1.30.6 PACKAGE_BASE_NAME=my-nginx \
  docker compose --profile ubuntu24 up --build
```

### Build Parameters

These environment variables are passed to [build-deb.sh](build-deb.sh) by Compose:

| Parameter | Meaning | Default |
|-----------|---------|---------|
| `NGINX_VERSION` | Nginx source version; minimum `1.30.6` | `1.30.6` |
| `DISABLE_LTO` | `1` disables Link Time Optimization for the Nginx build | `1` |
| `OPENRESTY_LUAJIT_VERSION` | OpenResty LuaJIT tag bundled with the Lua module | `v2.1-20250826` |
| `PACKAGE_BASE_NAME` | Main package name, without an Ubuntu codename suffix | `nginx-custom` |
| `PACKAGE_REVISION` | Package revision shared by the main and transitional packages | Build date and time, `YYYYMMDDHHMM` |

When `build-deb.sh` runs without `NGINX_VERSION`, it queries nginx.org for the stable version. Compose and CI explicitly supply their pinned default. CI uses `nginx-custom` and one UTC revision, `YYYYMMDDHHMM.RUN_NUMBER.RUN_ATTEMPT`, for all three Ubuntu targets.

The Dockerfiles install Rust `1.81.0` for the ACME module; `RUST_VERSION` is a Docker build argument, not a Compose environment variable. Most module repositories are cloned without pinned commits, so rebuilding the same Nginx version can pick up newer module code.

### Build Output

Packages are written to `output/ubuntu20/`, `output/ubuntu22/`, or `output/ubuntu24/`. With the default package name, each directory contains:

- The main package: `nginx-custom_<nginx>-1ubuntu<ubuntu>.<revision>_amd64.deb`.
- Three transitional packages: `nginx-custom-focal`, `nginx-custom-jammy`, and `nginx-custom-noble`, each depending on the exact main package version.
- `package-file.txt`: the main package filename for this build.
- `package-files.txt`: all four package filenames for this build.
- `build-info.txt`: the Nginx version, configure arguments, and Ubuntu release.

CI additionally creates `SHA256SUMS`. Local builds can leave older packages in the output directory; the manifests identify the current build.

## Package Installation

Choose the build matching the target host's Ubuntu release. For a local Ubuntu 24.04 build, install the exact main package from its manifest:

```bash
package_file=$(cat output/ubuntu24/package-file.txt)
sudo apt install "./output/ubuntu24/$package_file"
sudo nginx -t
sudo systemctl status nginx --no-pager
```

Use `output/ubuntu20` or `output/ubuntu22` on the corresponding Ubuntu release. For downloaded release assets, select the main package whose version contains the correct `1ubuntu20.04`, `1ubuntu22.04`, or `1ubuntu24.04` component.

The codename-suffixed packages are transitional packages for installations using the former package names. They do not contain Nginx and cannot replace the main package. All three names are generated for every Ubuntu build, so the suffix alone does not identify the target operating system.

The package conflicts with stock `nginx`, `nginx-common`, `nginx-core`, `nginx-full`, `nginx-light`, `nginx-extras`, and `nginx-mainline`. Back up `/etc/nginx` and review apt's removal plan when replacing another package. A switch from a different package can stop the old service; it is not guaranteed to be seamless. Existing configuration must also match the modules included below.

## Additional Modules

All modules in this table are built as dynamic modules. Their configuration files live in `/etc/nginx/modules-available/`.

| Module | Configuration file | Enabled by default | Purpose |
|--------|--------------------|--------------------|---------|
| NDK | `10-ndk.conf` | Yes | Development kit required by Lua |
| headers-more | `20-headers-more.conf` | Yes | Request and response header control |
| cache-purge | `20-cache-purge.conf` | Yes | Cache purging |
| auth-pam | `20-auth-pam.conf` | No | PAM authentication |
| dav-ext | `20-dav-ext.conf` | No | Extended WebDAV support |
| fancyindex | `20-fancyindex.conf` | No | Directory listings |
| njs HTTP | `20-njs-http.conf` | No | JavaScript for HTTP |
| njs Stream | `20-njs-stream.conf` | No | JavaScript for Stream |
| ACME | `20-acme.conf` | No | Certificate management |
| OpenTelemetry | `20-otel.conf` | No | Tracing |
| Lua | `30-lua.conf` | Yes | Lua scripting with bundled OpenResty LuaJIT |
| GeoIP2 | `30-geoip2.conf` | Yes | MaxMind GeoIP2 support |
| VTS | `30-vts.conf` | Yes | Virtual host traffic statistics |

The former echo, nchan, RTMP, uploadprogress, and subs-filter modules are no longer included. Upstream-fair is also not built. VTS is loaded by default, but a statistics endpoint must be configured separately.

The supplied `nginx.conf` includes `/etc/nginx/modules-enabled/*.conf` in the main context. Existing configurations need that include to load enabled modules. Numeric prefixes ensure that NDK loads before Lua.

To enable njs HTTP:

```bash
sudo ln -sf ../modules-available/20-njs-http.conf /etc/nginx/modules-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

To disable it, first remove configuration directives that depend on njs, then remove its link:

```bash
sudo rm /etc/nginx/modules-enabled/20-njs-http.conf
sudo nginx -t && sudo systemctl reload nginx
```

On package configuration, the installer rewrites the module configuration files and recreates links for modules enabled by default. Removing one of those default links does not persist across package upgrades.

### Built-in Modules and Paths

The binary also includes HTTP SSL, HTTP/2, realip, stub_status, addition, sub, auth_request, DAV, FLV, gunzip, gzip_static, MP4, random_index, secure_link, and slice support. Mail with SSL and Stream with SSL, realip, and SSL preread are compiled in. These features do not need `load_module` entries.

| Item | Path |
|------|------|
| Binary | `/usr/sbin/nginx` |
| Configuration | `/etc/nginx/nginx.conf` |
| Dynamic modules | `/usr/lib/nginx/modules/` |
| Bundled LuaJIT | `/usr/lib/nginx/luajit/libnginx-custom-luajit.so.2` |
| Lua libraries | `/usr/share/lua/5.1/` |
| HTML files | `/usr/share/nginx/html/` |
| Logs | `/var/log/nginx/` |
| Request temporary files | `/var/lib/nginx/` |
| Master PID | `/run/nginx.pid` |
| Upgrade helper | `/usr/lib/nginx/nginx-upgrade` |

## Request ID Correlation

[The request ID patch](patches/nginx-1.30-request-id.patch) adds `error_log_request_id` in the `http` or `server` context and the `$correlation_id` variable. This is a project extension, not an upstream Nginx directive.

- `error_log_request_id off;` is the default. `$correlation_id` is empty and the patch adds no ID fields to the error log.
- `error_log_request_id $request_id;` selects a locally generated ID, suitable for an edge proxy accepting public requests.
- A different source variable can supply an inherited ID. Only exactly 32 hexadecimal characters are accepted; missing or invalid values fall back to the local `$request_id`.
- `$request_id` remains the local identifier. `$correlation_id` is selected once for the main request and reused across internal redirects and subrequests.
- HTTP error messages gain `local_request_id` and, once selected, `request_id`. Early HTTP errors may have only the local ID. TLS failures before an HTTP request exists have neither field.

Merge this example into the existing `http` and `server` blocks in `/etc/nginx/nginx.conf`, replacing the upstream address with the application's address:

```nginx
http {
    error_log_request_id $request_id;
    log_format correlated escape=json
        '{"request_id":"$correlation_id","local_request_id":"$request_id",'
        '"request":"$request","status":$status}';
    access_log /var/log/nginx/access.log correlated;

    server {
        listen 80;
        add_header X-Request-ID $correlation_id always;

        location / {
            proxy_set_header X-Request-ID $correlation_id;
            proxy_pass http://127.0.0.1:8080;
        }
    }
}
```

On an internal proxy, replace the `error_log_request_id $request_id;` line with the following `http`-context directives to accept IDs only from a trusted peer. Replace `192.0.2.10/32` with that peer's actual address:

```nginx
geo $realip_remote_addr $trusted_id_peer {
    default 0;
    192.0.2.10/32 1;
}
map $trusted_id_peer $incoming_request_id {
    default "";
    1 $http_x_request_id;
}
error_log_request_id $incoming_request_id;
```

[`$realip_remote_addr`](https://nginx.org/en/docs/http/ngx_http_realip_module.html#embedded_variables) retains the original peer address when RealIP rewrites `$remote_addr`. Do not accept a public client's ID directly as a trusted correlation ID. The source is evaluated before server rewrite processing, so it must not depend on a value assigned by a rewrite `set`. `$correlation_id` cannot be used as its own source.

Validate and reload after editing:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

With the response header example above, an HTTP request should return a 32-character `X-Request-ID` matching `request_id` in the access log. When forwarding through trusted proxies, the correlation ID stays the same and the local IDs differ.

## Service Lifecycle and Upgrades

On a normal systemd installation, the package enables and starts `nginx.service`. For an active service, its `postinst` runs the upgrade helper after reloading unit files. Service policy can defer these actions.

The helper requires `Type=forking`, `PIDFile=/run/nginx.pid`, a matching systemd master PID, and no unfinished previous upgrade. It validates the new binary's configuration, sends `USR2` to start a new master, waits for its workers, then sends `QUIT` to the old master so existing requests can finish. This follows Nginx's [binary upgrade mechanism](https://nginx.org/en/docs/control.html#upgrade).

| Helper exit code | Meaning | Package configuration action |
|------------------|---------|------------------------------|
| `0` | New master is active; old connections are draining | Succeeds |
| `1` | Upgrade failed; inspect processes and logs | Fails |
| `2` | Seamless upgrade prerequisites are not met; helper left Nginx unchanged | Attempts a service restart, which can interrupt connections |
| `3` | Installed binary is already running | Succeeds |
| `4` | A previous upgrade is still draining connections | Fails; retry after it finishes |

`NGINX_UPGRADE_TIMEOUT` controls the wait for the new master and workers, defaulting to 10 seconds. It does not limit the time allowed for old connections to drain. A manual retry with a longer startup timeout is:

```bash
sudo env NGINX_UPGRADE_TIMEOUT=30 /usr/lib/nginx/nginx-upgrade
```

While old connections remain, `/run/nginx.pid.oldbin` can exist. Long-lived connections can delay another upgrade. If package configuration fails, inspect the apt output, `/var/log/nginx/error.log`, and `journalctl -u nginx`; correct the cause or wait for the previous upgrade to finish, then retry:

```bash
sudo dpkg --configure -a
```

The package honors `/usr/sbin/policy-rc.d`; a policy denying the restart action, such as exit code `101`, defers binary activation. Once activation is allowed, the helper can be run manually. A running service alone does not prove the installed binary has been activated: compare `/proc/<master-pid>/exe` with `/usr/sbin/nginx` when investigating a failed or deferred upgrade.

## GitHub Actions

[The workflow](.github/workflows/build.yml) builds and tests all three Ubuntu targets in parallel. It runs for pull requests targeting `main`, pushes to `main`, pushes of `v*` tags, and manual dispatch.

For a manual build, select **Actions → Build and test packages → Run workflow** and set `nginx_version`. The minimum is `1.30.6`. Branch and tag pushes use the version configured in the workflow; a tag name does not select the Nginx source version.

Each matrix job verifies package versions and architecture, runs the package tests, then uploads an artifact named `nginx-ubuntu20`, `nginx-ubuntu22`, or `nginx-ubuntu24`. Artifacts contain the packages, manifests, build information, and `SHA256SUMS`, and are retained for 14 days.

After all matrix jobs succeed on a `v*` tag push, a separate job creates a GitHub Release containing the `.deb` files and combined `SHA256SUMS`. PR, branch, and manual builds do not publish releases. The workflow uses the built-in `GITHUB_TOKEN`; no separate package-registry credential is required.

## Tests

After building a target with the default `nginx-custom` package name, run its package checks from the repository root:

```bash
bash tests/run-package-tests.sh ubuntu24 24.04
```

Use `ubuntu20 20.04` or `ubuntu22 22.04` for the other targets. The test runner needs a Linux Docker daemon capable of running privileged containers with private cgroup namespaces. It installs packages inside a temporary systemd container and removes the container on exit.

The checks cover package maintainer scripts, LuaJIT, Nginx startup, and [request ID behavior](tests/request_id_test.py), including HTTP/1.1, HTTP/2, retries, redirects, subrequests, and early errors.

[The upgrade test](tests/upgrade_test.py) installs a lower revision repacked from the same build, holds an HTTP request open, installs the target package, and verifies master replacement, uninterrupted health probes, completion of the original request, and systemd tracking the new master. This exercises the package upgrade path; it is not a compatibility test between different Nginx source releases.
