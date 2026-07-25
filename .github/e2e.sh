#!/usr/bin/env bash
#
# Bateria de verificacao da stack ja instalada — roda depois do install.sh, em
# qualquer familia de distro. Vive num arquivo (e nao dentro do ci.yml) porque
# dois jobs a executam: o Debian, num container comum, e o RPM, dentro de um
# container com systemd de verdade.
#
#   bash .github/e2e.sh <diretorio-do-checkout>
#
set -euo pipefail

REPO="${1:?uso: e2e.sh <diretorio-do-checkout>}"
PERSIST=/srv/plexden
PLEX_USER=plex
QB=http://127.0.0.1:8081/api/v2
COOKIE=/tmp/qb.cookie
QB_USER=citest
QB_PASS=senha-do-ci-123

log() { echo; echo "== $* =="; }

# Quando algo nao sobe, o que interessa e o motivo — e um daemon que morre nao
# deixa rastro nenhum no log do job. Entao repetimos a subida em primeiro plano
# so para capturar a mensagem.
diagnostico() {
    echo "--- processos da stack ---"
    pgrep -a -f 'qbittorrent-nox|Plex Media Server|cloudflared' || echo "(nenhum)"
    echo "--- qbittorrent-nox em primeiro plano (5s) ---"
    timeout 5 su - "$PLEX_USER" -c 'qbittorrent-nox --confirm-legal-notice' 2>&1 \
      | tail -20 || true
    echo "--- journal do qbittorrent, se houver ---"
    journalctl -n 20 --no-pager 2>/dev/null | tail -20 || echo "(sem journal)"
}
fail() { echo "FALHOU: $*" >&2; diagnostico >&2; exit 1; }

pkg_has() {
    if command -v dpkg >/dev/null 2>&1; then dpkg -s "$1" >/dev/null 2>&1
    else rpm -q "$1" >/dev/null 2>&1; fi
}

# --------------------------------------------------------------------------
log "O que ficou instalado e o deste commit"
cmp "$PERSIST/scripts/plexden" "$REPO/plexden"
cmp "$PERSIST/provision.sh"    "$REPO/provision.sh"
echo "  byte a byte"

# --------------------------------------------------------------------------
log "Binarios, stubs e config no lugar"
command -v curl     >/dev/null || fail "curl ausente"
command -v plexden  >/dev/null || fail "plexden nao instalado"
cloudflared --version                         # binario estatico baixado e +x
pkg_has plexmediaserver || fail "plexmediaserver nao instalado"
pkg_has qbittorrent-nox || fail "qbittorrent-nox nao instalado"
id "$PLEX_USER" >/dev/null
for f in /etc/init.d/plexmediaserver /usr/local/bin/plex-stack-start \
         "/home/$PLEX_USER/bin/plex-start"; do
    [ -x "$f" ] || fail "$f nao e executavel"
done
grep -qx "PLEXDEN_HOME=$PERSIST" /etc/plexden.conf || fail "/etc/plexden.conf errado"
grep -qx "PLEXDEN_USER=$PLEX_USER" /etc/plexden.conf || fail "/etc/plexden.conf errado"
for d in movies series config scripts cloudflared \
         torrents/complete torrents/incomplete; do
    [ -d "$PERSIST/$d" ] || fail "faltou $PERSIST/$d"
done
[ "$(stat -c %U "$PERSIST/movies")" = "$PLEX_USER" ] || fail "dono errado em movies/"
[ "$(stat -c %a "$PERSIST/cloudflared")" = 700 ] || fail "cloudflared/ deveria ser 700"
grep -q 'plexden postprocess' "/home/$PLEX_USER/.config/qBittorrent/qBittorrent.conf" \
    || fail "AutoRun nao aponta para o plexden"
echo "  ok"

# --------------------------------------------------------------------------
log "Servicos no ar"
wait_http() {   # $1 = url, $2 = rotulo
    for _ in $(seq 1 45); do
        c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" || true)
        case "$c" in 2*|3*|4*) echo "  $2 HTTP $c"; return 0 ;; esac
        sleep 2
    done
    fail "$2 nao respondeu ($1)"
}
wait_http http://127.0.0.1:8081/          qBittorrent
wait_http http://127.0.0.1:32400/identity Plex
plexden services status

# --------------------------------------------------------------------------
# Exercita o caminho dos segredos (senha da WebUI sedeada por PBKDF2 e o
# ~/.qbcreds regenerado) e, de quebra, prova que reprovisionar e idempotente.
log "credentials.env -> reprovisiona -> 'plexden qb' loga"
printf 'QB_USER=%s\nQB_PASS=%s\n' "$QB_USER" "$QB_PASS" > "$PERSIST/credentials.env"
bash "$PERSIST/provision.sh"
[ "$(stat -c %a "$PERSIST/credentials.env")" = 600 ] || fail "credentials.env sem 600"
grep -qx "QB_USER=$QB_USER" "/home/$PLEX_USER/.qbcreds" || fail ".qbcreds nao regenerado"
grep -q 'WebUI\\Password_PBKDF2=' \
    "/home/$PLEX_USER/.config/qBittorrent/qBittorrent.conf" || fail "senha nao sedeada"
su - "$PLEX_USER" -c 'plexden qb list'    # o que importa: a senha autentica

# --------------------------------------------------------------------------
# O qB 5.0 (Web API 2.11) renomeou pause->stop e resume->start, e o plexden
# escolhe o endpoint pela versao. Sem um torrent na lista o comando sai cedo com
# "nenhum torrent" e o gate nunca roda — dai o .torrent gerado aqui. Nao ha rede
# envolvida: o tracker nao existe, o torrent so precisa aparecer na lista.
log "qb pause/resume (gate de endpoint do qB 5)"
python3 - <<'PY'
import hashlib, os
data = os.urandom(262144)
open('/srv/plexden/torrents/complete/plexden-ci.bin', 'wb').write(data)
def be(o):
    if isinstance(o, int):   return b'i%de' % o
    if isinstance(o, bytes): return b'%d:%s' % (len(o), o)
    if isinstance(o, dict):
        return b'd' + b''.join(be(k) + be(v) for k, v in sorted(o.items())) + b'e'
    raise TypeError(o)
torrent = {
    b'announce': b'http://127.0.0.1:6969/announce',
    b'info': {b'name': b'plexden-ci.bin', b'piece length': 262144,
              b'pieces': hashlib.sha1(data).digest(), b'length': len(data)},
}
open('/tmp/ci.torrent', 'wb').write(be(torrent))
PY
chown "$PLEX_USER:$PLEX_USER" "$PERSIST/torrents/complete/plexden-ci.bin"

curl -s -c $COOKIE -d "username=$QB_USER&password=$QB_PASS" "$QB/auth/login" | grep -q Ok
curl -s -b $COOKIE -F 'torrents=@/tmp/ci.torrent' -F 'skip_checking=true' \
     -F "savepath=$PERSIST/torrents/complete" "$QB/torrents/add" | grep -q Ok

state() {
    curl -s -b $COOKIE "$QB/torrents/info" \
      | python3 -c 'import json,sys; t=json.load(sys.stdin); print(t[0]["state"] if t else "")'
}
for _ in $(seq 1 20); do [ -n "$(state)" ] && break; sleep 1; done
[ -n "$(state)" ] || fail "o torrent nao entrou na lista"
echo "  estado inicial: $(state)"

su - "$PLEX_USER" -c 'plexden qb pause'
for _ in $(seq 1 20); do
    case "$(state)" in stopped*|paused*) break ;; esac; sleep 1
done
case "$(state)" in
    stopped*|paused*) echo "  pausado: $(state)" ;;
    *) fail "qb pause nao pausou (estado: $(state))" ;;
esac

su - "$PLEX_USER" -c 'plexden qb resume'
for _ in $(seq 1 20); do
    case "$(state)" in stopped*|paused*) sleep 1 ;; *) break ;; esac
done
case "$(state)" in
    stopped*|paused*) fail "qb resume nao retomou (estado: $(state))" ;;
    *) echo "  retomado: $(state)" ;;
esac

curl -s -b $COOKIE -d 'hashes=all&deleteFiles=false' "$QB/torrents/delete" >/dev/null
rm -f "$PERSIST/torrents/complete/plexden-ci.bin"

# --------------------------------------------------------------------------
log "postprocess cria hardlink na biblioteca"
C="$PERSIST/torrents/complete"
# acima do MIN_VIDEO_MB (100), senao o postprocess ignora de proposito
dd if=/dev/zero of="$C/The.Office.S04E01.1080p.WEB.mkv"  bs=1M count=120 status=none
dd if=/dev/zero of="$C/Blade.Runner.2049.2017.1080p.mkv" bs=1M count=120 status=none
chown -R "$PLEX_USER:$PLEX_USER" "$C"
su - "$PLEX_USER" -c "plexden postprocess 'The.Office.S04E01.1080p.WEB'  '$C/The.Office.S04E01.1080p.WEB.mkv'"
su - "$PLEX_USER" -c "plexden postprocess 'Blade.Runner.2049.2017.1080p' '$C/Blade.Runner.2049.2017.1080p.mkv'"
[ -f "$PERSIST/series/The Office/Season 04/The.Office.S04E01.1080p.WEB.mkv" ] \
    || fail "serie nao foi agrupada em series/The Office/Season 04/"
[ -f "$PERSIST/movies/Blade.Runner.2049.2017.1080p.mkv" ] || fail "filme nao foi linkado"
# hardlink de verdade, nao copia: e o ponto do design
[ "$(stat -c %h "$C/The.Office.S04E01.1080p.WEB.mkv")" = 2 ] || fail "nao virou hardlink"
echo "  hardlink confirmado (nlink 2)"

# --------------------------------------------------------------------------
log "Ciclo de vida dos servicos"
plexden services stop
plexden services start
plexden services status

echo
echo "== e2e OK =="
