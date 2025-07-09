# Building Nginx with Additional Modules

## Problem and Solution

### The Problem

In earlier versions of Ubuntu, the official repositories provided multiple Nginx package variants with different module sets:
- `nginx-light` - minimal build with basic modules
- `nginx-full` - standard build with most common modules  
- `nginx-extras` - extended build with additional modules
- `nginx-core` - core functionality only

However, in current Ubuntu versions (22.04+ and especially 24.04), this variety has been significantly reduced. Users who need specific additional modules (like Lua scripting, RTMP streaming, advanced load balancing, or specialized authentication) often find themselves having to compile Nginx from source manually, which is time-consuming and doesn't integrate well with the system package management.

### The Solution

This project provides an automated solution that:
- **Builds custom Nginx packages** with a comprehensive set of additional modules
- **Maintains Ubuntu package standards** - the resulting packages integrate seamlessly with apt and system management
- **Offers flexibility** - easy to modify the build script to include/exclude specific modules based on your needs
- **Ensures compatibility** - uses standard Ubuntu paths and conventions, making it a drop-in replacement
- **Provides version-specific packages** - separate builds for different Ubuntu versions ensure optimal compatibility

The resulting packages (`nginx-custom-jammy`, `nginx-custom-noble`) can be installed and managed just like official Ubuntu packages, but with the extended functionality that was previously available in nginx-extras and more.

This script is designed to build Nginx with additional modules for Ubuntu 22.04 (jammy) and 24.04 (noble), creating Debian packages that can be installed using standard apt tools.

## Features

- Automatic detection of the latest stable Nginx version
- Building with additional modules not included in official Ubuntu packages
- Creating separate packages for different Ubuntu versions (`nginx-custom-jammy`, `nginx-custom-noble`)
- Compliance with Debian/Ubuntu package standards
- Uses standard file paths for compatibility with the Ubuntu ecosystem

## Pre-installed Modules:

The build includes the following additional modules:

| Module | Description |
|--------|-------------|
| headers-more-filter | Managing HTTP request/response headers |
| auth-pam | Authentication via PAM |
| cache-purge | Cache purging |
| dav-ext | Extended WebDAV support |
| ndk | Nginx Development Kit |
| echo | Request debugging and testing |
| fancyindex | Enhanced directory listing |
| nchan | Real-time Pub/Sub and push notifications |
| lua | Lua scripting support with LuaJIT |
| rtmp | Streaming (RTMP) |
| uploadprogress | File upload progress tracking |
| subs-filter | Text substitution in server responses |
| geoip2 | IP geolocation via MaxMind GeoIP2 |
| upstream-fair | Load balancing algorithm considering server load |

## Module Organization

All modules are loaded dynamically and managed through a configuration file system in directories:
- `/etc/nginx/modules-available/` - available modules
- `/etc/nginx/modules-enabled/` - activated modules (symbolic links)

Each module has its own configuration file with a numeric prefix that determines loading priority:
- **10-** - basic modules (e.g., NDK)
- **20-** - main functional modules (headers-more, auth-pam, upstream-fair, etc.)
- **30-** - additional and specialized modules (lua, rtmp, geoip2, etc.)

To enable/disable a module, simply create or remove the corresponding symbolic link:
```bash
# Enable module
ln -sf ../modules-available/20-upstream-fair.conf /etc/nginx/modules-enabled/

# Disable module
rm /etc/nginx/modules-enabled/20-upstream-fair.conf
```

## Standard Nginx Modules

The build includes all core Nginx modules, including:
- HTTP SSL, HTTP/2, HTTP realip
- HTTP stub_status, HTTP addition, HTTP sub
- HTTP auth_request, HTTP dav, HTTP flv
- HTTP gunzip, HTTP gzip_static, HTTP mp4
- HTTP random_index, HTTP secure_link, HTTP slice
- Mail and Mail SSL
- Stream with SSL and realip support

All modules are statically compiled into the executable for maximum performance.

## Usage

### Building Packages

**Note**: A profile must be specified. Without a profile, no services will be started.

```bash
# Build all packages (all Ubuntu versions)
docker compose --profile all up --build

# Build specific Ubuntu version using profiles
docker compose --profile ubuntu22 up --build   # Only Ubuntu 22.04
docker compose --profile ubuntu24 up --build   # Only Ubuntu 24.04
docker compose --profile ubuntu20 up --build   # Only Ubuntu 20.04

# Build multiple versions
docker compose --profile ubuntu22 --profile ubuntu24 up --build

# Build with LTO disabled (to solve compatibility issues on ARM)
DISABLE_LTO=1 docker compose --profile ubuntu24 up --build

# Build with custom package name
PACKAGE_BASE_NAME=my-nginx docker compose --profile ubuntu22 up --build
```

### Build Parameters

| Parameter | Description | Default Value |
|-----------|-------------|---------------|
| --profile | Selects specific Ubuntu version to build (ubuntu20, ubuntu22, ubuntu24, all) | No default profile |
| DISABLE_LTO | Disables Link Time Optimization to solve compilation issues on ARM | 0 (enabled) |
| NGINX_VERSION | Nginx version to build | Automatically detects latest stable version |
| PACKAGE_BASE_NAME | Base package name (final name will be {base_name}-{ubuntu_codename}) | nginx-custom |
| PACKAGE_REVISION | Package revision | Generated based on date and time (YYYYMMDDHHMM) |

### Package Installation

```bash
# For Ubuntu 22.04
apt install ./nginx-custom-jammy_*.deb

# For Ubuntu 24.04
apt install ./nginx-custom-noble_*.deb
```

## Installation Notes
- The package conflicts with standard Nginx packages in Ubuntu (`nginx`, `nginx-core`, `nginx-full`, `nginx-light`, `nginx-extras`, `nginx-mainline`). Installing any of these packages will remove them.
- The package uses standard file paths and will work as a replacement for standard Nginx:
  - Executable file: `/usr/sbin/nginx`
  - Modules: `/usr/lib/nginx/modules/*.so`
  - Configuration: `/etc/nginx/nginx.conf`
  - Logs: `/var/log/nginx/`
  - Temporary directories: `/var/lib/nginx/`

## Troubleshooting

### LTO Compilation Errors

On some architectures (especially ARM), compilation errors may occur when using Link Time Optimization (LTO). If you encounter such errors, try building with LTO disabled:

```bash
# For all versions
DISABLE_LTO=1 docker compose --profile all up --build

# For specific Ubuntu version
DISABLE_LTO=1 docker compose --profile ubuntu24 up --build
```

### Installation Conflicts

If installation errors occur due to conflicts with existing files, make sure all official Nginx packages are removed:

```bash
apt purge nginx nginx-core nginx-full nginx-light nginx-extras nginx-mainline
apt autoremove
```

## Package Structure

The created package follows Debian standards and includes:
- Correct control file with dependencies
- Postinst script for setting up access permissions
- Changelog with change history 