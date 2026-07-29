#!/usr/bin/env bash
#
# Instalador da stack Plex + qBittorrent + Cloudflare Tunnel.
#
#   curl -fsSL https://raw.githubusercontent.com/t00ls-dev/plexden/main/install.sh | sudo bash
#
# Parametrizavel por variaveis de ambiente:
#   PLEXDEN_HOME   diretorio persistente da stack    (pergunta durante a instalacao,
#                  default /srv/plexden — passe por env para pular a pergunta)
#   PLEXDEN_REPO   owner/repo no GitHub              (default t00ls-dev/plexden)
#   PLEXDEN_BRANCH branch                            (default main)
#   PLEXDEN_RAW    origem dos arquivos               (default raw.githubusercontent)
#                  aceita qualquer coisa que o curl entenda, inclusive file://
#                  — util para instalar de um clone local ou de um espelho.
#
# O usuario que roda os servicos NAO e mais escolhido por variavel: e sempre
# quem esta executando a instalacao (quem chamou o 'sudo', ou o proprio root
# se voce ja esta numa sessao root).
#
set -euo pipefail

REPO="${PLEXDEN_REPO:-t00ls-dev/plexden}"
BRANCH="${PLEXDEN_BRANCH:-main}"
RAW="${PLEXDEN_RAW:-https://raw.githubusercontent.com/${REPO}/${BRANCH}}"

if [ "$(id -u)" -ne 0 ]; then
    echo "rode como root:  curl -fsSL ${RAW}/install.sh | sudo bash" >&2
    exit 1
fi

# O usuario da stack e sempre quem esta rodando a instalacao: quem chamou
# 'sudo' (SUDO_USER) ou, se ja e uma sessao root direta (sem sudo — e o caso
# tipico de containers/CI), o proprio root.
PLEXDEN_USER="${SUDO_USER:-$(id -un)}"

# PLEXDEN_HOME e perguntado interativamente — passar a variavel de ambiente
# pula a pergunta (util para automacao/CI). Sem terminal disponivel (pipe sem
# tty controlador), cai no default sem travar a instalacao. O '2>/dev/null'
# vem antes do '</dev/tty' de proposito: redirecoes sao aplicadas na ordem em
# que aparecem, entao so assim a falha de abrir /dev/tty fica muda.
if [ -z "${PLEXDEN_HOME:-}" ]; then
    if read -r -p "Onde a stack deve viver? [/srv/plexden] " resposta 2>/dev/null </dev/tty; then
        PLEXDEN_HOME="${resposta:-/srv/plexden}"
    else
        PLEXDEN_HOME=/srv/plexden
    fi
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
    else echo "instale 'curl' manualmente e rode de novo." >&2; exit 1
    fi
    command -v curl >/dev/null 2>&1 || { echo "falha ao instalar curl." >&2; exit 1; }
}
ensure_curl

echo "== Baixando plexden + provision.sh de ${RAW} =="
mkdir -p "${PLEXDEN_HOME}/scripts"
# --max-time e obrigatorio aqui: sem limite, uma rede lenta ou um proxy que
# engole a conexao travam a instalacao logo no primeiro download, antes de
# qualquer coisa aparecer na tela.
curl -fsSL --max-time 60 "${RAW}/plexden"                -o "${PLEXDEN_HOME}/scripts/plexden"
curl -fsSL --max-time 60 "${RAW}/provision.sh"           -o "${PLEXDEN_HOME}/provision.sh"
curl -fsSL --max-time 60 "${RAW}/credentials.env.example" -o "${PLEXDEN_HOME}/credentials.env.example"
chmod +x "${PLEXDEN_HOME}/scripts/plexden" "${PLEXDEN_HOME}/provision.sh"

echo "== Provisionando (HOME=${PLEXDEN_HOME}, usuario=${PLEXDEN_USER}) =="
export PLEXDEN_HOME PLEXDEN_USER
bash "${PLEXDEN_HOME}/provision.sh"

# O provision.sh ja pergunta essas tres coisas na hora, se rodou com terminal
# interativo (ver a secao "Assistente interativo" nele). Aqui so sobra
# lembrar do que, por falta de tty ou por a pessoa ter pulado, ainda nao foi
# resolvido — nunca repetir o que ja esta feito.
PENDENTE=""
if [ ! -f "${PLEXDEN_HOME}/credentials.env" ]; then
    PENDENTE="${PENDENTE}
 qBittorrent sem credenciais da WebUI:
      cp ${PLEXDEN_HOME}/credentials.env.example ${PLEXDEN_HOME}/credentials.env
      chmod 600 ${PLEXDEN_HOME}/credentials.env   # edite QB_USER / QB_PASS
      sudo ${PLEXDEN_HOME}/provision.sh           # regenera ~/.qbcreds
"
fi
CLAIMED_ATUAL=$( (curl -s --max-time 5 http://127.0.0.1:32400/identity 2>/dev/null | grep -o 'claimed="[01]"') || true)
if [ "$CLAIMED_ATUAL" != 'claimed="1"' ]; then
    PENDENTE="${PENDENTE}
 Plex ainda nao reivindicado:
      # pegue um token em https://plex.tv/claim (validade 4 min) e:
      curl -s -X POST 'http://127.0.0.1:32400/myplex/claim?token=SEU_TOKEN'
      sudo plexden services restart
"
fi
if [ ! -f "${PLEXDEN_HOME}/cloudflared/config.yml" ]; then
    PENDENTE="${PENDENTE}
 Cloudflare Tunnel (opcional) ainda nao configurado: rode de novo o
 provision.sh num terminal interativo, ou veja a secao Tunnel do README.
"
fi

echo
echo "============================================================================"
if [ -n "$PENDENTE" ]; then
    echo " Software instalado. Falta configurar (rode de novo o provision.sh num"
    echo " terminal interativo pra ser perguntado, ou faca na mao):"
    echo "$PENDENTE"
else
    echo " Pronto — qBittorrent, Plex e Cloudflare Tunnel ja configurados."
    echo
fi
echo " Comandos:"
echo "      plexden services status"
echo "      plexden qb list"
echo "============================================================================"
