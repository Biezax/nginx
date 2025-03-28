#!/bin/bash
set -e

BUILD_DIR="/build/nginx-debian"
TARGET_DIR="/output"
DEB_DIR="$BUILD_DIR"
NGINX_VERSION=${NGINX_VERSION:-$(curl -s https://nginx.org/en/download.html | grep -oP '(?<=nginx-)([0-9]+\.[0-9]+\.[0-9]+)(?=\.tar\.gz)' | sort -V | tail -1)}

UBUNTU_VERSION=$(lsb_release -rs)
UBUNTU_CODENAME=$(lsb_release -cs)

PACKAGE_NAME="nginx-consultant-$UBUNTU_CODENAME"
PACKAGE_REVISION=$(date +%Y%m%d%H%M)

export LUAJIT_LIB=/usr/lib/x86_64-linux-gnu
export LUAJIT_INC=/usr/include/luajit-2.1

echo "Building nginx version $NGINX_VERSION for Ubuntu $UBUNTU_VERSION ($UBUNTU_CODENAME)"
echo "Package name: $PACKAGE_NAME"
echo "Package revision: $PACKAGE_REVISION"
echo "Using LuaJIT: lib=$LUAJIT_LIB, inc=$LUAJIT_INC"

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
mkdir -p modules

echo "Downloading modules..."
cd "$DEB_DIR/modules"

# Modules
git clone https://github.com/openresty/headers-more-nginx-module http-headers-more-filter
git clone https://github.com/sto/ngx_http_auth_pam_module http-auth-pam
git clone https://github.com/Danrancan/ngx_cache_purge_dynamic http-cache-purge
git clone https://github.com/arut/nginx-dav-ext-module http-dav-ext
git clone https://github.com/vision5/ngx_devel_kit http-ndk
git clone https://github.com/openresty/echo-nginx-module http-echo
git clone https://github.com/aperezdc/ngx-fancyindex http-fancyindex
git clone https://github.com/slact/nchan
git clone https://github.com/openresty/lua-nginx-module http-lua
git clone https://github.com/arut/nginx-rtmp-module rtmp
git clone https://github.com/masterzen/nginx-upload-progress-module http-uploadprogress
git clone https://github.com/yaoweibin/ngx_http_substitutions_filter_module http-subs-filter
git clone https://github.com/leev/ngx_http_geoip2_module http-geoip2

# Additional libraries required for Lua
git clone https://github.com/openresty/lua-resty-core
git clone https://github.com/openresty/lua-resty-lrucache

cd "$BUILD_DIR"
mkdir -p debian/source
mkdir -p debian/modules

echo "Preparing Debian package structure..."

# debian/source/format
mkdir -p debian/source
echo "3.0 (quilt)" > debian/source/format

# debian/control
cat > debian/control << EOF
Source: nginx
Section: httpd
Priority: optional
Maintainer: Stanislav Rossovskii <custom@example.com>
Build-Depends: debhelper-compat (= 13),
 libpcre3-dev, zlib1g-dev, libssl-dev, 
 libxml2-dev, libxslt1-dev, libgd-dev, libgeoip-dev, libperl-dev,
 libpam0g-dev, libmaxminddb-dev, libldap2-dev, liblua5.3-dev | liblua5.4-dev,
 pkg-config, libbrotli-dev, po-debconf
Standards-Version: 4.6.2
Homepage: https://nginx.org
Rules-Requires-Root: no

Package: $PACKAGE_NAME
Architecture: amd64
Depends: \${shlibs:Depends}, \${misc:Depends}, iproute2, logrotate
Provides: httpd, nginx
Conflicts: nginx, nginx-light, nginx-full, nginx-extras, nginx-core, nginx-mainline
Replaces: nginx, nginx-light, nginx-full, nginx-extras, nginx-core, nginx-mainline
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
  * echo - debugging and testing
  * fancyindex - enhanced directory listings
  * nchan - pub/sub and push notifications
  * lua - Lua scripting support
  * rtmp - streaming media
  * uploadprogress - file upload progress
  * subs-filter - response text substitution
  * geoip2 - MaxMind GeoIP2 support
EOF

cat > debian/changelog << EOF
nginx ($NGINX_VERSION-1ubuntu$UBUNTU_VERSION.$PACKAGE_REVISION) $UBUNTU_CODENAME; urgency=medium

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
	--prefix=/usr \\
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
	--add-dynamic-module=\$(BASEDIR)/modules/http-echo \\
	--add-dynamic-module=\$(BASEDIR)/modules/http-fancyindex \\
	--add-dynamic-module=\$(BASEDIR)/modules/nchan \\
	--add-dynamic-module=\$(BASEDIR)/modules/http-lua \\
	--add-dynamic-module=\$(BASEDIR)/modules/rtmp \\
	--add-dynamic-module=\$(BASEDIR)/modules/http-uploadprogress \\
	--add-dynamic-module=\$(BASEDIR)/modules/http-subs-filter \\
	--add-dynamic-module=\$(BASEDIR)/modules/http-geoip2

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
	mkdir -p debian/tmp/var/lib/nginx/body || { echo "Error creating body directory"; exit 1; }
	chmod 755 debian/tmp/var/lib/nginx/body
	chown www-data:www-data debian/tmp/var/lib/nginx/body
	mkdir -p debian/tmp/usr/share/nginx/html
	if [ -d debian/tmp/usr/html ]; then \
		echo "HTML directory found, copying files..."; \
		cp -r debian/tmp/usr/html/* debian/tmp/usr/share/nginx/html/ 2>/dev/null || true; \
		echo "HTML files processed"; \
		rm -rf debian/tmp/usr/html; \
	else \
		echo "No HTML directory found at debian/tmp/usr/html"; \
	fi

override_dh_installsystemd:
	dh_installsystemd --name=nginx

override_dh_installinit:
	dh_installinit --name=nginx --no-stop-on-upgrade --no-start

override_dh_installlogrotate:
	dh_installlogrotate --name=nginx

override_dh_shlibdeps:
	dh_shlibdeps -l${LUAJIT_LIB}

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
    cat > /etc/nginx/modules-available/00-dynamic-modules.conf << EOFMODULES

# Headers More
load_module /usr/lib/nginx/modules/ngx_http_headers_more_filter_module.so;
# Auth PAM
load_module /usr/lib/nginx/modules/ngx_http_auth_pam_module.so;
# Cache Purge
load_module /usr/lib/nginx/modules/ngx_http_cache_purge_module.so;
# DAV Extended
load_module /usr/lib/nginx/modules/ngx_http_dav_ext_module.so;
# Development Kit
load_module /usr/lib/nginx/modules/ndk_http_module.so;
# Echo
load_module /usr/lib/nginx/modules/ngx_http_echo_module.so;
# Fancy Index
load_module /usr/lib/nginx/modules/ngx_http_fancyindex_module.so;
# NChan
load_module /usr/lib/nginx/modules/ngx_nchan_module.so;
# Lua
load_module /usr/lib/nginx/modules/ngx_http_lua_module.so;
# RTMP
load_module /usr/lib/nginx/modules/ngx_rtmp_module.so;
# Upload Progress
load_module /usr/lib/nginx/modules/ngx_http_uploadprogress_module.so;
# Substitutions Filter
load_module /usr/lib/nginx/modules/ngx_http_subs_filter_module.so;
# GeoIP2
load_module /usr/lib/nginx/modules/ngx_http_geoip2_module.so;
EOFMODULES

    mkdir -p /etc/nginx/modules-enabled
    ln -sf ../modules-available/00-dynamic-modules.conf /etc/nginx/modules-enabled/
fi

#DEBHELPER#

exit 0
EOF

chmod +x debian/$PACKAGE_NAME.postinst

# Create systemd service file
mkdir -p debian/service
cat > debian/service/nginx.service << EOF
[Unit]
Description=A high performance web server and a reverse proxy server
Documentation=man:nginx(8)
After=network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStartPre=/usr/sbin/nginx -t -q -g 'daemon on; master_process on;'
ExecStart=/usr/sbin/nginx -g 'daemon on; master_process on;'
ExecReload=/usr/sbin/nginx -g 'daemon on; master_process on;' -s reload
ExecStop=-/sbin/start-stop-daemon --quiet --stop --retry QUIT/5 --pidfile /run/nginx.pid
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF

# Create logrotate configuration
mkdir -p debian/config
cat > debian/config/nginx.logrotate << EOF
/var/log/nginx/*.log {
	daily
	missingok
	rotate 14
	compress
	delaycompress
	notifempty
	create 0640 www-data adm
	sharedscripts
	prerotate
		if [ -d /etc/logrotate.d/httpd-prerotate ]; then \\
			run-parts /etc/logrotate.d/httpd-prerotate; \\
		fi \\
	endscript
	postrotate
		invoke-rc.d nginx rotate >/dev/null 2>&1
	endscript
}
EOF

# Create directories for Lua libraries
mkdir -p usr/share/lua/5.1/resty
mkdir -p usr/share/lua/5.1/ngx

cp -r "$DEB_DIR/modules/lua-resty-core/lib/resty" usr/share/lua/5.1/
cp -r "$DEB_DIR/modules/lua-resty-lrucache/lib/resty" usr/share/lua/5.1/

cat > debian/$PACKAGE_NAME.install << EOF
debian/tmp/usr/sbin/nginx usr/sbin/
debian/tmp/etc/nginx/* etc/nginx/
debian/tmp/usr/share/nginx/html/* usr/share/nginx/html/
debian/service/nginx.service lib/systemd/system/
debian/config/nginx.logrotate etc/logrotate.d/
usr/share/lua/5.1/* usr/share/lua/5.1/
debian/tmp/usr/lib/nginx/modules/*.so usr/lib/nginx/modules/
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

cp /build/*.deb "$TARGET_DIR/"

echo "Done. Packages are in $TARGET_DIR:"
ls -la "$TARGET_DIR" 