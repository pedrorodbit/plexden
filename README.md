# plexctl

Stack de mídia auto-hospedada em um container Debian: **Plex Media Server +
qBittorrent + Cloudflare Tunnel**, gerenciada por um único script Python
(`plexctl`) — sem dependências além da biblioteca padrão.

Pensado para containers minimalistas onde **PID 1 = bash** (sem systemd, sem
cron, sem `start-stop-daemon`).

## Instalação

Num container Debian novo (como root):

```bash
curl -fsSL https://raw.githubusercontent.com/pedrorodbit/plexctl/main/install.sh | sudo bash
```

Personalizando caminho e usuário:

```bash
curl -fsSL https://raw.githubusercontent.com/pedrorodbit/plexctl/main/install.sh \
  | sudo PLEXCTL_HOME=/srv/plex PLEXCTL_USER=media bash
```

O instalador baixa o `plexctl` + `provision.sh`, instala as dependências
(`python3`, `qbittorrent-nox`, Plex, `cloudflared`), cria a estrutura persistente
e sobe o que der. Ao final, imprime os passos com **segredos** (claim do Plex,
senha do qBittorrent, credenciais do túnel) — que **você fornece na hora**, pois
nunca ficam no repositório.

> ⚠️ **Segredos nunca são versionados.** Copie `credentials.env.example` para
> `credentials.env` (fora do Git) e ponha as credenciais do túnel em
> `$PLEXCTL_HOME/cloudflared/`. Veja `.gitignore`.

## Comandos

```bash
sudo plexctl services {start|stop|restart|status|watch [segundos]}
plexctl qb {list|paths|pause [busca]|resume [busca]|setlocation <dest> [hash]}
plexctl postprocess "<nome>" "<caminho>"     # chamado pelo AutoRun do qBittorrent
sudo plexctl update                          # atualiza o Plex via .deb oficial
```

| Subcomando | O que faz |
|---|---|
| `services` | sobe/derruba/vigia Plex + qBittorrent + cloudflared, com health-check HTTP real |
| `qb` | controla o qBittorrent pela WebUI API (login por usuário/senha em `~/.qbcreds`) |
| `postprocess` | detecta filme/série e cria **hardlinks** na biblioteca, agrupando temporadas em `series/<Show>/Season NN/` |
| `update` | baixa o `.deb` oficial do Plex, faz backup do banco e reinstala |

## Configuração

`plexctl` lê, nesta ordem: variáveis de ambiente → `/etc/plexctl.conf` → defaults.

| Variável | Default | Descrição |
|---|---|---|
| `PLEXCTL_HOME` | `/var/www/html/plex` | diretório persistente da stack |
| `PLEXCTL_USER` | `plex` | usuário que roda os serviços |
| `CF_TUNNEL_UUID` | *(auto)* | UUID do túnel; se vazio, detecta pelo `*.json` em `cloudflared/` |

O `provision.sh` grava `/etc/plexctl.conf` com os valores escolhidos.

## Arquitetura

Tudo vive em `$PLEXCTL_HOME` (um bind mount que persiste à recriação do
container). Pontos de integração de caminho fixo são stubs de 1 linha que chamam
o `plexctl`:

| Arquivo | Aponta para |
|---|---|
| `/etc/init.d/plexmediaserver` | `plexctl _init "$@"` |
| `/usr/local/bin/plex-stack-start` | `plexctl services start` (entrypoint) |
| `~/bin/plex-start` | `plexctl plex-exec` |
| AutoRun no `qBittorrent.conf` | `plexctl postprocess "%N" "%F"` |

> Nada sobe sozinho (PID 1 = bash). Para autostart, chame `plexctl services start`
> no entrypoint do container, ou deixe um `plexctl services watch` em background.

## Licença

MIT — veja [LICENSE](LICENSE).
