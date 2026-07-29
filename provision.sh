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

# Parametrizavel por variavel de ambiente (default sensato). Ex.:
#   sudo PLEXDEN_HOME=/srv/plex ./provision.sh
# Precedencia do HOME: variavel de ambiente > /etc/plexden.conf (instalacao ja
# feita) > default. Assim, re-rodar num servidor ja configurado preserva o
# valor dele.
# O usuario da stack NAO se escolhe por variavel: e sempre quem esta rodando o
# script (SUDO_USER, ou o proprio root numa sessao root direta) na primeira
# instalacao; num re-provisionamento, o valor ja gravado em /etc/plexden.conf
# prevalece, para nao trocar o dono da stack so porque outro admin rodou o
# script. PLEXDEN_USER no ambiente ainda e aceito — e assim que o install.sh
# repassa o usuario que ele ja resolveu.
_ENV_HOME="${PLEXDEN_HOME:-}"; _ENV_USER="${PLEXDEN_USER:-}"
[ -r /etc/plexden.conf ] && . /etc/plexden.conf
PERSIST="${_ENV_HOME:-${PLEXDEN_HOME:-/srv/plexden}}"
PLEX_USER="${_ENV_USER:-${PLEXDEN_USER:-${SUDO_USER:-$(id -un)}}}"
# UUID do tunnel: se vazio, e auto-detectado a partir de cloudflared/*.json.
TUNNEL_UUID="${CF_TUNNEL_UUID:-}"

# --check: dry-run. Detecta o gerenciador, resolve a lista de pacotes e a
# estrategia por familia, valida a sintaxe do plexden e sai — sem instalar nada
# nem mutar o sistema. E' o que o CI roda em cada distro.
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

log()  { echo "[$(date +%H:%M:%S)] $*"; }
fail() { echo "ERRO: $*" >&2; exit 1; }

# Le do terminal de controle, nao do stdin do script (que num 'curl | sudo
# bash' e o proprio script chegando por pipe). Sem tty (pipe sem controlador,
# CI, container sem -it) devolve 1 e nada no stdout — quem chama trata isso
# como "pular a pergunta", nunca como travar esperando input que nunca vem.
# A ordem do redirecionamento importa: '2>/dev/null' antes de '</dev/tty' e
# o que faz a falha de abrir /dev/tty ficar muda (redirecoes se aplicam da
# esquerda pra direita).
read_tty() {   # $1 = prompt
    local resposta
    if read -r -p "$1" resposta 2>/dev/null </dev/tty; then
        printf '%s' "$resposta"
        return 0
    fi
    return 1
}
read_tty_secreto() {   # $1 = prompt; nao ecoa o que foi digitado
    local resposta
    if read -r -s -p "$1" resposta 2>/dev/null </dev/tty; then
        echo >/dev/tty
        printf '%s' "$resposta"
        return 0
    fi
    return 1
}

# Roda um comando em segundo plano e avisa a cada poucos segundos que ainda
# esta vivo — sem isso, uma instalacao de pacotes ou download lento nao
# imprime nada por dezenas de segundos e parece travado, mesmo funcionando.
# O 'fail()' de dentro do comando ainda funciona: 'exit' num job em segundo
# plano so encerra o job, e o codigo de saida chega aqui pelo 'wait'.
com_status() {   # $1 = rotulo, resto = comando
    local rotulo="$1" pid t=0 rc
    shift
    "$@" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        kill -0 "$pid" 2>/dev/null || break
        t=$((t + 5))
        log "  ...$rotulo, ainda em andamento (${t}s)"
    done
    if wait "$pid"; then rc=0; else rc=$?; fi
    if [ "$rc" = 0 ]; then
        log "  ...$rotulo, concluido"
    else
        log "  ...$rotulo, falhou (codigo $rc)"
    fi
    return "$rc"
}

if [ "$CHECK" = 0 ]; then
    [ "$(id -u)" -eq 0 ] || fail "rode como root (sudo $0)"
    # cria o usuario da stack se ainda nao existir
    id "$PLEX_USER" >/dev/null 2>&1 || { useradd -m -s /bin/bash "$PLEX_USER" && log "usuario $PLEX_USER criado"; }
    # Home real do usuario (nao assumir /home/$PLEX_USER: para root, por
    # exemplo, e /root).
    PLEX_HOME=$(getent passwd "$PLEX_USER" | cut -d: -f6)
    [ -n "$PLEX_HOME" ] || PLEX_HOME="/home/$PLEX_USER"
    # Avisa se $PERSIST nao parece estar num mount dedicado (dado que so ele
    # persiste a recriacao do container). Checa o proprio dir e o pai.
    mountpoint -q "$PERSIST" 2>/dev/null || \
      mountpoint -q "$(dirname "$PERSIST")" 2>/dev/null || \
      grep -qF " $PERSIST " /proc/mounts || \
      log "AVISO: $PERSIST nao aparece como mount — confirme que persiste!"
fi

# ============================================================ diagnostico ===
# Roda antes de tocar em qualquer coisa: diz em que pe o CI esta em relacao a
# este SO e o que esperar deste hardware. Nada aqui bloqueia a instalacao —
# informa e segue.

_osrel() {   # $1 = campo do /etc/os-release
    [ -r /etc/os-release ] || return 1
    sed -n "s/^$1=//p" /etc/os-release | tr -d '"' | head -1
}

# Espelha a matriz do .github/workflows/ci.yml. Se um dia entrar imagem nova la,
# esta tabela precisa acompanhar — o job 'distros' confere que os dois batem.
cobertura_so() {
    id=$(_osrel ID || echo desconhecido)
    pretty=$(_osrel PRETTY_NAME || echo "SO nao identificado")
    ver=$(_osrel VERSION_ID || echo "")
    like=$(_osrel ID_LIKE || echo "")

    log "  SO: $pretty"
    case "$id" in
        debian)
            log "  Tier 1 — o CI instala a stack inteira em debian:stable-slim a cada push" ;;
        ubuntu)
            if [ "$ver" = "24.04" ]; then
                log "  Tier 1 — o CI instala a stack inteira em ubuntu:24.04 a cada push"
            else
                log "  Tier 3 — o CI testa o Ubuntu 24.04, nao o $ver."
                log "           Mesmo caminho de codigo, versao nao exercitada." ;
            fi ;;
        fedora)
            log "  Tier 1 — o CI instala a stack inteira em fedora:latest a cada push" ;;
        almalinux)
            log "  Tier 2 — o CI so roda o dry-run aqui (deteccao e sintaxe)."
            log "           A instalacao em si nunca foi exercitada nesta distro." ;;
        alpine)
            # Nao e falta de teste: o Plex nao publica build musl. Melhor dizer
            # agora do que deixar a pessoa descobrir no meio da instalacao.
            log "  SEM TIER — o Plex nao tem build para musl, entao esta stack nao"
            log "           roda no Alpine. Use uma base glibc enxuta (debian:slim)." ;;
        nixos|gentoo)
            log "  SEM TIER — o modelo de instalacao do $id e outro; um instalador"
            log "           imperativo como este nao se aplica." ;;
        *)
            # Nao esta na matriz: vale pelo parentesco, e so.
            case " $like " in
                *debian*|*ubuntu*)
                    log "  Tier 3 — familia Debian, testada via Debian stable e Ubuntu 24.04" ;;
                *rhel*|*fedora*|*centos*)
                    log "  Tier 3 — familia RPM, testada via Fedora" ;;
                *)
                    log "  SEM TIER — este SO nao aparece em lugar nenhum do CI."
                    log "           Se o gerenciador for detectado abaixo, deve funcionar," ;;
            esac
            log "           mas ninguem instalou a stack aqui. Reporte como for." ;;
    esac
}

# Divide KiB por 1 GiB devolvendo uma casa decimal, sem depender de awk/python
# (que podem nem estar instalados quando isto roda).
_gb() { echo "$(( $1 / 1048576 )).$(( ($1 % 1048576) * 10 / 1048576 ))"; }

_livre_kb() {   # espaco livre no ancestral existente mais proximo de $1
    d=$1
    while [ ! -d "$d" ] && [ "$d" != "/" ]; do d=$(dirname "$d"); done
    df -Pk "$d" 2>/dev/null | tail -1 | {
        read -r _ _ _ livre _ && echo "${livre:-0}" || echo 0
    }
}

# Veredito honesto: mede o que da para medir (nucleos, RAM, disco) e diz em voz
# alta o que NAO da (velocidade de transcodificacao depende do modelo da CPU,
# nao da contagem de nucleos).
avaliar_maquina() {
    nucleos=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
    modelo=$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo 2>/dev/null | head -1)
    [ -z "$modelo" ] && modelo=$(sed -n 's/^Model[[:space:]]*: //p' /proc/cpuinfo 2>/dev/null | head -1)
    [ -z "$modelo" ] && modelo=$(uname -m)
    mem_kb=$(sed -n 's/^MemTotal:[[:space:]]*\([0-9]*\).*/\1/p' /proc/meminfo 2>/dev/null || echo 0)
    mem_mb=$(( mem_kb / 1024 ))
    livre_kb=$(_livre_kb "$PERSIST")
    livre_gb=$(( livre_kb / 1048576 ))

    log "  CPU:     $nucleos nucleo(s) — $modelo"
    log "  Memoria: $(_gb "$mem_kb") GB"
    log "  Disco:   $(_gb "$livre_kb") GB livres para $PERSIST"

    # 0 = folga, 1 = da conta, 2 = no limite. Vale o pior dos tres.
    nota=0
    avisos=()
    if [ "$mem_mb" -lt 1500 ]; then
        nota=2
        avisos+=("menos de 1,5 GB de RAM: o Plex pode ser morto pelo OOM ao varrer bibliotecas grandes")
    elif [ "$mem_mb" -lt 3000 ]; then
        [ "$nota" -lt 1 ] && nota=1
        avisos+=("RAM entre 1,5 e 3 GB: da para reproducao direta, aperta se transcodificar")
    fi
    if [ "$nucleos" -le 1 ]; then
        nota=2
        avisos+=("1 nucleo: conte com reproducao direta apenas")
    elif [ "$nucleos" -lt 4 ]; then
        [ "$nota" -lt 1 ] && nota=1
        avisos+=("menos de 4 nucleos: um transcode 1080p por vez, no maximo")
    fi
    if [ "$livre_gb" -lt 20 ]; then
        nota=2
        avisos+=("menos de 20 GB livres: biblioteca de midia enche isso rapido")
    elif [ "$livre_gb" -lt 100 ]; then
        [ "$nota" -lt 1 ] && nota=1
        avisos+=("menos de 100 GB livres: da para comecar, planeje o crescimento")
    fi
    case "$(uname -m)" in
        x86_64|amd64) ;;
        *) [ "$nota" -lt 1 ] && nota=1
           avisos+=("arquitetura $(uname -m): transcodificacao por software costuma ser inviavel aqui") ;;
    esac

    case "$nota" in
        0) log "  VEREDITO: roda com folga" ;;
        1) log "  VEREDITO: da conta" ;;
        2) log "  VEREDITO: no limite" ;;
    esac
    for a in ${avisos[@]+"${avisos[@]}"}; do log "            - $a"; done
    log "         Isto olha nucleos, RAM e disco. A velocidade de transcodificacao"
    log "         depende do modelo da CPU, que nenhum numero aqui mede — o"
    log "         veredito vale para reproducao direta e para a biblioteca."
}

log "== Cobertura de teste deste SO =="
cobertura_so
log "== Este computador =="
avaliar_maquina

# ------------------------------------------------- gerenciador de pacotes ---
# Camada fina sobre o gerenciador da distro. So o bootstrap (este script) e o
# 'plexden update' dependem disto; o resto do plexden e' agnostico.
PKG=""
detect_pkg() {
    for m in apt-get dnf yum; do
        command -v "$m" >/dev/null 2>&1 && { PKG="$m"; return 0; }
    done
    fail "nenhum gerenciador de pacotes suportado (apt/dnf/yum)"
}

pkg_refresh() {
    case "$PKG" in
        apt-get) apt-get update -qq ;;
        dnf|yum) : ;;   # atualizam os metadados sob demanda
    esac
}

pkg_installed() {   # $1 = pacote
    case "$PKG" in
        # 'dpkg -s' devolve sucesso mesmo com o pacote so removido (estado
        # "deinstall ok config-files", o que 'apt-get remove' — sem --purge —
        # deixa para tras, exatamente o que o 'plexden uninstall' faz de
        # proposito). Sem checar o Status de verdade, um pacote removido e
        # tratado como instalado e nunca e reinstalado.
        apt-get) [ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" = "install ok installed" ] ;;
        dnf|yum) rpm -q "$1" >/dev/null 2>&1 ;;
    esac
}

pkg_install() {     # $@ = pacotes
    case "$PKG" in
        apt-get) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
        dnf)     dnf install -y -q "$@" ;;
        yum)     yum install -y -q "$@" ;;
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

# Nomes que variam por familia: procps -> procps-ng (rpm); gnupg so e' preciso
# no apt (dearmor da chave do Plex). util-linux (o 'su') e' essencial no
# Debian, mas nao vem numa Fedora/RHEL enxuta — e a stack inteira sobe os
# servicos com 'su - $PLEX_USER'.
case "$PKG" in
    apt-get) base="curl wget ca-certificates sudo qbittorrent-nox gnupg procps psmisc python3" ;;
    dnf|yum) base="curl wget ca-certificates sudo qbittorrent-nox procps-ng psmisc python3 util-linux" ;;
esac

PLEX_PKG=plexmediaserver

# Dry-run: reporta o plano e valida o plexden, sem tocar no sistema.
if [ "$CHECK" = 1 ]; then
    log "== MODO --check (dry-run) — nada sera instalado =="
    log "  pacotes base: $base"
    log "  pacote do plex: $PLEX_PKG"
    case "$PKG" in
        apt-get) log "  plex: repositorio apt assinado (distro=debian)" ;;
        dnf|yum) log "  plex: repositorio rpm (.repo + rpm --import)" ;;
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

_instalar_pacotes_base() {
    pkg_refresh
    for p in $base; do
        install_if_missing "$p"
    done
}
com_status "instalando pacotes base" _instalar_pacotes_base \
  || fail "instalacao dos pacotes base falhou — veja o log acima"

# Sem estes, a stack falha de um jeito silencioso e dificil de diagnosticar: os
# servicos sobem com 'su' e a saude e' medida com HTTP. Melhor parar aqui.
for c in su curl pgrep pkill; do
    command -v "$c" >/dev/null 2>&1 || \
      fail "'$c' nao existe mesmo apos instalar os pacotes base — abortando"
done

# ------------------------------------------------------------------- plex ---
# Familia deb: repo apt assinado. Familia rpm: .repo + rpm --import.
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
    if pkg_installed "$PLEX_PKG"; then
        log "  $PLEX_PKG ja instalado"
        return 0
    fi
    log "  instalando $PLEX_PKG"
    case "$PKG" in
        apt-get)
            mkdir -p /etc/apt/keyrings
            curl -fsSL --max-time 60 https://downloads.plex.tv/plex-keys/PlexSign.key \
              | gpg --dearmor -o /etc/apt/keyrings/plex.gpg
            echo "deb [signed-by=/etc/apt/keyrings/plex.gpg] https://downloads.plex.tv/repo/deb public main" \
              > /etc/apt/sources.list.d/plexmediaserver.list
            apt-get update -qq || true
            if pkg_install "$PLEX_PKG"; then
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
                pkg_installed "$PLEX_PKG" || fail "falha ao instalar $PLEX_PKG"
            fi
            ;;
        dnf|yum)
            repodir=/etc/yum.repos.d
            if curl -fsSL --max-time 60 -o /tmp/plex.key https://downloads.plex.tv/plex-keys/PlexSign.key \
               && rpm --import /tmp/plex.key 2>/dev/null; then
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
            rm -f /tmp/plex.key
            if pkg_install "$PLEX_PKG"; then
                log "  instalado pelo repositorio do Plex"
            else
                log "  repositorio do Plex indisponivel — usando o pacote oficial"
                rm -f "$repodir/plex.repo"
                plex_download redhat /tmp/plex.rpm || fail "download do Plex falhou"
                case "$PKG" in
                    dnf) dnf install -y -q /tmp/plex.rpm ;;
                    yum) yum install -y -q /tmp/plex.rpm ;;
                esac
                rm -f /tmp/plex.rpm
                pkg_installed "$PLEX_PKG" || fail "falha ao instalar $PLEX_PKG"
            fi
            ;;
    esac
}
com_status "instalando o Plex" install_plex || fail "instalacao do Plex falhou — veja o log acima"

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
    curl -fsSL --max-time 300 "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cfarch}" \
      -o /usr/local/bin/cloudflared || fail "download do cloudflared falhou"
    chmod +x /usr/local/bin/cloudflared
}
com_status "instalando o cloudflared" install_cloudflared \
  || fail "instalacao do cloudflared falhou — veja o log acima"

# Se o UUID nao veio por env, auto-detecta pelo unico *.json ja restaurado em
# cloudflared/ (reinstalacao). Cedo o bastante para o assistente interativo
# logo abaixo saber se ja ha tunnel configurado antes de perguntar.
if [ -z "$TUNNEL_UUID" ]; then
    j=$(find "$PERSIST"/cloudflared -maxdepth 1 -name '*.json' 2>/dev/null | head -1)
    [ -n "$j" ] && TUNNEL_UUID=$(basename "$j" .json)
fi

# Passo a passo interativo do Cloudflare Tunnel: login, criacao do tunnel,
# hostnames e config.yml, e o route dns. So chega aqui se o assistente
# interativo perguntou e o usuario topou. O 'cloudflared tunnel login' abre
# um link que precisa ser autorizado no navegador — isso a propria Cloudflare
# exige, nao da pra automatizar por fora.
setup_cloudflare_tunnel() {
    local certdir="${HOME:-/root}/.cloudflared" nome uuid host_plex host_qbit saida

    echo "  abra o link a seguir num navegador e autorize (ate 5min de espera):" >/dev/tty
    # 'timeout' e obrigatorio aqui: sem ele, um navegador que nunca autoriza,
    # rede que bloqueia o callback do OAuth, ou a pessoa que so foi embora,
    # travariam a instalacao inteira para sempre, sem chance de seguir.
    if ! timeout 300 cloudflared tunnel login </dev/tty >/dev/tty 2>&1; then
        log "  login nao concluido em 5min (ou cancelado) — Cloudflare Tunnel pulado"
        log "  rode de novo o provision.sh quando quiser tentar de novo"
        return 0
    fi
    if [ ! -f "$certdir/cert.pem" ]; then
        log "  cert.pem nao apareceu em $certdir — Cloudflare Tunnel pulado"
        return 0
    fi

    nome=$(read_tty "  nome do tunnel [plexden]: ") || nome=""
    nome="${nome:-plexden}"
    saida=$(timeout 60 cloudflared tunnel create "$nome" </dev/tty 2>&1)
    printf '%s\n' "$saida" >/dev/tty
    # Ancorado em "with id <UUID>", a frase que o cloudflared sempre imprime
    # ao criar um tunnel — pegar qualquer UUID solto na saida arriscaria casar
    # o UUID errado (ele tambem aparece no caminho do credentials-file).
    uuid=$(printf '%s\n' "$saida" \
             | sed -n 's/.* with id \([0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}\).*/\1/p' \
             | tail -1)
    if [ -z "$uuid" ] || [ ! -f "$certdir/$uuid.json" ]; then
        log "  nao consegui criar o tunnel (ou ele ja existia com outro nome) — pulado"
        return 0
    fi

    host_plex=$(read_tty "  hostname do Plex (ex.: plex.seudominio.com): ") || host_plex=""
    host_qbit=$(read_tty "  hostname do qBittorrent (Enter p/ pular): ") || host_qbit=""

    cp "$certdir/cert.pem" "$PERSIST/cloudflared/"
    cp "$certdir/$uuid.json" "$PERSIST/cloudflared/"
    {
        echo "tunnel: $uuid"
        echo "credentials-file: /etc/cloudflared/$uuid.json"
        echo
        echo "ingress:"
        if [ -n "$host_plex" ]; then
            echo "  - hostname: $host_plex"
            echo "    service: https://localhost:32400"
            echo "    originRequest:"
            echo "      noTLSVerify: true"
        fi
        if [ -n "$host_qbit" ]; then
            echo "  - hostname: $host_qbit"
            echo "    service: http://localhost:8081"
        fi
        echo "  - service: http_status:404"
    } > "$PERSIST/cloudflared/config.yml"

    [ -n "$host_plex" ] && timeout 60 cloudflared tunnel route dns "$nome" "$host_plex" </dev/tty >/dev/tty 2>&1
    [ -n "$host_qbit" ] && timeout 60 cloudflared tunnel route dns "$nome" "$host_qbit" </dev/tty >/dev/tty 2>&1

    TUNNEL_UUID="$uuid"
    log "  tunnel '$nome' configurado (UUID $uuid)"
}

# ------------------------------------------------------------- diretorios ---
log "== Diretorios persistentes =="
mkdir -p "$PERSIST"/{movies,series,config,scripts,cloudflared} \
         "$PERSIST"/torrents/{complete,incomplete}
chown -R "$PLEX_USER:$PLEX_USER" "$PERSIST"
chmod 700 "$PERSIST/cloudflared"
log "  ok"

# ------------------------------------------------------- assistente interativo ---
# So pergunta com terminal de controle disponivel, e so pelo que ainda falta
# (credentials.env ou tunnel ja existentes no volume persistente nao geram
# pergunta — reinstalar nao deve pedir tudo de novo). Sem tty (automacao, CI,
# 'curl | sudo bash' sem terminal interativo) e' pulado em silencio e o
# provisionamento segue com os avisos de sempre, exatamente como antes deste
# assistente existir.
log "== Assistente interativo =="
if : 2>/dev/null </dev/tty; then
    log "  terminal interativo detectado — vou perguntar o que ainda faltar"
else
    log "  sem terminal interativo (automacao, CI, ou stdin sem controle de tty)"
    log "  — pulando as perguntas abaixo; configure depois pelo README"
fi

if [ -f "$PERSIST/credentials.env" ]; then
    log "  qBittorrent: credentials.env ja existe, pulando pergunta"
elif resposta=$(read_tty "  configurar agora a senha do qBittorrent? [S/n] "); then
    case "$resposta" in
        n|N|nao|Nao|NAO|não|Não|NÃO)
            log "  qBittorrent: pulado, veja a secao do README depois" ;;
        *)
            qbu=$(read_tty "  usuario da WebUI [admin]: ") || qbu=""
            qbu="${qbu:-admin}"
            qbp1="" qbp2=""
            while true; do
                qbp1=$(read_tty_secreto "  senha da WebUI: ") || { qbp1=""; break; }
                qbp2=$(read_tty_secreto "  confirme a senha: ") || { qbp2=""; break; }
                [ -n "$qbp1" ] && [ "$qbp1" = "$qbp2" ] && break
                echo "  senhas vazias ou diferentes, tente de novo" >/dev/tty
            done
            if [ -n "$qbp1" ] && [ "$qbp1" = "$qbp2" ]; then
                ( umask 077; printf 'QB_USER=%s\nQB_PASS=%s\n' "$qbu" "$qbp1" > "$PERSIST/credentials.env" )
                log "  credentials.env gravado"
            else
                log "  senha nao confirmada — qBittorrent pulado"
            fi
            ;;
    esac
else
    log "  sem terminal interativo — qBittorrent pulado (automacao/CI)"
fi

if [ -n "$TUNNEL_UUID" ] && [ -f "$PERSIST/cloudflared/$TUNNEL_UUID.json" ] \
   && [ -f "$PERSIST/cloudflared/config.yml" ]; then
    log "  Cloudflare Tunnel: ja configurado, pulando pergunta"
elif resposta=$(read_tty "  configurar agora o Cloudflare Tunnel? [s/N] "); then
    case "$resposta" in
        s|S|sim|Sim|SIM) setup_cloudflare_tunnel ;;
        *) log "  Cloudflare Tunnel: pulado, veja a secao do README depois" ;;
    esac
else
    log "  sem terminal interativo — Cloudflare Tunnel pulado (automacao/CI)"
fi

# ------------------------------------------------------------------ plex ----
log "== Plex =="
# A logica de ambiente do Plex (variaveis + exec do binario) vive agora em
# 'plexden plex-exec'. ~/bin/plex-start e so um stub que chama o plexden.
mkdir -p "$PLEX_HOME"/bin
cat > "$PLEX_HOME"/bin/plex-start <<'EOF'
#!/bin/sh
exec /usr/local/bin/plexden plex-exec
EOF
chmod +x "$PLEX_HOME"/bin/plex-start
chown -R "$PLEX_USER:$PLEX_USER" "$PLEX_HOME"/bin

PLEX_NOVO=0
if [ -f "$PERSIST/config/Plex Media Server/Preferences.xml" ]; then
    log "  config existente encontrada — claim e bibliotecas preservados"
else
    PLEX_NOVO=1
    log "  config nova: sera preciso claimar em https://plex.tv/claim (ver README)"
fi

# init script (stub SysV -> plexden _init). O pacote do Plex o remove ao
# atualizar; o 'plexden update' e este provision o recriam.
# O mkdir nao e' decorativo: numa Fedora/RHEL enxuta /etc/init.d nem existe
# (vem com initscripts), e sem ele o stub era silenciosamente perdido.
mkdir -p /etc/init.d
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
QBCONF="$PLEX_HOME"/.config/qBittorrent/qBittorrent.conf
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
    chown -R "$PLEX_USER:$PLEX_USER" "$PLEX_HOME"/.config
    log "  config criada"
else
    log "  config ja existe — preservada"
fi

# O aceite do aviso legal precisa estar la mesmo num conf preexistente: sem ele,
# um qBittorrent 4.x (que nao aceita --confirm-legal-notice) fica pedindo
# confirmacao num terminal que nao existe e nunca sobe. Antes isto so era
# gravado quando o conf era criado do zero.
if ! grep -q '^\[LegalNotice\]' "$QBCONF" 2>/dev/null; then
    printf '\n[LegalNotice]\nAccepted=true\n' >> "$QBCONF"
    chown "$PLEX_USER:$PLEX_USER" "$QBCONF"
    log "  aviso legal aceito no conf existente"
fi

# Alinha usuario/senha da WebUI ao credentials.env. Sem isso, 'plexden qb' pode
# nao logar numa instalacao nova: a serie 4.x usa 'adminadmin', mas a 5.x
# (Fedora) gera uma senha aleatoria a cada boot ate uma ser definida. Faz com
# o qB parado, para a edicao nao ser sobrescrita ao salvar a sessao.
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
        chown -R "$PLEX_USER:$PLEX_USER" "$PLEX_HOME"/.config
        log "  usuario/senha da WebUI alinhados ao credentials.env"
    fi
fi

# ------------------------------------------------------------- cloudflared --
log "== Cloudflare Tunnel: instalando o servico =="
# UUID ja resolvido antes do assistente interativo (env, *.json restaurado do
# volume, ou o tunnel recem-criado pelo wizard). O config.yml entra na condicao
# porque ele tambem e copiado logo abaixo: sem
# isso, faltando so ele, o cp falhava em silencio e o tunnel subia sem rota.
if [ -n "$TUNNEL_UUID" ] && [ -f "$PERSIST/cloudflared/cert.pem" ] \
   && [ -f "$PERSIST/cloudflared/$TUNNEL_UUID.json" ] \
   && [ -f "$PERSIST/cloudflared/config.yml" ]; then
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
    log "         rode de novo o provision.sh num terminal interativo (o assistente"
    log "         acima pergunta e configura), ou veja a secao Tunnel do README"
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
        printf 'QB_USER=%s\nQB_PASS=%s\n' "$QB_U" "$QB_P" > "$PLEX_HOME"/.qbcreds
        chown "$PLEX_USER:$PLEX_USER" "$PLEX_HOME"/.qbcreds
        chmod 600 "$PLEX_HOME"/.qbcreds
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
    # A flag so existe a partir do qB 5; na serie 4.x o binario recusa e nem
    # sobe. La o aceite vem do [LegalNotice] gravado no qBittorrent.conf.
    QB_LEGAL=""
    qbittorrent-nox --help 2>&1 | grep -q -- --confirm-legal-notice \
      && QB_LEGAL=" --confirm-legal-notice"
    su - "$PLEX_USER" -c "qbittorrent-nox --daemon$QB_LEGAL"
    [ -x /etc/init.d/plexmediaserver ] && /etc/init.d/plexmediaserver start
    [ -x /etc/init.d/cloudflared ]     && /etc/init.d/cloudflared start
fi

# --------------------------------------------------------------- resumo -----
echo
log "== Verificacao =="
FALHOU=""
PLEX_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://127.0.0.1:32400/identity 2>/dev/null)
echo "  Plex        HTTP ${PLEX_CODE:-sem resposta}"
[ "$PLEX_CODE" = 200 ] || FALHOU="$FALHOU Plex"
CLAIMED=$(curl -s --max-time 10 http://127.0.0.1:32400/identity 2>/dev/null \
          | grep -o 'claimed="[01]"')
echo "  ${CLAIMED:-claim desconhecido}"

# Reivindicar so faz sentido numa config nova, com o Plex de pe e ainda nao
# reivindicado, e so pergunta com terminal — o token expira em 4 minutos, entao
# so vale a pena pedir aqui, agora que o servico acabou de subir de verdade.
if [ "$PLEX_NOVO" = 1 ] && [ "$PLEX_CODE" = 200 ] && [ "$CLAIMED" = 'claimed="0"' ]; then
    if resposta=$(read_tty "  reivindicar o Plex agora? cole o token de https://plex.tv/claim [Enter p/ pular]: "); then
        if [ -n "$resposta" ]; then
            CLAIM_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST --max-time 10 \
              "http://127.0.0.1:32400/myplex/claim?token=$resposta")
            if [ "$CLAIM_CODE" = 200 ]; then
                log "  claim aceito — reiniciando o Plex para confirmar"
                /usr/local/bin/plexden services restart >/dev/null 2>&1 || true
                for _ in $(seq 1 15); do
                    CLAIMED=$(curl -s --max-time 5 http://127.0.0.1:32400/identity 2>/dev/null \
                              | grep -o 'claimed="[01]"')
                    [ "$CLAIMED" = 'claimed="1"' ] && break
                    sleep 2
                done
                echo "  ${CLAIMED:-claim desconhecido}"
            else
                log "  claim recusado (HTTP $CLAIM_CODE) — token invalido ou expirado?"
                log "         pegue um novo em https://plex.tv/claim e rode de novo o provision.sh"
            fi
        fi
    fi
fi

QB_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://127.0.0.1:8081/ 2>/dev/null)
echo "  qBittorrent HTTP ${QB_CODE:-sem resposta}"
[ "$QB_CODE" = 200 ] || FALHOU="$FALHOU qBittorrent"
# Tunnel e opcional: dizer "PARADO" para quem nunca o configurou e alarme falso.
if pgrep -x cloudflared >/dev/null 2>&1; then
    echo "  cloudflared rodando"
elif [ -f /etc/cloudflared/cert.pem ]; then
    echo "  cloudflared PARADO"
else
    echo "  cloudflared nao configurado (opcional)"
fi

echo
# Sair 0 com servico fora do ar fazia o install.sh anunciar "Software
# instalado" em cima de uma stack que nao subiu.
if [ -n "$FALHOU" ]; then
    log "FALHOU:$FALHOU nao respondeu(ram)."
    log "  Veja o log:      tail -50 /tmp/plex.log"
    log "  Estado da stack: plexden services status"
    log "  Tentar de novo:  sudo plexden services start"
    exit 1
fi
log "Pronto. Se o Plex mostrar claimed=\"0\", siga a secao 'Claim' do README."
