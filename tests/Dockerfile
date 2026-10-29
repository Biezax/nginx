ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

RUN apt-get update && apt-get install -y --no-install-recommends \
    systemd systemd-sysv dbus procps python3 python3-h2 openssl \
    && rm -f /usr/sbin/policy-rc.d \
    && rm -rf /var/lib/apt/lists/*

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
