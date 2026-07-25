#!/bin/bash
#
# Provisiona Plex + qBittorrent + Cloudflare Tunnel nesta maquina.
#
# Idempotente: pode rodar quantas vezes precisar. Tudo que importa (banco do
# Plex, midia, credenciais do tunnel) vive em $PLEXDEN_HOME — de preferencia um
# volume que persista (num container, um bind mount do disco do host; o resto
# do container e overlay e some).
#
#   sudo $PLEXDEN_HOME/provision.sh
#   sudo ./provision.sh --check      # dry-run: so detecta e valida
#
set -u

# Parametrizavel por variaveis de ambiente (defaults sensatos). Ex.:
#   sudo PLEXDEN_HOME=/srv/plex PLEXDEN_USER=media ./provision.sh
# Precedencia: variavel de ambiente > /etc/plexden.conf (instalacao ja feita) >
# default. Assim, re-rodar num servidor ja configurado preserva os valores dele.
_ENV_HOME="${PLEXDEN_HOME:-}"; _ENV_USER="${PLEXDEN_USER:-}"
[ -r /etc/plexden.conf ] && . /etc/plexden.conf
PERSIST="${_ENV_HOME:-${PLEXDEN_HOME:-/srv/plexden}}"
PLEX_USER="${_ENV_USER:-${PLEXDEN_USER:-plex}}"
# UUID do tunnel: se vazio, e auto-detectado a partir de cloudflared/*.json.
TUNNEL_UUID="${CF_TUNNEL_UUID:-}"

# --check: dry-run. Detecta o gerenciador, resolve a lista de pacotes e a
# estrategia por familia, valida a sintaxe do plexden e sai — sem instalar nada
# nem mutar o sistema. E' o que o CI roda em cada distro.
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

log()  { echo "[$(date +%H:%M:%S)] $*"; }
fail() { echo "ERRO: $*" >&2; exit 1; }

if [ "$CHECK" = 0 ]; then
    [ "$(id -u)" -eq 0 ] || fail "rode como root (sudo $0)"
    # cria o usuario da stack se ainda nao existir
    id "$PLEX_USER" >/dev/null 2>&1 || { useradd -m -s /bin/bash "$PLEX_USER" && log "usuario $PLEX_USER criado"; }
    # Avisa se $PERSIST nao parece estar num mount dedicado (dado que so ele
    # persiste a recriacao do container). Checa o proprio dir e o pai.
    mountpoint -q "$PERSIST" 2>/dev/null || \
      mountpoint -q "$(dirname "$PERSIST")" 2>/dev/null || \
      grep -qF " $PERSIST " /proc/mounts || \
      log "AVISO: $PERSIST nao aparece como mount — confirme que persiste!"
fi

# ------------------------------------------------- gerenciador de pacotes ---
# Camada fina sobre o gerenciador da distro. So o bootstrap (este script) e o
# 'plexden update' dependem disto; o resto do plexden e' agnostico.
PKG=""
detect_pkg() {
    for m in apt-get dnf yum pacman zypper; do
        command -v "$m" >/dev/null 2>&1 && { PKG="$m"; return 0; }
    done
    fail "nenhum gerenciador de pacotes suportado (apt/dnf/yum/pacman/zypper)"
}

pkg_refresh() {
    case "$PKG" in
        apt-get) apt-get update -qq ;;
        pacman)  pacman -Sy --noconfirm >/dev/null ;;
        zypper)  zypper -n refresh >/dev/null ;;
        dnf|yum) : ;;   # atualizam os metadados sob demanda
    esac
}

pkg_installed() {   # $1 = pacote
    case "$PKG" in
        apt-get)        dpkg -s "$1" >/dev/null 2>&1 ;;
        pacman)         pacman -Q "$1" >/dev/null 2>&1 ;;
        dnf|yum|zypper) rpm -q "$1" >/dev/null 2>&1 ;;
    esac
}

pkg_install() {     # $@ = pacotes
    case "$PKG" in
        apt-get) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
        dnf)     dnf install -y -q "$@" ;;
        yum)     yum install -y -q "$@" ;;
        pacman)  pacman -S --noconfirm --needed "$@" ;;
        zypper)  zypper -n install "$@" ;;
    esac
}

install_if_missing() {
    if pkg_installed "$1"; then
        log "  $1 ja instalado"
    else
        log "  instalando $1"
        pkg_install "$1" || fail "falha ao instalar $1"
    fi
}

# ---------------------------------------------------------------- pacotes ---
log "== Pacotes =="
detect_pkg
log "  gerenciador detectado: $PKG"

# Nomes que variam por familia: procps -> procps-ng (rpm/arch); python3 ->
# python (arch); gnupg so e' preciso no apt (dearmor da chave do Plex).
case "$PKG" in
    apt-get)        base="curl wget ca-certificates sudo qbittorrent-nox gnupg procps psmisc python3" ;;
    pacman)         base="curl wget ca-certificates sudo qbittorrent-nox procps-ng psmisc python" ;;
    dnf|yum|zypper) base="curl wget ca-certificates sudo qbittorrent-nox procps-ng psmisc python3" ;;
esac

# Dry-run: reporta o plano e valida o plexden, sem tocar no sistema.
if [ "$CHECK" = 1 ]; then
    log "== MODO --check (dry-run) — nada sera instalado =="
    log "  pacotes base: $base"
    case "$PKG" in
        apt-get)        log "  plex: repositorio apt assinado (distro=debian)" ;;
        dnf|yum|zypper) log "  plex: repositorio rpm (.repo + rpm --import)" ;;
        pacman)         log "  plex: AUR (instalacao manual)" ;;
    esac
    log "  cloudflared: binario estatico ($(uname -m))"
    sdir=$(cd "$(dirname "$0")" && pwd)
    P=""
    [ -f "$sdir/scripts/plexden" ] && P="$sdir/scripts/plexden"
    [ -z "$P" ] && [ -f "$sdir/plexden" ] && P="$sdir/plexden"
    if [ -n "$P" ] && command -v python3 >/dev/null 2>&1; then
        python3 - "$P" <<'PY' && log "  plexden: sintaxe Python OK"
import ast, sys
ast.parse(open(sys.argv[1]).read())
PY
    else
        log "  (plexden ou python3 ausente — pulei a checagem de sintaxe)"
    fi
    exit 0
fi

pkg_refresh
for p in $base; do
    install_if_missing "$p"
done

# ------------------------------------------------------------------- plex ---
# Familia deb: repo apt assinado. Familia rpm: .repo + rpm --import. Arch: AUR.
#
# O repositorio e o caminho preferido (deixa o 'apt/dnf upgrade' cuidar do Plex),
# mas ele nao e confiavel: em 2026 o apt do Debian 13+ passou a verificar com
# sequoia (sqv), que recusa a chave do Plex porque a assinatura de vinculo dela
# e SHA1 — o repo simplesmente para de existir para o apt. Por isso todo caminho
# tem fallback para o pacote oficial baixado direto, que e a mesma origem que o
# 'plexden update' usa e nao depende de repositorio nenhum.

# Baixa o pacote oficial mais novo. O endpoint publico redireciona para o
# .deb/.rpm da versao atual e dispensa token (o token so importa no update, para
# canais de assinante).
plex_download() {   # $1 = debian|redhat, $2 = arquivo de destino
    case "$(uname -m)" in
        x86_64|amd64)  pbuild=linux-x86_64 ;;
        aarch64|arm64) pbuild=linux-aarch64 ;;
        armv7l|armhf)  pbuild=linux-armv7neon ;;
        *) log "  arquitetura sem build do Plex: $(uname -m)"; return 1 ;;
    esac
    log "  baixando o pacote oficial do Plex ($pbuild)"
    curl -fsSL --max-time 600 -o "$2" \
      "https://plex.tv/downloads/latest/5?channel=16&build=${pbuild}&distro=$1"
}

install_plex() {
    if pkg_installed plexmediaserver; then
        log "  plexmediaserver ja instalado"
        return 0
    fi
    log "  instalando plexmediaserver"
    case "$PKG" in
        apt-get)
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://downloads.plex.tv/plex-keys/PlexSign.key \
              | gpg --dearmor -o /etc/apt/keyrings/plex.gpg
            echo "deb [signed-by=/etc/apt/keyrings/plex.gpg] https://downloads.plex.tv/repo/deb public main" \
              > /etc/apt/sources.list.d/plexmediaserver.list
            apt-get update -qq || true
            if pkg_install plexmediaserver; then
                log "  instalado pelo repositorio do Plex"
            else
                # Repo inutilizavel. Remove a entrada: deixa-la ali so faria todo
                # 'apt update' do usuario terminar em erro daqui pra frente.
                log "  repositorio do Plex recusado pelo apt — usando o pacote oficial"
                rm -f /etc/apt/sources.list.d/plexmediaserver.list
                apt-get update -qq || true
                plex_download debian /tmp/plex.deb || fail "download do Plex falhou"
                DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/plex.deb >/dev/null 2>&1 || \
                  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -f
                rm -f /tmp/plex.deb
                pkg_installed plexmediaserver || fail "falha ao instalar plexmediaserver"
            fi
            ;;
        dnf|yum|zypper)
            repodir=/etc/yum.repos.d
            [ "$PKG" = zypper ] && repodir=/etc/zypp/repos.d
            if rpm --import https://downloads.plex.tv/plex-keys/PlexSign.key 2>/dev/null; then
                mkdir -p "$repodir"
                cat > "$repodir/plex.repo" <<'REPO'
[PlexRepo]
name=Plex
baseurl=https://downloads.plex.tv/repo/rpm/$basearch/
enabled=1
gpgkey=https://downloads.plex.tv/plex-keys/PlexSign.key
gpgcheck=1
REPO
            else
                log "  chave do Plex recusada pelo rpm — pulando o repositorio"
            fi
            if pkg_install plexmediaserver; then
                log "  instalado pelo repositorio do Plex"
            else
                log "  repositorio do Plex indisponivel — usando o pacote oficial"
                rm -f "$repodir/plex.repo"
                plex_download redhat /tmp/plex.rpm || fail "download do Plex falhou"
                case "$PKG" in
                    dnf)    dnf install -y -q /tmp/plex.rpm ;;
                    yum)    yum install -y -q /tmp/plex.rpm ;;
                    zypper) zypper -n --no-gpg-checks install /tmp/plex.rpm ;;
                esac
                rm -f /tmp/plex.rpm
                pkg_installed plexmediaserver || fail "falha ao instalar plexmediaserver"
            fi
            ;;
        pacman)
            log "  Arch: o Plex nao tem pacote oficial nos repos."
            log "        Instale pelo AUR (ex.: yay -S plex-media-server) e rode este script de novo."
            ;;
    esac
}
install_plex

# ------------------------------------------------------------- cloudflared ---
# Binario estatico oficial: portavel em qualquer distro (dispensa .deb/.rpm).
install_cloudflared() {
    if command -v cloudflared >/dev/null 2>&1; then
        log "  cloudflared ja instalado"
        return 0
    fi
    log "  instalando cloudflared (binario estatico)"
    case "$(uname -m)" in
        x86_64|amd64)  cfarch=amd64 ;;
        aarch64|arm64) cfarch=arm64 ;;
        armv7l|armhf)  cfarch=arm ;;
        *) fail "arquitetura sem binario cloudflared: $(uname -m)" ;;
    esac
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cfarch}" \
      -o /usr/local/bin/cloudflared || fail "download do cloudflared falhou"
    chmod +x /usr/local/bin/cloudflared
}
install_cloudflared

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
# 'plexden plex-exec'. ~/bin/plex-start e so um stub que chama o plexden.
mkdir -p /home/"$PLEX_USER"/bin
cat > /home/"$PLEX_USER"/bin/plex-start <<'EOF'
#!/bin/sh
exec /usr/local/bin/plexden plex-exec
EOF
chmod +x /home/"$PLEX_USER"/bin/plex-start
chown -R "$PLEX_USER:$PLEX_USER" /home/"$PLEX_USER"/bin

if [ -f "$PERSIST/config/Plex Media Server/Preferences.xml" ]; then
    log "  config existente encontrada — claim e bibliotecas preservados"
else
    log "  config nova: sera preciso claimar em https://plex.tv/claim (ver README)"
fi

# init script (stub SysV -> plexden _init). O pacote do Plex o remove ao
# atualizar; o 'plexden update' e este provision o recriam.
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
exec /usr/local/bin/plexden _init "$@"
EOF
chmod 755 /etc/init.d/plexmediaserver
log "  init stub instalado"

# ----------------------------------------------------------- qbittorrent ----
log "== qBittorrent =="
QBCONF=/home/"$PLEX_USER"/.config/qBittorrent/qBittorrent.conf
if [ ! -f "$QBCONF" ]; then
    mkdir -p "$(dirname "$QBCONF")"
    # qBittorrent 4.5 le Session\DefaultSavePath (nao Downloads\SavePath, que e
    # legado e fica ignorado). AutoRun chama o 'plexden postprocess' ao concluir.
    cat > "$QBCONF" <<EOF
[AutoRun]
enabled=true
program=/usr/local/bin/plexden postprocess "%N" "%F"

[LegalNotice]
Accepted=true

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
    log "  config criada"
else
    log "  config ja existe — preservada"
fi

# Alinha usuario/senha da WebUI ao credentials.env. Sem isso, 'plexden qb' pode
# nao logar numa instalacao nova: a serie 4.x usa 'adminadmin', mas a 5.x
# (Fedora/Arch) gera uma senha aleatoria a cada boot ate uma ser definida. Faz
# com o qB parado, para a edicao nao ser sobrescrita ao salvar a sessao.
if [ -f "$PERSIST/credentials.env" ]; then
    QB_U=$(grep -E '^QB_USER=' "$PERSIST/credentials.env" | cut -d= -f2-)
    QB_P=$(grep -E '^QB_PASS=' "$PERSIST/credentials.env" | cut -d= -f2-)
    if [ -n "${QB_U:-}" ] && [ -n "${QB_P:-}" ]; then
        pkill -x qbittorrent-nox 2>/dev/null && sleep 2
        python3 - "$QBCONF" "$QB_U" "$QB_P" <<'PY'
import sys, os, hashlib, base64
conf, user, pw = sys.argv[1], sys.argv[2], sys.argv[3]
salt = os.urandom(16)
key = hashlib.pbkdf2_hmac('sha512', pw.encode(), salt, 100000, 64)
pbkdf2 = '"@ByteArray(%s:%s)"' % (
    base64.b64encode(salt).decode(), base64.b64encode(key).decode())
user_line = 'WebUI\\Username=' + user
pass_line = 'WebUI\\Password_PBKDF2=' + pbkdf2
try:
    lines = open(conf, encoding='utf-8').read().splitlines()
except OSError:
    lines = []
result, cur = [], None
done_user = done_pass = False

def flush_prefs():
    global done_user, done_pass
    if not done_user:
        result.append(user_line); done_user = True
    if not done_pass:
        result.append(pass_line); done_pass = True

for ln in lines:
    s = ln.strip()
    if s.startswith('[') and s.endswith(']'):
        if cur == '[Preferences]':
            flush_prefs()
        cur = s
        result.append(ln)
        continue
    if cur == '[Preferences]' and ln.startswith('WebUI\\Username='):
        result.append(user_line); done_user = True; continue
    if cur == '[Preferences]' and ln.startswith('WebUI\\Password_PBKDF2='):
        result.append(pass_line); done_pass = True; continue
    result.append(ln)
if cur == '[Preferences]':
    flush_prefs()
if not done_pass:            # nao havia secao [Preferences]
    result.append('[Preferences]')
    flush_prefs()
open(conf, 'w', encoding='utf-8').write('\n'.join(result) + '\n')
PY
        chown -R "$PLEX_USER:$PLEX_USER" /home/"$PLEX_USER"/.config
        log "  usuario/senha da WebUI alinhados ao credentials.env"
    fi
fi

# ------------------------------------------------------------- cloudflared --
log "== Cloudflare Tunnel =="
# Se o UUID nao veio por env, auto-detecta pelo unico *.json em cloudflared/.
if [ -z "$TUNNEL_UUID" ]; then
    j=$(find "$PERSIST"/cloudflared -maxdepth 1 -name '*.json' 2>/dev/null | head -1)
    [ -n "$j" ] && TUNNEL_UUID=$(basename "$j" .json)
fi
if [ -n "$TUNNEL_UUID" ] && [ -f "$PERSIST/cloudflared/cert.pem" ] && [ -f "$PERSIST/cloudflared/$TUNNEL_UUID.json" ]; then
    mkdir -p /etc/cloudflared
    cp "$PERSIST/cloudflared/config.yml"        /etc/cloudflared/
    cp "$PERSIST/cloudflared/cert.pem"          /etc/cloudflared/
    cp "$PERSIST/cloudflared/$TUNNEL_UUID.json" /etc/cloudflared/
    chmod 600 /etc/cloudflared/cert.pem /etc/cloudflared/*.json
    log "  credenciais restauradas do volume persistente"

    # 'cloudflared service install' cria unit do systemd (onde ha systemd) ou
    # script SysV. So instala se ainda nao houver nenhum dos dois.
    if [ -f /etc/init.d/cloudflared ] || \
       { command -v systemctl >/dev/null 2>&1 && \
         systemctl list-unit-files cloudflared.service 2>/dev/null | grep -q cloudflared; }; then
        log "  servico ja instalado"
    else
        cloudflared service install >/dev/null 2>&1 && log "  servico instalado"
    fi
else
    log "  AVISO: credenciais do tunnel ausentes em $PERSIST/cloudflared/"
    log "         rode 'cloudflared tunnel login' e veja a secao Tunnel do README"
fi

# ------------------------------------------------------------ stack start ---
log "== Scripts de operacao =="
# Tudo unificado em 'plexden' (Python). plex-stack-start e um stub para o
# entrypoint do container.
if [ -f "$PERSIST/scripts/plexden" ]; then
    cp "$PERSIST/scripts/plexden" /usr/local/bin/plexden
    chmod 755 /usr/local/bin/plexden
    log "  plexden instalado"
else
    log "  AVISO: $PERSIST/scripts/plexden ausente — stack nao vai subir"
fi
# grava a config que o plexden le em runtime (caminho e usuario da stack)
cat > /etc/plexden.conf <<EOF
PLEXDEN_HOME=$PERSIST
PLEXDEN_USER=$PLEX_USER
EOF
chmod 644 /etc/plexden.conf
log "  /etc/plexden.conf gravado ($PERSIST, usuario $PLEX_USER)"
cat > /usr/local/bin/plex-stack-start <<'EOF'
#!/bin/sh
exec /usr/local/bin/plexden services start
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
    log "  AVISO: $PERSIST/credentials.env ausente — 'plexden qb' vai pedir ~/.qbcreds"
fi

# ---------------------------------------------------------------- subir -----
log "== Subindo servicos =="
if [ -x /usr/local/bin/plex-stack-start ]; then
    /usr/local/bin/plex-stack-start
else
    su - "$PLEX_USER" -c "qbittorrent-nox --daemon --confirm-legal-notice"
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
