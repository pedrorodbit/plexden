#!/bin/bash
#
# Provisiona Plex + qBittorrent + Cloudflare Tunnel neste container.
#
# Idempotente: pode rodar quantas vezes precisar. Tudo que importa (banco do
# Plex, midia, credenciais do tunnel) vive em /var/www/html/plex, que e um
# bind mount do disco do host — o resto do container e overlay e some.
#
#   sudo /var/www/html/plex/provision.sh
#
set -u

# Parametrizavel por variaveis de ambiente (defaults sensatos). Ex.:
#   sudo PLEXCTL_HOME=/srv/plex PLEXCTL_USER=media ./provision.sh
PERSIST="${PLEXCTL_HOME:-/var/www/html/plex}"
PLEX_USER="${PLEXCTL_USER:-plex}"
# UUID do tunnel: se vazio, e auto-detectado a partir de cloudflared/*.json.
TUNNEL_UUID="${CF_TUNNEL_UUID:-}"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
fail() { echo "ERRO: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "rode como root (sudo $0)"
# cria o usuario da stack se ainda nao existir
id "$PLEX_USER" >/dev/null 2>&1 || { useradd -m -s /bin/bash "$PLEX_USER" && log "usuario $PLEX_USER criado"; }
mountpoint -q "$PERSIST" 2>/dev/null || \
  grep -q " /var/www/html " /proc/mounts || \
  log "AVISO: /var/www/html nao aparece como mount — confirme que persiste!"

# ---------------------------------------------------------------- pacotes ---
log "== Pacotes =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

install_if_missing() {
    if dpkg -s "$1" >/dev/null 2>&1; then
        log "  $1 ja instalado"
    else
        log "  instalando $1"
        apt-get install -y -qq "$1" || fail "falha ao instalar $1"
    fi
}

for p in curl wget gnupg ca-certificates procps psmisc sudo qbittorrent-nox python3; do
    install_if_missing "$p"
done

# Plex (repositorio oficial)
if ! dpkg -s plexmediaserver >/dev/null 2>&1; then
    log "  instalando plexmediaserver"
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://downloads.plex.tv/plex-keys/PlexSign.key \
      | gpg --dearmor -o /etc/apt/keyrings/plex.gpg
    echo "deb [signed-by=/etc/apt/keyrings/plex.gpg] https://downloads.plex.tv/repo/deb public main" \
      > /etc/apt/sources.list.d/plexmediaserver.list
    apt-get update -qq
    apt-get install -y -qq plexmediaserver || fail "falha ao instalar plexmediaserver"
else
    log "  plexmediaserver ja instalado"
fi

# Cloudflared
if ! command -v cloudflared >/dev/null 2>&1; then
    log "  instalando cloudflared"
    curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
      -o /tmp/cf.deb || fail "download do cloudflared falhou"
    dpkg -i /tmp/cf.deb || apt-get -f install -y
else
    log "  cloudflared ja instalado"
fi

# ------------------------------------------------------------- diretorios ---
log "== Diretorios persistentes =="
mkdir -p "$PERSIST"/{movies,series,config,scripts,cloudflared} \
         "$PERSIST"/torrents/{complete,incomplete}
chown -R "$PLEX_USER:$PLEX_USER" "$PERSIST"
chmod 700 "$PERSIST/cloudflared"
log "  ok"

# ------------------------------------------------------------------ plex ----
log "== Plex =="
# A logica de ambiente do Plex (variaveis + exec do binario) vive agora em
# 'plexctl plex-exec'. ~/bin/plex-start e so um stub que chama o plexctl.
mkdir -p /home/"$PLEX_USER"/bin
cat > /home/"$PLEX_USER"/bin/plex-start <<'EOF'
#!/bin/sh
exec /usr/local/bin/plexctl plex-exec
EOF
chmod +x /home/"$PLEX_USER"/bin/plex-start
chown -R "$PLEX_USER:$PLEX_USER" /home/"$PLEX_USER"/bin

if [ -f "$PERSIST/config/Plex Media Server/Preferences.xml" ]; then
    log "  config existente encontrada — claim e bibliotecas preservados"
else
    log "  config nova: sera preciso claimar em https://plex.tv/claim (ver README)"
fi

# init script (stub SysV -> plexctl _init). O pacote do Plex o remove ao
# atualizar; o 'plexctl update' e este provision o recriam.
cat > /etc/init.d/plexmediaserver <<'EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          plexmediaserver
# Required-Start:    $network $remote_fs
# Required-Stop:     $network $remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Plex Media Server
### END INIT INFO
exec /usr/local/bin/plexctl _init "$@"
EOF
chmod 755 /etc/init.d/plexmediaserver
log "  init stub instalado"

# ----------------------------------------------------------- qbittorrent ----
log "== qBittorrent =="
QBCONF=/home/"$PLEX_USER"/.config/qBittorrent/qBittorrent.conf
if [ ! -f "$QBCONF" ]; then
    mkdir -p "$(dirname "$QBCONF")"
    # qBittorrent 4.5 le Session\DefaultSavePath (nao Downloads\SavePath, que e
    # legado e fica ignorado). AutoRun chama o 'plexctl postprocess' ao concluir.
    cat > "$QBCONF" <<EOF
[AutoRun]
enabled=true
program=/usr/local/bin/plexctl postprocess "%N" "%F"

[BitTorrent]
Session\\DefaultSavePath=$PERSIST/torrents/complete
Session\\TempPath=$PERSIST/torrents/incomplete
Session\\TempPathEnabled=true
Session\\QueueingSystemEnabled=false

[Preferences]
WebUI\\Port=8081
WebUI\\Username=admin
EOF
    chown -R "$PLEX_USER:$PLEX_USER" /home/"$PLEX_USER"/.config
    log "  config criada (login inicial: admin / adminadmin na 4.5.x)"
else
    log "  config ja existe — preservada"
fi

# ------------------------------------------------------------- cloudflared --
log "== Cloudflare Tunnel =="
# Se o UUID nao veio por env, auto-detecta pelo unico *.json em cloudflared/.
if [ -z "$TUNNEL_UUID" ]; then
    j=$(ls "$PERSIST"/cloudflared/*.json 2>/dev/null | head -1)
    [ -n "$j" ] && TUNNEL_UUID=$(basename "$j" .json)
fi
if [ -n "$TUNNEL_UUID" ] && [ -f "$PERSIST/cloudflared/cert.pem" ] && [ -f "$PERSIST/cloudflared/$TUNNEL_UUID.json" ]; then
    mkdir -p /etc/cloudflared
    cp "$PERSIST/cloudflared/config.yml"        /etc/cloudflared/
    cp "$PERSIST/cloudflared/cert.pem"          /etc/cloudflared/
    cp "$PERSIST/cloudflared/$TUNNEL_UUID.json" /etc/cloudflared/
    chmod 600 /etc/cloudflared/cert.pem /etc/cloudflared/*.json
    log "  credenciais restauradas do volume persistente"

    if [ ! -f /etc/init.d/cloudflared ]; then
        cloudflared service install >/dev/null 2>&1 && log "  servico instalado"
    else
        log "  servico ja instalado"
    fi
else
    log "  AVISO: credenciais do tunnel ausentes em $PERSIST/cloudflared/"
    log "         rode 'cloudflared tunnel login' e veja a secao Tunnel do README"
fi

# ------------------------------------------------------------ stack start ---
log "== Scripts de operacao =="
# Tudo unificado em 'plexctl' (Python). plex-stack-start e um stub para o
# entrypoint do container.
if [ -f "$PERSIST/scripts/plexctl" ]; then
    cp "$PERSIST/scripts/plexctl" /usr/local/bin/plexctl
    chmod 755 /usr/local/bin/plexctl
    log "  plexctl instalado"
else
    log "  AVISO: $PERSIST/scripts/plexctl ausente — stack nao vai subir"
fi
# grava a config que o plexctl le em runtime (caminho e usuario da stack)
cat > /etc/plexctl.conf <<EOF
PLEXCTL_HOME=$PERSIST
PLEXCTL_USER=$PLEX_USER
EOF
chmod 644 /etc/plexctl.conf
log "  /etc/plexctl.conf gravado ($PERSIST, usuario $PLEX_USER)"
cat > /usr/local/bin/plex-stack-start <<'EOF'
#!/bin/sh
exec /usr/local/bin/plexctl services start
EOF
chmod 755 /usr/local/bin/plex-stack-start
log "  plex-stack-start (stub)"

# Credenciais: ~/.qbcreds fica em /home (overlay) e se perde na recriacao.
# E regenerado a partir do credentials.env, que vive no volume persistente.
if [ -f "$PERSIST/credentials.env" ]; then
    chmod 600 "$PERSIST/credentials.env"
    chown "$PLEX_USER:$PLEX_USER" "$PERSIST/credentials.env"
    # shellcheck disable=SC1091
    QB_U=$(grep -E '^QB_USER=' "$PERSIST/credentials.env" | cut -d= -f2-)
    QB_P=$(grep -E '^QB_PASS=' "$PERSIST/credentials.env" | cut -d= -f2-)
    if [ -n "${QB_U:-}" ] && [ -n "${QB_P:-}" ]; then
        umask 077
        printf 'QB_USER=%s\nQB_PASS=%s\n' "$QB_U" "$QB_P" > /home/"$PLEX_USER"/.qbcreds
        chown "$PLEX_USER:$PLEX_USER" /home/"$PLEX_USER"/.qbcreds
        chmod 600 /home/"$PLEX_USER"/.qbcreds
        log "  ~/.qbcreds regenerado do credentials.env"
    else
        log "  AVISO: QB_USER/QB_PASS ausentes no credentials.env"
    fi
else
    log "  AVISO: $PERSIST/credentials.env ausente — 'plexctl qb' vai pedir ~/.qbcreds"
fi

# ---------------------------------------------------------------- subir -----
log "== Subindo servicos =="
if [ -x /usr/local/bin/plex-stack-start ]; then
    /usr/local/bin/plex-stack-start
else
    su - "$PLEX_USER" -c "qbittorrent-nox --daemon"
    [ -x /etc/init.d/plexmediaserver ] && /etc/init.d/plexmediaserver start
    [ -x /etc/init.d/cloudflared ]     && /etc/init.d/cloudflared start
fi

# --------------------------------------------------------------- resumo -----
echo
log "== Verificacao =="
CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://127.0.0.1:32400/identity 2>/dev/null)
echo "  Plex        HTTP ${CODE:-sem resposta}"
CLAIMED=$(curl -s --max-time 10 http://127.0.0.1:32400/identity 2>/dev/null \
          | grep -o 'claimed="[01]"')
echo "  ${CLAIMED:-claim desconhecido}"
CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://127.0.0.1:8081/ 2>/dev/null)
echo "  qBittorrent HTTP ${CODE:-sem resposta}"
pgrep -x cloudflared >/dev/null && echo "  cloudflared rodando" || echo "  cloudflared PARADO"

echo
log "Pronto. Se o Plex mostrar claimed=\"0\", siga a secao 'Claim' do README."
