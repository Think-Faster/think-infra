FROM debian:13

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y \
        samba \
        samba-ad-provision \
        samba-dsdb-modules \
        smbclient \
        krb5-user \
        ldap-utils \
        dnsutils \
        iproute2 \
        procps \
        && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 53/tcp
EXPOSE 53/udp
EXPOSE 88/tcp
EXPOSE 88/udp
EXPOSE 389/tcp
EXPOSE 389/udp
EXPOSE 445/tcp
EXPOSE 464/tcp
EXPOSE 464/udp
EXPOSE 636/tcp
EXPOSE 3268/tcp
EXPOSE 3269/tcp

ENTRYPOINT ["/entrypoint.sh"]