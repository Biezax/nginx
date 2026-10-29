#!/bin/bash
set -euo pipefail

package="/packages/${PACKAGE_FILE:?Missing package filename}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

dpkg-deb --raw-extract "$package" "$work/previous"
control="$work/previous/DEBIAN"
sh -n "$control/postinst"
sh -n "$control/prerm"
grep -q '/usr/lib/nginx/nginx-upgrade' "$control/postinst"
grep -q 'daemon-reload' "$control/postinst"
grep -q 'deb-systemd-invoke stop' "$control/prerm"
if grep -Eq '_dh_action=restart|deb-systemd-invoke try-restart' "$control/postinst" ||
    grep -qs 'deb-systemd-invoke stop' "$control/preinst"; then
    echo 'Package must not restart or stop nginx on upgrade' >&2
    exit 1
fi

# Reuse the payload to exercise a real dpkg upgrade without rebuilding Nginx.
version=$(dpkg-deb -f "$package" Version)
sed -i "s/^Version: .*/Version: $version~ci1/" "$control/control"
dpkg-deb --build "$work/previous" "$work/previous.deb"
apt-get update
apt-get install -y "$work/previous.deb"

grep -aFq '/usr/share/lua/5.1/?.lua' /usr/lib/nginx/luajit/libnginx-custom-luajit.so.2
test -x /usr/lib/nginx/nginx-upgrade
bash -n /usr/lib/nginx/nginx-upgrade
nginx -t
systemctl --quiet is-active nginx.service
TEST_NGINX_BINARY=/usr/sbin/nginx python3 -W error::ResourceWarning /checks/request_id_test.py
python3 -W error::ResourceWarning /checks/upgrade_test.py "$package"
