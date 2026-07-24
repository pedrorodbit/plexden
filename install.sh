#!/usr/bin/env bash
#
# Instalador da stack Plex + qBittorrent + Cloudflare Tunnel.
#
#   curl -fsSL https://raw.githubusercontent.com/pedrorodbit/plexctl/main/install.sh | sudo bash
#
# Parametrizavel por variaveis de ambiente:
#   PLEXCTL_HOME   diretorio persistente da stack   (default /var/www/html/plex)
#   PLEXCTL_USER   usuario que roda os servicos      (default plex)
#   PLEXCTL_REPO   owner/repo no GitHub              (default pedrorodbit/plexctl)
#   PLEXCTL_BRANCH branch                            (default main)
#
#   curl -fsSL .../install.sh | sudo PLEXCTL_HOME=/srv/plex PLEXCTL_USER=media bash
#
set -euo pipefail

REPO="${PLEXCTL_REPO:-pedrorodbit/plexctl}"
BRANCH="${PLEXCTL_BRANCH:-main}"
RAW="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
PLEXCTL_HOME="${PLEXCTL_HOME:-/var/www/html/plex}"
PLEXCTL_USER="${PLEXCTL_USER:-plex}"

if [ "$(id -u)" -ne 0 ]; then
    echo "rode como root:  curl -fsSL ${RAW}/install.sh | sudo bash" >&2
    exit 1
fi

command -v curl >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq curl; }

echo "== Baixando plexctl + provision.sh de ${REPO}@${BRANCH} =="
mkdir -p "${PLEXCTL_HOME}/scripts"
curl -fsSL "${RAW}/plexctl"                -o "${PLEXCTL_HOME}/scripts/plexctl"
curl -fsSL "${RAW}/provision.sh"           -o "${PLEXCTL_HOME}/provision.sh"
curl -fsSL "${RAW}/credentials.env.example" -o "${PLEXCTL_HOME}/credentials.env.example"
chmod +x "${PLEXCTL_HOME}/scripts/plexctl" "${PLEXCTL_HOME}/provision.sh"

echo "== Provisionando (HOME=${PLEXCTL_HOME}, usuario=${PLEXCTL_USER}) =="
PLEXCTL_HOME="${PLEXCTL_HOME}" PLEXCTL_USER="${PLEXCTL_USER}" \
    bash "${PLEXCTL_HOME}/provision.sh"

cat <<EOF

============================================================================
 Software instalado. Faltam os SEGREDOS (nunca ficam no repositorio):

 1) qBittorrent — credenciais da WebUI:
      cp ${PLEXCTL_HOME}/credentials.env.example ${PLEXCTL_HOME}/credentials.env
      chmod 600 ${PLEXCTL_HOME}/credentials.env
      # edite QB_USER / QB_PASS, depois:
      sudo ${PLEXCTL_HOME}/provision.sh      # regenera ~/.qbcreds

 2) Plex — claim (servidor novo aparece como nao reivindicado):
      # pegue um token em https://plex.tv/claim (validade 4 min) e:
      curl -s -X POST "http://127.0.0.1:32400/myplex/claim?token=SEU_TOKEN"
      sudo plexctl services restart

 3) Cloudflare Tunnel (opcional) — coloque as credenciais e reprovisione:
      # ${PLEXCTL_HOME}/cloudflared/{cert.pem, <UUID>.json, config.yml}
      sudo ${PLEXCTL_HOME}/provision.sh

 Comandos:
      sudo plexctl services status
      plexctl qb list
============================================================================
EOF
