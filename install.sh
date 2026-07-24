#!/usr/bin/env bash
#
# Instalador da stack Plex + qBittorrent + Cloudflare Tunnel.
#
#   curl -fsSL https://raw.githubusercontent.com/pedrorodbit/plexden/main/install.sh | sudo bash
#
# Parametrizavel por variaveis de ambiente:
#   PLEXDEN_HOME   diretorio persistente da stack   (default /var/www/html/plex)
#   PLEXDEN_USER   usuario que roda os servicos      (default plex)
#   PLEXDEN_REPO   owner/repo no GitHub              (default pedrorodbit/plexden)
#   PLEXDEN_BRANCH branch                            (default main)
#
#   curl -fsSL .../install.sh | sudo PLEXDEN_HOME=/srv/plex PLEXDEN_USER=media bash
#
set -euo pipefail

REPO="${PLEXDEN_REPO:-pedrorodbit/plexden}"
BRANCH="${PLEXDEN_BRANCH:-main}"
RAW="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
PLEXDEN_HOME="${PLEXDEN_HOME:-/srv/plexden}"
PLEXDEN_USER="${PLEXDEN_USER:-plex}"

if [ "$(id -u)" -ne 0 ]; then
    echo "rode como root:  curl -fsSL ${RAW}/install.sh | sudo bash" >&2
    exit 1
fi

# O install.sh so precisa de curl (o provision.sh depois cuida do resto, ja de
# forma multi-distro). Normalmente o curl ja existe — foi ele que baixou este
# script. Mas se alguem rodar apos baixar por outro meio, tentamos instalar pelo
# gerenciador da distro, sem assumir apt.
ensure_curl() {
    command -v curl >/dev/null 2>&1 && return 0
    echo "== curl ausente — tentando instalar =="
    if   command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y -qq curl
    elif command -v dnf     >/dev/null 2>&1; then dnf install -y -q curl
    elif command -v yum     >/dev/null 2>&1; then yum install -y -q curl
    elif command -v pacman  >/dev/null 2>&1; then pacman -Sy --noconfirm --needed curl
    elif command -v zypper  >/dev/null 2>&1; then zypper -n install curl
    else echo "instale 'curl' manualmente e rode de novo." >&2; exit 1
    fi
    command -v curl >/dev/null 2>&1 || { echo "falha ao instalar curl." >&2; exit 1; }
}
ensure_curl

echo "== Baixando plexden + provision.sh de ${REPO}@${BRANCH} =="
mkdir -p "${PLEXDEN_HOME}/scripts"
curl -fsSL "${RAW}/plexden"                -o "${PLEXDEN_HOME}/scripts/plexden"
curl -fsSL "${RAW}/provision.sh"           -o "${PLEXDEN_HOME}/provision.sh"
curl -fsSL "${RAW}/credentials.env.example" -o "${PLEXDEN_HOME}/credentials.env.example"
chmod +x "${PLEXDEN_HOME}/scripts/plexden" "${PLEXDEN_HOME}/provision.sh"

echo "== Provisionando (HOME=${PLEXDEN_HOME}, usuario=${PLEXDEN_USER}) =="
export PLEXDEN_HOME PLEXDEN_USER
bash "${PLEXDEN_HOME}/provision.sh"

cat <<EOF

============================================================================
 Software instalado. Faltam os SEGREDOS (nunca ficam no repositorio):

 1) qBittorrent — credenciais da WebUI:
      cp ${PLEXDEN_HOME}/credentials.env.example ${PLEXDEN_HOME}/credentials.env
      chmod 600 ${PLEXDEN_HOME}/credentials.env
      # edite QB_USER / QB_PASS, depois:
      sudo ${PLEXDEN_HOME}/provision.sh      # regenera ~/.qbcreds

 2) Plex — claim (servidor novo aparece como nao reivindicado):
      # pegue um token em https://plex.tv/claim (validade 4 min) e:
      curl -s -X POST "http://127.0.0.1:32400/myplex/claim?token=SEU_TOKEN"
      sudo plexden services restart

 3) Cloudflare Tunnel (opcional) — coloque as credenciais e reprovisione:
      # ${PLEXDEN_HOME}/cloudflared/{cert.pem, <UUID>.json, config.yml}
      sudo ${PLEXDEN_HOME}/provision.sh

 Comandos:
      sudo plexden services status
      plexden qb list
============================================================================
EOF
