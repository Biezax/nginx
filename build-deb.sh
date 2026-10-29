#!/bin/bash
set -e

BUILD_DIR="/build/nginx-debian"
TARGET_DIR="/output"
DEB_DIR="$BUILD_DIR"
NGINX_VERSION=${NGINX_VERSION:-$(curl -s https://nginx.org/en/download.html | awk '/Stable version/{stable=1; next} /Legacy versions/{stable=0} stable' | grep -oP '(?<=nginx-)([0-9]+\.[0-9]+\.[0-9]+)(?=\.tar\.gz)' | sort -V | tail -1)}
MIN_NGINX_VERSION=1.30.6

if ! [[ "$NGINX_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid nginx version: '$NGINX_VERSION'; expected major.minor.patch" >&2
    exit 1
fi
if ! dpkg --compare-versions "$NGINX_VERSION" ge "$MIN_NGINX_VERSION"; then
    echo "nginx $MIN_NGINX_VERSION or newer is required by the request ID patch; got $NGINX_VERSION" >&2
    exit 1
fi

UBUNTU_VERSION=$(lsb_release -rs)
UBUNTU_CODENAME=$(lsb_release -cs)

PACKAGE_BASE_NAME=${PACKAGE_BASE_NAME:-nginx-custom}
PACKAGE_NAME="$PACKAGE_BASE_NAME"
PACKAGE_REVISION=${PACKAGE_REVISION:-$(date +%Y%m%d%H%M)}
PACKAGE_VERSION="${NGINX_VERSION}-1ubuntu${UBUNTU_VERSION}.${PACKAGE_REVISION}"
LEGACY_CODENAMES=(focal jammy noble)

OPENRESTY_LUAJIT_VERSION=${OPENRESTY_LUAJIT_VERSION:-v2.1-20250826}
OPENRESTY_LUAJIT_DIR=/build/openresty-luajit-src
OPENRESTY_LUAJIT_PREFIX=/usr
OPENRESTY_LUAJIT_DESTDIR=/build/openresty-luajit
OPENRESTY_LUAJIT_SONAME=libnginx-custom-luajit.so.2
export LUAJIT_LIB="$OPENRESTY_LUAJIT_DESTDIR$OPENRESTY_LUAJIT_PREFIX/lib"
export LUAJIT_INC="$OPENRESTY_LUAJIT_DESTDIR$OPENRESTY_LUAJIT_PREFIX/include/luajit-2.1"

clone_module() {
    local target="$1"
    local attempt

    shift
    for attempt in 1 2 3 4 5; do
        rm -rf "$target"
        if git clone "$@" "$target"; then
            return 0
        fi
        if [ "$attempt" -eq 5 ]; then
            return 1
        fi
        echo "Clone failed for $target, retrying in $((attempt * 5)) seconds..."
        sleep $((attempt * 5))
    done
}

echo "Building nginx version $NGINX_VERSION for Ubuntu $UBUNTU_VERSION ($UBUNTU_CODENAME)"
echo "Package name: $PACKAGE_NAME"
echo "Package version: $PACKAGE_VERSION"
echo "Package revision: $PACKAGE_REVISION"
echo "OpenResty LuaJIT version: $OPENRESTY_LUAJIT_VERSION"

if [ "${DISABLE_LTO}" == "1" ]; then
    echo "LTO disabled to avoid compiler errors with dynamic modules"
fi

echo "Cleaning up modules directory..."
rm -rf "$DEB_DIR/modules"
mkdir -p "$DEB_DIR/modules"

mkdir -p "$TARGET_DIR"
mkdir -p "$DEB_DIR"

cd /build
wget -q "https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz"
tar -xzf "nginx-$NGINX_VERSION.tar.gz"

rm -rf "$BUILD_DIR"/*
cp -r "/build/nginx-$NGINX_VERSION"/* "$BUILD_DIR/"

if [ -d "/build/nginx-$NGINX_VERSION/man" ]; then
    mkdir -p "$BUILD_DIR/man"
    cp -r "/build/nginx-$NGINX_VERSION/man"/* "$BUILD_DIR/man/"
    echo "Copied man pages from nginx sources"
else
    echo "No man pages found in nginx sources"
fi

cd "$BUILD_DIR"
patch --batch --forward --fuzz=0 -p1 < /build/patches/nginx-1.30-request-id.patch
mkdir -p modules

echo "Building OpenResty LuaJIT..."
rm -rf "$OPENRESTY_LUAJIT_DESTDIR"
clone_module "$OPENRESTY_LUAJIT_DIR" --branch "$OPENRESTY_LUAJIT_VERSION" --depth 1 https://github.com/openresty/luajit2.git
make -C "$OPENRESTY_LUAJIT_DIR" -j"$(nproc)" \
    PREFIX="$OPENRESTY_LUAJIT_PREFIX" \
    TARGET_SONAME="$OPENRESTY_LUAJIT_SONAME"
make -C "$OPENRESTY_LUAJIT_DIR" install \
    PREFIX="$OPENRESTY_LUAJIT_PREFIX" \
    DESTDIR="$OPENRESTY_LUAJIT_DESTDIR" \
    TARGET_SONAME="$OPENRESTY_LUAJIT_SONAME"
LUAJIT_SHARED_LIB=$(readlink -f "$LUAJIT_LIB/libluajit-5.1.so.2")
ln -sfn "$(basename "$LUAJIT_SHARED_LIB")" "$LUAJIT_LIB/$OPENRESTY_LUAJIT_SONAME"

echo "Downloading modules..."
cd "$DEB_DIR/modules"

clone_module http-headers-more-filter https://github.com/openresty/headers-more-nginx-module
clone_module http-auth-pam https://github.com/sto/ngx_http_auth_pam_module
clone_module http-cache-purge https://github.com/Danrancan/ngx_cache_purge_dynamic
clone_module http-dav-ext https://github.com/arut/nginx-dav-ext-module
clone_module http-ndk https://github.com/vision5/ngx_devel_kit
clone_module http-fancyindex https://github.com/aperezdc/ngx-fancyindex
clone_module http-lua https://github.com/openresty/lua-nginx-module
clone_module http-geoip2 https://github.com/leev/ngx_http_geoip2_module
clone_module http-vts --branch master --single-branch https://github.com/vozlt/nginx-module-vts.git
clone_module njs https://github.com/nginx/njs.git
clone_module http-acme https://github.com/nginx/nginx-acme.git
clone_module http-otel https://github.com/nginx/nginx-otel.git
#git clone https://github.com/gnosek/nginx-upstream-fair upstream-fair

clone_module lua-resty-core https://github.com/openresty/lua-resty-core
clone_module lua-resty-lrucache https://github.com/openresty/lua-resty-lrucache

cd "$BUILD_DIR"
mkdir -p debian/source
mkdir -p debian/modules

echo "Preparing Debian package structure..."

mkdir -p debian/source
echo "3.0 (quilt)" > debian/source/format

# Determine correct debhelper-compat version based on Ubuntu version
if [ "$UBUNTU_VERSION" = "20.04" ]; then
    DEBHELPER_COMPAT_VERSION="12"
else
    DEBHELPER_COMPAT_VERSION="13"
fi

echo "Ubuntu version: $UBUNTU_VERSION"
echo "Using debhelper-compat version: $DEBHELPER_COMPAT_VERSION"

cat > debian/control << EOF
Source: nginx
Section: httpd
Priority: optional
Maintainer: Stanislav Rossovskii <custom@example.com>
Build-Depends: debhelper-compat (= $DEBHELPER_COMPAT_VERSION),
 libpcre3-dev, zlib1g-dev, libssl-dev, 
 libxml2-dev, libxslt1-dev, libgd-dev, libgeoip-dev, libperl-dev,
 libpam0g-dev, libmaxminddb-dev, libldap2-dev, liblua5.3-dev | liblua5.4-dev,
 pkg-config, libbrotli-dev, po-debconf, patchelf,
 cmake, libclang-dev, libc-ares-dev, libre2-dev
Standards-Version: 4.6.2
Homepage: https://nginx.org
Rules-Requires-Root: no

Package: $PACKAGE_NAME
Architecture: amd64
Depends: \${shlibs:Depends}, \${misc:Depends}, iproute2, logrotate, procps
Provides: httpd, nginx
Conflicts: nginx, nginx-common, nginx-light, nginx-full, nginx-extras, nginx-core, nginx-mainline
Breaks: $PACKAGE_NAME-focal (<< \${binary:Version}), $PACKAGE_NAME-jammy (<< \${binary:Version}), $PACKAGE_NAME-noble (<< \${binary:Version})
Replaces: nginx, nginx-common, nginx-light, nginx-full, nginx-extras, nginx-core, nginx-mainline,
 $PACKAGE_NAME-focal (<< \${binary:Version}), $PACKAGE_NAME-jammy (<< \${binary:Version}), $PACKAGE_NAME-noble (<< \${binary:Version})
Description: Nginx web/proxy server (custom build for Ubuntu $UBUNTU_VERSION)
 Nginx ("engine X") is a high-performance web and reverse proxy server
 created by Igor Sysoev. It can be used both as a standalone web server
 and as a proxy to reduce the load on back-end HTTP or mail servers.
 .
 This custom build is based on Nginx $NGINX_VERSION and includes additional
 modules not available in the standard Ubuntu packages.
 .
 Built specifically for Ubuntu $UBUNTU_VERSION ($UBUNTU_CODENAME).
 .
 Includes the following additional modules:
  * headers-more-filter - control HTTP headers
  * auth-pam - PAM authentication
  * cache-purge - cache management
  * dav-ext - extended WebDAV
  * ndk - development kit
  * fancyindex - enhanced directory listings
  * lua - Lua scripting support
  * geoip2 - MaxMind GeoIP2 support
  * vts - virtual host traffic status
  * njs - JavaScript support for HTTP and stream
  * acme - automatic certificate management
  * otel - OpenTelemetry tracing
EOF

for legacy_codename in "${LEGACY_CODENAMES[@]}"; do
    cat >> debian/control << EOF

Package: $PACKAGE_NAME-$legacy_codename
Section: oldlibs
Architecture: amd64
Depends: $PACKAGE_NAME (= \${binary:Version}), \${misc:Depends}
Description: transitional package for $PACKAGE_NAME
 This package can be safely removed after the upgrade.
EOF
done

cat > debian/changelog << EOF
nginx ($PACKAGE_VERSION) $UBUNTU_CODENAME; urgency=medium

  * Custom build with additional modules based on nginx $NGINX_VERSION
  * Added various third-party modules for enhanced functionality
  * Disabled LTO to prevent issues with dynamic modules

 -- Custom Builder <custom@example.com>  $(date -R)
EOF

cat > debian/rules << EOF
#!/usr/bin/make -f
export DH_VERBOSE=1
export DPKG_EXPORT_BUILDFLAGS=1
include /usr/share/dpkg/default.mk

LUAJIT_LIB=$LUAJIT_LIB
LUAJIT_INC=$LUAJIT_INC

debian_cflags:=\$(shell dpkg-buildflags --get CFLAGS) -fPIC \$(shell dpkg-buildflags --get CPPFLAGS) -I$LUAJIT_INC
debian_ldflags:=\$(shell dpkg-buildflags --get LDFLAGS) -fPIC -L$LUAJIT_LIB

ifeq ("\${DISABLE_LTO}", "1")
    debian_cflags += -fno-lto
    debian_ldflags += -fno-lto
endif

ifneq (\$(DEB_HOST_ARCH),\$(DEB_BUILD_ARCH))
	CROSS=CC=\$(DEB_HOST_GNU_TYPE)-gcc
endif

export CFLAGS=\$(debian_cflags)
export LDFLAGS=\$(debian_ldflags)

FLAVOURS = $PACKAGE_NAME

BASEDIR=/build/nginx-debian
DEB_HOST_MULTIARCH ?= \$(shell dpkg-architecture -qDEB_HOST_MULTIARCH)

override_dh_auto_configure:
	cd \$(BASEDIR) && ./configure \\
	--prefix=/usr/share/nginx \\
	--sbin-path=/usr/sbin/nginx \\
	--conf-path=/etc/nginx/nginx.conf \\
	--http-log-path=/var/log/nginx/access.log \\
	--error-log-path=/var/log/nginx/error.log \\
	--lock-path=/var/lock/nginx.lock \\
	--pid-path=/run/nginx.pid \\
	--modules-path=/usr/lib/nginx/modules \\
	--http-client-body-temp-path=/var/lib/nginx/body \\
	--http-fastcgi-temp-path=/var/lib/nginx/fastcgi \\
	--http-proxy-temp-path=/var/lib/nginx/proxy \\
	--http-scgi-temp-path=/var/lib/nginx/scgi \\
	--http-uwsgi-temp-path=/var/lib/nginx/uwsgi \\
	--user=www-data \\
	--group=www-data \\
	--with-compat \\
	--with-debug \\
	--with-file-aio \\
	--with-threads \\
	--with-http_addition_module \\
	--with-http_auth_request_module \\
	--with-http_dav_module \\
	--with-http_flv_module \\
	--with-http_gunzip_module \\
	--with-http_gzip_static_module \\
	--with-http_mp4_module \\
	--with-http_random_index_module \\
	--with-http_realip_module \\
	--with-http_secure_link_module \\
	--with-http_slice_module \\
	--with-http_ssl_module \\
	--with-http_stub_status_module \\
	--with-http_sub_module \\
	--with-http_v2_module \\
	--with-mail \\
	--with-mail_ssl_module \\
	--with-stream \\
	--with-stream_realip_module \\
	--with-stream_ssl_module \\
	--with-stream_ssl_preread_module \\
	--add-dynamic-module=\$(BASEDIR)/modules/http-headers-more-filter \\
	--add-dynamic-module=\$(BASEDIR)/modules/http-auth-pam \\
	--add-dynamic-module=\$(BASEDIR)/modules/http-cache-purge \\
	--add-dynamic-module=\$(BASEDIR)/modules/http-dav-ext \\
	--add-dynamic-module=\$(BASEDIR)/modules/http-ndk \\
	--add-dynamic-module=\$(BASEDIR)/modules/http-fancyindex \\
	--add-dynamic-module=\$(BASEDIR)/modules/http-lua \\
	--add-dynamic-module=\$(BASEDIR)/modules/http-geoip2 \\
	--add-dynamic-module=\$(BASEDIR)/modules/http-vts \\
	--add-dynamic-module=\$(BASEDIR)/modules/njs/nginx \\
	--add-dynamic-module=\$(BASEDIR)/modules/http-acme \\
	--add-dynamic-module=\$(BASEDIR)/modules/http-otel \\
	#--add-dynamic-module=\$(BASEDIR)/modules/upstream-fair

override_dh_auto_build:
ifeq ("\${DISABLE_LTO}", "1")
	echo "Building with LTO disabled..."
	export DEB_CFLAGS_MAINT_STRIP="-flto=auto -ffat-lto-objects"
	export DEB_LDFLAGS_MAINT_STRIP="-flto=auto -ffat-lto-objects"
	export CFLAGS="\$(CFLAGS) -fno-lto"
	export LDFLAGS="\$(LDFLAGS) -fno-lto"
	export PERL_LDFLAGS="\$(PERL_LDFLAGS) -fno-lto"
	find \$(BASEDIR) -name Makefile -exec sed -i 's/-flto=auto//g' {} \; || echo "Warning: Failed to remove -flto=auto from Makefiles"
	find \$(BASEDIR) -name Makefile -exec sed -i 's/-ffat-lto-objects//g' {} \; || echo "Warning: Failed to remove -ffat-lto-objects from Makefiles"
	cd \$(BASEDIR) && make -j$(nproc) || { echo "Error: Build failed with LTO disabled"; exit 1; }
else
	echo "Building with default compiler settings..."
	cd \$(BASEDIR) && make -j$(nproc) || { echo "Error: Build failed"; exit 1; }
endif
	echo "Build completed successfully"

override_dh_auto_test:

override_dh_auto_install:
	cd \$(BASEDIR) && make install DESTDIR=\$(CURDIR)/debian/tmp || { echo "Error during installation"; exit 1; }
	install -m 0644 \$(BASEDIR)/objs/ngx_otel_module.so \$(CURDIR)/debian/tmp/usr/lib/nginx/modules/
	install -d \$(CURDIR)/debian/tmp/usr/lib/nginx/luajit/
	install -m 0755 $LUAJIT_SHARED_LIB \$(CURDIR)/debian/tmp/usr/lib/nginx/luajit/$OPENRESTY_LUAJIT_SONAME
	grep -qF 'include /etc/nginx/modules-enabled/*.conf;' debian/tmp/etc/nginx/nginx.conf || \\
		sed -i '1i include /etc/nginx/modules-enabled/*.conf;' debian/tmp/etc/nginx/nginx.conf
	mkdir -p debian/tmp/var/lib/nginx/body || { echo "Error creating body directory"; exit 1; }
	chmod 755 debian/tmp/var/lib/nginx/body
	chown www-data:www-data debian/tmp/var/lib/nginx/body

override_dh_installsystemd:
	dh_installsystemd --name=nginx --no-restart-after-upgrade --no-stop-on-upgrade

override_dh_installinit:
	dh_installinit --name=nginx --no-stop-on-upgrade --no-start

override_dh_installlogrotate:
	dh_installlogrotate --name=nginx

override_dh_strip:
	dh_strip
	patchelf --set-rpath '\$\$ORIGIN/../luajit' \$(CURDIR)/debian/$PACKAGE_NAME/usr/lib/nginx/modules/ngx_http_lua_module.so

override_dh_shlibdeps:
	dh_shlibdeps -l\$(CURDIR)/debian/$PACKAGE_NAME/usr/lib/nginx/luajit -- -x$PACKAGE_NAME

override_dh_install:
	dh_install

override_dh_missing:
	dh_missing --list-missing

%:
	dh \$@
EOF

chmod +x debian/rules

cat > debian/$PACKAGE_NAME.postinst << EOF
#!/bin/sh
set -e

if [ "\$1" = "configure" ]; then
    mkdir -p /var/lib/nginx/body /var/lib/nginx/fastcgi /var/lib/nginx/proxy /var/lib/nginx/scgi /var/lib/nginx/uwsgi || { echo "Failed to create nginx directories"; exit 1; }

    chown -R www-data:adm /var/log/nginx 2>/dev/null || echo "Warning: Could not set permissions on /var/log/nginx"
    chown -R www-data:www-data /var/lib/nginx || echo "Warning: Could not set permissions on /var/lib/nginx"
    
    chmod 700 /var/lib/nginx/body /var/lib/nginx/fastcgi /var/lib/nginx/proxy /var/lib/nginx/scgi /var/lib/nginx/uwsgi || echo "Warning: Could not set permissions on cache directories"

    logdir="/var/log/nginx"
    if [ ! -e "\$logdir/access.log" ]; then
        touch "\$logdir/access.log" || echo "Warning: Could not create access.log"
        chmod 640 "\$logdir/access.log" 2>/dev/null || echo "Warning: Could not set permissions on access.log"
        chown www-data:adm "\$logdir/access.log" 2>/dev/null || echo "Warning: Could not set ownership on access.log"
    fi

    if [ ! -e "\$logdir/error.log" ]; then
        touch "\$logdir/error.log" || echo "Warning: Could not create error.log"
        chmod 640 "\$logdir/error.log" 2>/dev/null || echo "Warning: Could not set permissions on error.log"
        chown www-data:adm "\$logdir/error.log" 2>/dev/null || echo "Warning: Could not set ownership on error.log"
    fi

    
    mkdir -p /etc/nginx/modules-available
    mkdir -p /etc/nginx/modules-enabled
    
    # Development Kit (базовый модуль, необходим для других)
    cat > /etc/nginx/modules-available/10-ndk.conf << EOFMOD
load_module /usr/lib/nginx/modules/ndk_http_module.so;
EOFMOD
	ln -svf /etc/nginx/modules-available/10-ndk.conf /etc/nginx/modules-enabled/10-ndk.conf

    # Headers More
    cat > /etc/nginx/modules-available/20-headers-more.conf << EOFMOD
load_module /usr/lib/nginx/modules/ngx_http_headers_more_filter_module.so;
EOFMOD
	ln -svf /etc/nginx/modules-available/20-headers-more.conf /etc/nginx/modules-enabled/20-headers-more.conf

    # Auth PAM
    cat > /etc/nginx/modules-available/20-auth-pam.conf << EOFMOD
load_module /usr/lib/nginx/modules/ngx_http_auth_pam_module.so;
EOFMOD

    # Cache Purge
    cat > /etc/nginx/modules-available/20-cache-purge.conf << EOFMOD
load_module /usr/lib/nginx/modules/ngx_http_cache_purge_module.so;
EOFMOD
	ln -svf /etc/nginx/modules-available/20-cache-purge.conf /etc/nginx/modules-enabled/20-cache-purge.conf

    # DAV Extended
    cat > /etc/nginx/modules-available/20-dav-ext.conf << EOFMOD
load_module /usr/lib/nginx/modules/ngx_http_dav_ext_module.so;
EOFMOD

    # Fancy Index
    cat > /etc/nginx/modules-available/20-fancyindex.conf << EOFMOD
load_module /usr/lib/nginx/modules/ngx_http_fancyindex_module.so;
EOFMOD

    # Lua (зависит от NDK)
    cat > /etc/nginx/modules-available/30-lua.conf << EOFMOD
load_module /usr/lib/nginx/modules/ngx_http_lua_module.so;
EOFMOD
	ln -svf /etc/nginx/modules-available/30-lua.conf /etc/nginx/modules-enabled/30-lua.conf
    # GeoIP2
    cat > /etc/nginx/modules-available/30-geoip2.conf << EOFMOD
load_module /usr/lib/nginx/modules/ngx_http_geoip2_module.so;
EOFMOD
	ln -svf /etc/nginx/modules-available/30-geoip2.conf /etc/nginx/modules-enabled/30-geoip2.conf

    # Vhost Traffic Status
    cat > /etc/nginx/modules-available/30-vts.conf << EOFMOD
load_module /usr/lib/nginx/modules/ngx_http_vhost_traffic_status_module.so;
EOFMOD
	ln -svf /etc/nginx/modules-available/30-vts.conf /etc/nginx/modules-enabled/30-vts.conf

    # NJS HTTP
    cat > /etc/nginx/modules-available/20-njs-http.conf << EOFMOD
load_module /usr/lib/nginx/modules/ngx_http_js_module.so;
EOFMOD

    # NJS Stream
    cat > /etc/nginx/modules-available/20-njs-stream.conf << EOFMOD
load_module /usr/lib/nginx/modules/ngx_stream_js_module.so;
EOFMOD

    # ACME
    cat > /etc/nginx/modules-available/20-acme.conf << EOFMOD
load_module /usr/lib/nginx/modules/ngx_http_acme_module.so;
EOFMOD

    # OpenTelemetry
    cat > /etc/nginx/modules-available/20-otel.conf << EOFMOD
load_module /usr/lib/nginx/modules/ngx_otel_module.so;
EOFMOD

    # Upstream Fair
    #cat > /etc/nginx/modules-available/20-upstream-fair.conf << EOFMOD
#load_module /usr/lib/nginx/modules/ngx_http_upstream_fair_module.so;
#EOFMOD

fi

#DEBHELPER#

# Runs after debhelper's daemon-reload; policy-rc.d can defer the upgrade.
# Not limited to upgrades: the renamed legacy package leaves its master running.
if [ "\$1" = configure ] && [ -z "\${DPKG_ROOT:-}" ] && [ -d /run/systemd/system ]; then
    if systemctl --quiet is-active nginx.service; then
        policy=0
        if [ -x /usr/sbin/policy-rc.d ]; then
            /usr/sbin/policy-rc.d nginx.service restart || policy=\$?
        fi
        case "\$policy" in
            0|104)
                upgrade=0
                /usr/lib/nginx/nginx-upgrade || upgrade=\$?
                case "\$upgrade" in
                    0|3) ;;
                    2)
                        echo "Seamless Nginx upgrade is not possible; restarting nginx.service" >&2
                        if ! deb-systemd-invoke restart nginx.service; then
                            echo "Error: Could not restart nginx.service; fix the error and run dpkg --configure -a" >&2
                            exit 1
                        fi
                        ;;
                    4)
                        echo "Error: Nginx still runs the previous binary; run dpkg --configure -a after the previous upgrade finishes draining connections" >&2
                        exit 1
                        ;;
                    *)
                        echo "Error: Nginx still runs the previous binary; fix the error above and run dpkg --configure -a" >&2
                        exit 1
                        ;;
                esac
                ;;
            *)
                echo "policy-rc.d deferred the Nginx upgrade; run /usr/lib/nginx/nginx-upgrade to activate the new binary"
                ;;
        esac
    fi
fi

exit 0
EOF

chmod +x debian/$PACKAGE_NAME.postinst

mkdir -p debian/service
install -m 0755 /build/nginx-upgrade debian/service/nginx-upgrade
cat > debian/service/nginx.service << EOF
[Unit]
Description=A high performance web server and a reverse proxy server
Documentation=man:nginx(8)
After=network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
LimitNOFILE=65535
Restart=always
RestartSec=5
ExecStartPre=/usr/sbin/nginx -t -q -g 'daemon on; master_process on;'
ExecStart=/usr/sbin/nginx -g 'daemon on; master_process on;'
ExecReload=/usr/sbin/nginx -g 'daemon on; master_process on;' -s reload
ExecStop=-/sbin/start-stop-daemon --quiet --stop --retry QUIT/30 --pidfile /run/nginx.pid
TimeoutStopSec=35
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF

mkdir -p debian/config
cat > debian/config/nginx.logrotate << 'EOF'
/var/log/nginx/*.log
/var/log/nginx/*_log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 www-data adm
    sharedscripts
    postrotate
        if [ -s /run/nginx.pid ]; then
            kill -USR1 "$(cat /run/nginx.pid)"
        fi
    endscript
}
EOF

mkdir -p usr/share/lua/5.1/resty
mkdir -p usr/share/lua/5.1/ngx

cp -r "$DEB_DIR/modules/lua-resty-core/lib/resty" usr/share/lua/5.1/
cp -r "$DEB_DIR/modules/lua-resty-lrucache/lib/resty" usr/share/lua/5.1/

cat > debian/$PACKAGE_NAME.install << EOF
debian/tmp/usr/sbin/nginx usr/sbin/
debian/tmp/etc/nginx/* etc/nginx/
debian/tmp/usr/share/nginx/html/* usr/share/nginx/html/
debian/service/nginx.service lib/systemd/system/
debian/service/nginx-upgrade usr/lib/nginx/
debian/config/nginx.logrotate etc/logrotate.d/
usr/share/lua/5.1/* usr/share/lua/5.1/
debian/tmp/usr/lib/nginx/modules/*.so usr/lib/nginx/modules/
debian/tmp/usr/lib/nginx/luajit/* usr/lib/nginx/luajit/
EOF

cat > debian/$PACKAGE_NAME.dirs << EOF
etc/nginx
etc/nginx/conf.d
etc/nginx/modules-available
etc/nginx/modules-enabled
usr/share/nginx/html
usr/share/lua/5.1
usr/share/lua/5.1/resty
usr/share/lua/5.1/ngx
usr/lib/nginx/modules
usr/lib/nginx/luajit
var/lib/nginx/body
var/lib/nginx/fastcgi
var/lib/nginx/proxy
var/lib/nginx/scgi
var/lib/nginx/uwsgi
var/log/nginx
EOF

if [ -d "$BUILD_DIR/man" ]; then
    cat > debian/$PACKAGE_NAME.manpages << EOF
man/nginx.8
EOF
fi

cd "$BUILD_DIR"
echo "Building package..."
dpkg-buildpackage -b -uc -us
cd /build

PACKAGE_ARCH=$(dpkg --print-architecture)
PACKAGE_FILE="${PACKAGE_NAME}_${PACKAGE_VERSION}_${PACKAGE_ARCH}.deb"
PACKAGE_FILES=("$PACKAGE_FILE")
for legacy_codename in "${LEGACY_CODENAMES[@]}"; do
    PACKAGE_FILES+=("${PACKAGE_NAME}-${legacy_codename}_${PACKAGE_VERSION}_${PACKAGE_ARCH}.deb")
done

for package_file in "${PACKAGE_FILES[@]}"; do
    if [ ! -f "/build/$package_file" ]; then
        echo "Package not found: /build/$package_file" >&2
        exit 1
    fi
    cp "/build/$package_file" "$TARGET_DIR/"
done

printf '%s\n' "$PACKAGE_FILE" > "$TARGET_DIR/package-file.txt"
printf '%s\n' "${PACKAGE_FILES[@]}" > "$TARGET_DIR/package-files.txt"

echo "=== Nginx binary info ===" > "$TARGET_DIR/build-info.txt"
egrep -ao '.,.,.,[01]+' "$BUILD_DIR/objs/nginx" >> "$TARGET_DIR/build-info.txt" 2>&1
"$BUILD_DIR/objs/nginx" -V >> "$TARGET_DIR/build-info.txt" 2>&1
cat /etc/*release >> "$TARGET_DIR/build-info.txt" 2>&1

echo "Done. Packages are in $TARGET_DIR:"
ls -la "$TARGET_DIR"
