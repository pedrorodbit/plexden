# plexden

[![CI](https://github.com/pedrorodbit/plexden/actions/workflows/ci.yml/badge.svg)](https://github.com/pedrorodbit/plexden/actions/workflows/ci.yml)

Um servidor de mídia caseiro — **Plex + qBittorrent + Cloudflare Tunnel** — que
roda em qualquer Linux e é tocado por um único script Python. Sem framework, sem
dependência exótica: só a biblioteca padrão do Python e utilitários comuns de
linha de comando (`curl`, `pgrep`, `su` e afins).

Foi feito pensando no caso mais chato — um sistema sem systemd nem cron, onde o
PID 1 é literalmente um `bash` e nada sobe sozinho (é o que você encontra num
container minimalista, por exemplo). Ele dá conta disso. Mas não se limita a esse
cenário: num Linux comum, com systemd, também roda de boa — e aí você pode deixar
o systemd cuidar do autostart. O `plexden services` gerencia os três serviços em
qualquer caso — inclusive o cloudflared, detectando sozinho se ele roda via
systemd ou SysV.

## Instalando

Numa máquina nova, como root, uma linha resolve:

```bash
curl -fsSL https://raw.githubusercontent.com/pedrorodbit/plexden/main/install.sh | sudo bash
```

> **Sobre distros:** o instalador (e o `plexden update`) detecta sozinho o seu
> gerenciador de pacotes — `apt`, `dnf`/`yum`, `pacman` ou `zypper` — e segue a
> partir daí. O Plex tem repositório oficial nas famílias Debian e RPM; no Arch
> não há pacote oficial, então o instalador te aponta para o AUR e cuida do
> resto. Detalhes na tabela de [distros suportadas](#distros-suportadas).

Prefere outro caminho ou outro usuário? É só passar por variável de ambiente:

```bash
curl -fsSL https://raw.githubusercontent.com/pedrorodbit/plexden/main/install.sh \
  | sudo PLEXDEN_HOME=/srv/plex PLEXDEN_USER=media bash
```

O instalador baixa o `plexden` e o `provision.sh`, puxa as dependências
(`python3`, `qbittorrent-nox`, o Plex e o `cloudflared`), monta a estrutura de
pastas e sobe o que consegue. No fim, ele te mostra o que falta fazer à mão —
que são justamente as coisas que **não** cabem num repositório público.

## Distros suportadas

O `plexden` é escrito só com a biblioteca padrão do Python, então roda em
qualquer lugar que tenha `python3`. Quem depende da distro é a **instalação** (o
`provision.sh`) e o **`plexden update`** — e esses detectam o gerenciador
sozinhos. Os pacotes base e o `cloudflared` (binário estático) são iguais em
toda parte; o que muda é como o Plex chega.

| Família | Distros | Gerenciador | Plex | CI |
|---|---|---|---|---|
| Debian | Debian, Ubuntu, Mint e derivados | `apt` | pacote oficial | ✅ **instalação completa** |
| RPM (Red Hat) | Fedora, RHEL, Rocky, Alma, CentOS Stream | `dnf` / `yum` | pacote oficial | ✅ Fedora + Alma (dry-run) |
| SUSE | openSUSE, SLES | `zypper` | pacote oficial | ✅ openSUSE Leap (dry-run) |
| Arch | Arch, Manjaro | `pacman` | via **AUR** (manual) | ✅ dry-run |

São dois níveis de teste, e a diferença importa:

- **Instalação completa** (hoje, Debian) — cada push instala a stack do zero num
  container: baixa tudo, sobe os serviços e confere que o Plex responde em
  `:32400`, que a WebUI do qBittorrent responde em `:8081` e autentica com a
  senha gerada, e que o `postprocess` cria hardlink de verdade na biblioteca.
- **Dry-run** (as demais) — roda o `provision.sh --check`, que confere que o
  gerenciador certo foi detectado e que o `plexden` compila sob o Python de lá.
  Valida detecção e sintaxe, não a instalação em si.

Três ressalvas honestas:

- **O Plex vem do pacote oficial, não do repositório.** O instalador ainda tenta
  configurar o repositório do Plex primeiro, mas ele anda quebrado: desde
  fevereiro de 2026 o apt do Debian 13+ verifica assinaturas com o Sequoia, que
  recusa a chave do Plex (a assinatura de vínculo dela é SHA1). Quando isso
  acontece, o instalador remove a entrada de repositório (senão todos os seus
  `apt update` passariam a dar erro) e baixa o pacote oficial direto. Efeito
  colateral: o Plex não é atualizado pelo `apt upgrade`; use o `plexden update`.
- **Arch** — o Plex não tem pacote oficial. O instalador prepara tudo e te manda
  instalar pelo AUR (ex.: `yay -S plex-media-server`); depois é só rodar o
  `provision.sh` de novo. O `plexden update`, no Arch, também aponta pro AUR em
  vez de baixar `.deb`/`.rpm`.
- **Fedora/RHEL** — se o SELinux estiver em *enforcing*, ele pode barrar o Plex
  de seguir os hardlinks da biblioteca ou de varrer pastas fora do lugar
  esperado. Se a biblioteca aparecer vazia mesmo com os arquivos lá, olhe o
  `audit.log` — costuma ser isso.

## Os segredos ficam com você

Este repositório é público, então por princípio ele **não** guarda nada sensível:
nem senha, nem token do Plex, nem as credenciais do túnel. Isso é de propósito —
segredo em histórico de Git é para sempre.

O que você faz depois de instalar:

1. **qBittorrent** — copie o modelo e ponha sua senha:
   ```bash
   cp $PLEXDEN_HOME/credentials.env.example $PLEXDEN_HOME/credentials.env
   chmod 600 $PLEXDEN_HOME/credentials.env   # edite QB_USER / QB_PASS
   sudo $PLEXDEN_HOME/provision.sh           # regenera ~/.qbcreds e a senha da WebUI
   ```
2. **Plex** — um servidor recém-instalado nasce "não reivindicado". Pegue um token
   em [plex.tv/claim](https://plex.tv/claim) (ele expira em 4 minutos) e:
   ```bash
   curl -s -X POST "http://127.0.0.1:32400/myplex/claim?token=SEU_TOKEN"
   sudo plexden services restart
   ```
3. **Cloudflare Tunnel** (opcional) — jogue suas credenciais em
   `$PLEXDEN_HOME/cloudflared/` e rode o `provision.sh` de novo.

## O dia a dia

```bash
sudo plexden services {start|stop|restart|status|watch [segundos]}
plexden qb {list|paths|pause [busca]|resume [busca]|setlocation <dest> [hash]}
plexden postprocess "<nome>" "<caminho>"     # o AutoRun do qBittorrent chama isso
sudo plexden update                          # atualiza o Plex pelo pacote oficial (.deb/.rpm)
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
- **`update`** — o repositório da distro costuma ficar atrás no Plex, então este
  comando baixa o pacote oficial mais novo (`.deb` ou `.rpm`, conforme a família;
  no Arch, aponta pro AUR), faz backup do banco e reinstala.

## Ajustando ao seu setup

O `plexden` procura configuração nesta ordem: variável de ambiente →
`/etc/plexden.conf` → um default razoável.

| Variável | Default | Para quê |
|---|---|---|
| `PLEXDEN_HOME` | `/srv/plexden` | onde a stack vive (de preferência, um volume que persista) |
| `PLEXDEN_USER` | `plex` | usuário que roda os serviços |
| `CF_TUNNEL_UUID` | *(auto)* | UUID do túnel; se em branco, ele acha sozinho pelo `*.json` em `cloudflared/` |

O `provision.sh` grava esses valores em `/etc/plexden.conf` — então, se você
rodar de novo mais tarde, ele lembra do que você escolheu.

## Como as peças se encaixam

Tudo mora em `$PLEXDEN_HOME`, que de preferência fica num volume que persiste —
assim você reinstala (ou recria o container, se for o caso) sem levar seus dados
junto. Nos lugares onde algo externo espera um caminho fixo, deixamos um stub de
uma linha que só chama o `plexden`:

| Arquivo | Chama |
|---|---|
| `/etc/init.d/plexmediaserver` | `plexden _init "$@"` |
| `/usr/local/bin/plex-stack-start` | `plexden services start` (bom para o entrypoint) |
| `~/bin/plex-start` | `plexden plex-exec` |
| AutoRun no `qBittorrent.conf` | `plexden postprocess "%N" "%F"` |

Só um lembrete: num sistema sem init, **nada sobe sozinho** (lembra do PID 1 =
bash?). Para autostart, chame `plexden services start` no boot — um serviço
systemd, o entrypoint do container, o que fizer sentido no seu setup — ou deixe
um `plexden services watch` rodando em segundo plano para reerguer o que cair.

## Sobre a autoria

Este projeto foi escrito por uma IA (Claude, da Anthropic) em parceria com um
humano — que trouxe o problema, as manhas do servidor e os "não, assim não",
revisou cada passo e testou tudo num servidor de verdade.

Nada aqui foi publicado no escuro: rodou, quebrou, foi consertado e rodou de
novo. Ainda assim, é código da internet — use por sua conta e risco, e abra uma
issue se achar algo torto.

## Licença

MIT — veja [LICENSE](LICENSE). Faça o que quiser, só não me culpe se pegar fogo.
