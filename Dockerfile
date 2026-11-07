# KubePivot — Kali-based pentest access pod for Kubernetes
# SSH (public-key only) tunnelled over WebSocket/TLS (Apache + wstunnel).
FROM kalilinux/kali-rolling

ARG DEBIAN_FRONTEND=noninteractive
ARG WSTUNNEL_VERSION=10.5.0
# Unprivileged user that owns the SSH session. Change it here if you want a
# different login name (it is baked at build time and must match sshd_config).
ARG USERNAME=pentester
ARG USER_UID=1000
ARG USER_GID=1000
ENV HOME=/home/${USERNAME}

# --- Base packages + a default pentest toolset -------------------------------
# Trim or extend this list to taste; it only affects image size.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    openssh-server apache2 ca-certificates openssl procps curl wget gnupg \
    iproute2 nano binutils tmux nmap sqlmap ffuf python3 python3-pip \
    git dirsearch wfuzz proxychains4 bloodhound sudo net-tools masscan jq \
    socat unzip golang-go netcat-openbsd python3-venv \
 && rm -rf /var/lib/apt/lists/*

# --- Unprivileged user (sudo NOPASSWD so tools that need root still work) -----
# NOTE: NOPASSWD:ALL effectively gives this login full root inside the pod.
# That is intentional for a pentest box, but see the README security notes.
RUN groupadd -g ${USER_GID} ${USERNAME} \
 && useradd -m -u ${USER_UID} -g ${USER_GID} -s /bin/bash ${USERNAME} \
 && usermod -aG sudo ${USERNAME} \
 && printf "%s ALL=(ALL) NOPASSWD:ALL\n" "${USERNAME}" >/etc/sudoers.d/99-${USERNAME} \
 && chmod 440 /etc/sudoers.d/99-${USERNAME}

# --- wstunnel ----------------------------------------------------------------
RUN wget -O /tmp/wstunnel.tar.gz \
    "https://github.com/erebe/wstunnel/releases/download/v${WSTUNNEL_VERSION}/wstunnel_${WSTUNNEL_VERSION}_linux_amd64.tar.gz" \
 && tar -xzf /tmp/wstunnel.tar.gz -C /usr/local/bin wstunnel \
 && chmod +x /usr/local/bin/wstunnel \
 && rm /tmp/wstunnel.tar.gz

# --- Writable runtime tree (the user is non-root, so pre-create & chown) ------
RUN mkdir -p \
      /writable/etc/ssh \
      /writable/etc/apache \
      /writable/var/log/apache \
      /writable/var/run/apache \
      /writable/var/run/sshd \
      /writable/var/lock/apache \
      /pentest \
      /etc/kubepivot/ssh \
 && chown -R ${USERNAME}:${USERNAME} /writable /pentest \
 && chmod -R 755 /writable /pentest

# --- Apache: enable proxy/ws modules, listen only on 8443 --------------------
RUN a2enmod ssl proxy proxy_wstunnel headers || true \
 && a2dissite 000-default.conf default-ssl || true \
 && sed -ri 's/^\s*Listen 80\b/#&/; s/^\s*Listen 443\b/#&/' /etc/apache2/ports.conf \
 && (grep -q "^Listen 8443$" /etc/apache2/ports.conf || echo "Listen 8443" >> /etc/apache2/ports.conf)

# --- Project files -----------------------------------------------------------
COPY docker/apache-vhost.conf /etc/apache2/sites-available/001-wss-tunnel.conf
RUN a2ensite 001-wss-tunnel.conf || true
COPY docker/apache-envvars  /writable/etc/apache/envvars
COPY docker/sshd_config     /writable/etc/ssh/sshd_config
COPY docker/entrypoint.sh   /pentest/entrypoint.sh
COPY docker/ws_tunnel.sh    /pentest/ws_tunnel.sh
RUN chmod +x /pentest/*.sh

# Authorized keys are NOT baked into the image. They are mounted at runtime
# from a Kubernetes Secret at /etc/kubepivot/ssh/authorized_keys (see k8s/).
# Prepare an empty, correctly-permissioned home .ssh anyway.
RUN install -d -m 700 -o ${USERNAME} -g ${USERNAME} /home/${USERNAME}/.ssh \
 && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME} /pentest /writable

EXPOSE 8443 2222 30000

USER ${USERNAME}
WORKDIR /home/${USERNAME}

ENTRYPOINT ["/pentest/entrypoint.sh"]
