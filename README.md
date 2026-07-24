# plexctl

Um servidor de mídia caseiro — **Plex + qBittorrent + Cloudflare Tunnel** — que
cabe num container Linux enxuto e é tocado por um único script Python. Sem
framework, sem dependência exótica: só a biblioteca padrão do Python e alguns
utilitários que qualquer Linux já traz.

Nasceu para aqueles containers pelados, sem systemd nem cron, onde o PID 1 é
literalmente um `bash`. Se o seu ambiente é assim, você está no lugar certo.

## Instalando

Num container novo, como root, uma linha resolve:

```bash
curl -fsSL https://raw.githubusercontent.com/pedrorodbit/plexctl/main/install.sh | sudo bash
```

> **Um detalhe honesto:** o instalador usa `apt`/`dpkg` para puxar Plex,
> qBittorrent e cloudflared, então ele espera uma distro dessa família (Debian,
> Ubuntu e derivados). O `plexctl` em si é agnóstico; quem é preso ao `apt` é só
> a instalação e o `plexctl update`.

Prefere outro caminho ou outro usuário? É só passar por variável de ambiente:

```bash
curl -fsSL https://raw.githubusercontent.com/pedrorodbit/plexctl/main/install.sh \
  | sudo PLEXCTL_HOME=/srv/plex PLEXCTL_USER=media bash
```

O instalador baixa o `plexctl` e o `provision.sh`, puxa as dependências
(`python3`, `qbittorrent-nox`, o Plex e o `cloudflared`), monta a estrutura de
pastas e sobe o que consegue. No fim, ele te mostra o que falta fazer à mão —
que são justamente as coisas que **não** cabem num repositório público.

## Os segredos ficam com você

Este repositório é público, então por princípio ele **não** guarda nada sensível:
nem senha, nem token do Plex, nem as credenciais do túnel. Isso é de propósito —
segredo em histórico de Git é para sempre.

O que você faz depois de instalar:

1. **qBittorrent** — copie o modelo e ponha sua senha:
   ```bash
   cp $PLEXCTL_HOME/credentials.env.example $PLEXCTL_HOME/credentials.env
   chmod 600 $PLEXCTL_HOME/credentials.env   # edite QB_USER / QB_PASS
   sudo $PLEXCTL_HOME/provision.sh           # regenera o ~/.qbcreds
   ```
2. **Plex** — um servidor recém-instalado nasce "não reivindicado". Pegue um token
   em [plex.tv/claim](https://plex.tv/claim) (ele expira em 4 minutos) e:
   ```bash
   curl -s -X POST "http://127.0.0.1:32400/myplex/claim?token=SEU_TOKEN"
   sudo plexctl services restart
   ```
3. **Cloudflare Tunnel** (opcional) — jogue suas credenciais em
   `$PLEXCTL_HOME/cloudflared/` e rode o `provision.sh` de novo.

## O dia a dia

```bash
sudo plexctl services {start|stop|restart|status|watch [segundos]}
plexctl qb {list|paths|pause [busca]|resume [busca]|setlocation <dest> [hash]}
plexctl postprocess "<nome>" "<caminho>"     # o AutoRun do qBittorrent chama isso
sudo plexctl update                          # atualiza o Plex pelo .deb oficial
```

O que cada um faz:

- **`services`** — sobe, derruba e vigia Plex + qBittorrent + cloudflared. Ele
  checa saúde de verdade (HTTP, não só "o processo existe"), então um serviço
  travado é derrubado e reerguido em vez de fingir que está tudo bem.
- **`qb`** — conversa com a WebUI do qBittorrent (login por usuário/senha guardado
  em `~/.qbcreds`). Listar, pausar, retomar, mover — sem abrir o navegador.
- **`postprocess`** — quando um download termina, decide se é filme ou série e
  cria um **hardlink** na biblioteca (sem duplicar espaço, e o torrent continua
  semeando do arquivo original). Séries são agrupadas por show e temporada
  tiradas do próprio nome do arquivo — `The.Office.S04E01...` vira
  `series/The Office/Season 04/`, então temporadas de torrents diferentes caem na
  mesma pasta em vez de virarem dez séries soltas.
- **`update`** — o `apt` costuma ficar atrás no Plex, então este comando baixa o
  `.deb` oficial, faz backup do banco e reinstala.

## Ajustando ao seu setup

O `plexctl` procura configuração nesta ordem: variável de ambiente →
`/etc/plexctl.conf` → um default razoável.

| Variável | Default | Para quê |
|---|---|---|
| `PLEXCTL_HOME` | `/var/www/html/plex` | onde a stack vive (de preferência, um volume que persista) |
| `PLEXCTL_USER` | `plex` | usuário que roda os serviços |
| `CF_TUNNEL_UUID` | *(auto)* | UUID do túnel; se em branco, ele acha sozinho pelo `*.json` em `cloudflared/` |

O `provision.sh` grava esses valores em `/etc/plexctl.conf` — então, se você
rodar de novo mais tarde, ele lembra do que você escolheu.

## Como as peças se encaixam

Tudo mora em `$PLEXCTL_HOME`, que idealmente é um bind mount — assim o container
pode ser recriado sem levar seus dados junto. Nos lugares onde algo externo
espera um caminho fixo, deixamos um stub de uma linha que só chama o `plexctl`:

| Arquivo | Chama |
|---|---|
| `/etc/init.d/plexmediaserver` | `plexctl _init "$@"` |
| `/usr/local/bin/plex-stack-start` | `plexctl services start` (bom para o entrypoint) |
| `~/bin/plex-start` | `plexctl plex-exec` |
| AutoRun no `qBittorrent.conf` | `plexctl postprocess "%N" "%F"` |

Só um lembrete: **nada sobe sozinho** aqui (lembra do PID 1 = bash?). Para
autostart, chame `plexctl services start` no entrypoint do container, ou deixe um
`plexctl services watch` rodando em segundo plano para reerguer o que cair.

## Sobre a autoria

Este projeto foi escrito por uma IA (Claude, da Anthropic) em parceria com um
humano — que trouxe o problema, as manhas do servidor e os "não, assim não",
revisou cada passo e testou tudo num servidor de verdade.

Nada aqui foi publicado no escuro: rodou, quebrou, foi consertado e rodou de
novo. Ainda assim, é código da internet — use por sua conta e risco, e abra uma
issue se achar algo torto.

## Licença

MIT — veja [LICENSE](LICENSE). Faça o que quiser, só não me culpe se pegar fogo.
