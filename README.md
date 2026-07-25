# plexden

[![CI](https://github.com/pedrorodbit/plexden/actions/workflows/ci.yml/badge.svg)](https://github.com/pedrorodbit/plexden/actions/workflows/ci.yml)

Um servidor de mídia caseiro — **Plex + qBittorrent + Cloudflare Tunnel** — que
roda em qualquer Linux e é tocado por um único script Python. Sem framework, sem
dependência exótica: só a biblioteca padrão do Python e utilitários comuns de
linha de comando (`curl`, `pgrep`, `su` e afins).

Foi feito pensando no caso mais chato — um sistema sem systemd nem cron, onde o
PID 1 é literalmente um `bash` e nada sobe sozinho (é o que você encontra num
container minimalista, por exemplo). Ele dá conta disso — na família Debian; onde
o Plex vem em `.rpm` o próprio pacote se recusa a instalar sem systemd, e isso
está detalhado em [distros suportadas](#distros-suportadas). Mas não se limita a esse
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

Antes de tocar em qualquer coisa, ele te diz duas coisas — e nenhuma delas
impede a instalação, só informa:

```
== Cobertura de teste deste SO ==
  SO: Ubuntu 22.04.5 LTS
  Tier 3 — o CI testa o Ubuntu 24.04, nao o 22.04.
           Mesmo caminho de codigo, versao nao exercitada.
== Este computador ==
  CPU:     2 nucleo(s) — Intel(R) Core(TM) i5-8250U
  Memoria: 2.0 GB
  Disco:   60.0 GB livres para /srv/plexden
  VEREDITO: da conta
            - RAM entre 1,5 e 3 GB: da para reproducao direta, aperta se transcodificar
            - menos de 4 nucleos: um transcode 1080p por vez, no maximo
            - menos de 100 GB livres: da para comecar, planeje o crescimento
```

O **tier** é o mesmo da tabela de [distros suportadas](#distros-suportadas) — o
instalador te diz com o que você pode contar antes de começar, em vez de você
ter que procurar. O **veredito** é `roda com folga`, `dá conta` ou `no limite`, com o motivo de cada
ressalva — e ele mede núcleos, RAM e disco, não velocidade de transcodificação,
que depende do modelo da CPU e nenhum número ali captura. Para só ver isso, sem
instalar nada: `./provision.sh --check`.

O instalador baixa o `plexden`, o `provision.sh` e o modelo de credenciais, puxa
as dependências
(`python3`, `qbittorrent-nox`, o Plex e o `cloudflared`), monta a estrutura de
pastas e sobe os serviços. No fim, ele te mostra o que falta fazer à mão — que
são justamente as coisas que **não** cabem num repositório público.

Se o Plex ou a WebUI do qBittorrent não responderem ao final, o instalador
**para com erro** e aponta o log, em vez de anunciar sucesso sobre uma stack que
não subiu. O túnel não conta: ele é opcional e a ausência dele é normal.

## Distros suportadas

O `plexden` é escrito só com a biblioteca padrão do Python, então roda em
qualquer lugar que tenha `python3`. Quem depende da distro é a **instalação** (o
`provision.sh`) e o **`plexden update`** — e esses detectam o gerenciador
sozinhos. Os pacotes base e o `cloudflared` (binário estático) são iguais em
toda parte; o que muda é como o Plex chega.

| Família | Distros | Gerenciador | Plex | Suporte |
|---|---|---|---|---|
| Debian | Debian, Ubuntu, Mint e derivados | `apt` | pacote oficial | **Tier 1** |
| RPM (Red Hat) | Fedora, RHEL, Rocky, Alma, CentOS Stream | `dnf` / `yum` | pacote oficial | **Tier 1** |
| SUSE | openSUSE, SLES | `zypper` | pacote oficial | **Tier 1** |
| Arch | Arch, Manjaro | `pacman` | via **AUR** (manual) | **Tier 2** |

### O que cada tier promete

Testar e prometer são coisas diferentes. A tabela acima diz onde o código passa;
esta diz com o que você pode contar:

| Tier | Promessa | Onde vale |
|---|---|---|
| **1** | instalação completa roda a cada push; regressão segura o merge | Debian estável, Ubuntu 24.04, Fedora, openSUSE Leap |
| **2** | só o dry-run roda a cada push; regressão vira issue, não bloqueia | Arch, AlmaLinux 9 |
| **3** | melhor esforço, sem teste nenhum; issue e PR são bem-vindos | as demais distros das famílias acima — Mint, Rocky, SLES, Manjaro… |
| **—** | fora de alcance, e não por falta de vontade | Alpine e qualquer sistema musl, NixOS, Gentoo |

O tier vale para a **distro nomeada**, não para a família inteira. Mint herda o
caminho de código do Ubuntu, mas ninguém instalou nele — por isso é Tier 3, e
não Tier 1 por parentesco. O `provision.sh` te diz em que nível você está antes
de instalar qualquer coisa.

Sobre o último tier, para ninguém perder tempo descobrindo na prática:

- **Alpine e outros sistemas musl** — o Plex Media Server é distribuído só em
  builds contra a glibc; não há versão musl. Não é uma lacuna de teste que dá
  para fechar, é o fim da linha para esta stack. Se você quer um servidor de
  mídia em container mínimo, o caminho é uma base glibc enxuta (`debian:slim`),
  não o Alpine.
- **NixOS e Gentoo** — o modelo de instalação é outro. Um instalador imperativo
  que grava em `/usr/local/bin` e `/etc/init.d` não é "difícil" no NixOS, é
  inaplicável. O jeito certo seria um pacote Nix próprio, e isso este repositório
  não tem.

Antes dos dois, há um terceiro nível que não depende de distro nenhuma:
`tests/` guarda as formas de resposta que o qBittorrent usa no login, simuladas.
Existe porque o qB 5.2 trocou o `200 Ok.` por um `204` sem corpo e o `plexden`
recusava um login que tinha funcionado. Hoje o Fedora exercita essa forma no CI,
mas por acaso — se ele mudar de versão, a cobertura sumiria sem nada ficar
vermelho. Os testes simulados não dependem dessa coincidência.

São duas profundidades de teste de instalação, e a diferença é o que separa o
Tier 1 do Tier 2:

- **Instalação completa** — exatamente quatro imagens: `debian:stable-slim`,
  `ubuntu:24.04`, `fedora:latest` e `opensuse/leap:latest`. Cada push instala a
  stack do zero num container: baixa tudo, sobe os serviços e confere que o Plex
  responde em `:32400`, que a WebUI do qBittorrent responde em `:8081` e
  autentica com a senha gerada, que `pause`/`resume` de fato mudam o estado do
  torrent, e que o `postprocess` cria hardlink de verdade na biblioteca.

  O Ubuntu está aí por um motivo além de ser derivado popular: ele empacota a
  série **4.x** do qBittorrent, enquanto as outras três trazem a **5.x**. Como o
  qB 5 renomeou os endpoints de `pause`/`resume` para `stop`/`start`, é ele que
  garante que o lado antigo desse desvio também é exercitado a cada push.
- **Dry-run** — o `provision.sh --check` roda em cinco imagens
  (`debian:stable-slim`, `fedora:latest`, `almalinux:9`, `opensuse/leap:latest`,
  `archlinux:latest`) e confere que o gerenciador certo foi detectado e que o
  `plexden` compila sob o Python de lá. Para **Arch e AlmaLinux esse é o único
  nível**: valida detecção e sintaxe, não a instalação em si — foi justamente uma
  instalação de verdade que revelou que o openSUSE chama `procps` o que o Fedora
  chama `procps-ng`.

Quatro ressalvas honestas:

- **Onde o Plex vem em `.rpm`, ele exige systemd.** Não é escolha nossa: o
  pacote tem um scriptlet que aborta a instalação com *"Plex Media Server
  requires systemd"*. O `.deb` não faz essa checagem — por isso a promessa de
  rodar num sistema sem init vale para a família Debian, e não para RPM nem
  SUSE. Num Fedora, RHEL ou openSUSE normal (que têm systemd) não muda nada.

- **O repositório do Plex nem sempre é aceito — e aí entra o pacote oficial.** O
  instalador tenta o repositório primeiro, que é o caminho preferido (deixa o
  `apt`/`dnf upgrade` cuidar das atualizações). Mas desde fevereiro de 2026 o
  apt do Debian 13+ verifica assinaturas com o Sequoia, que recusa a chave do
  Plex porque a assinatura de vínculo dela é SHA1. O que acontece em cada distro
  do CI:

  | Distro | Repositório do Plex |
  |---|---|
  | Debian stable | ❌ recusado → cai no pacote oficial |
  | Ubuntu LTS | ✅ funciona |
  | Fedora | ✅ funciona |
  | openSUSE Leap | ✅ funciona |

  Quando o repositório é recusado, o instalador **remove a entrada** — senão
  todos os seus `apt update` passariam a dar erro daí em diante — e baixa o
  pacote oficial direto. Só nesse caso o Plex deixa de ser atualizado pelo
  `apt upgrade`; aí use o `plexden update`.
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
sudo plexden services {start|stop|restart|watch [segundos]}
plexden services status                      # só leitura: dispensa root
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
  semeando do arquivo original). Uma ressalva que importa: hardlink não cruza
  sistema de arquivos, então se `torrents/` e a biblioteca ficarem em discos
  diferentes ele **copia** — e aí o espaço é duplicado de verdade. O log em
  `logs/autorun.log` diz qual dos dois aconteceu. Mantenha os dois no mesmo
  volume e o problema não existe. Séries são agrupadas por show e temporada
  tiradas do próprio nome do arquivo — `The.Office.S04E01...` vira
  `series/The Office/Season 04/`, então temporadas de torrents diferentes caem na
  mesma pasta em vez de virarem dez séries soltas.
- **`update`** — o que o repositório entrega costuma ficar atrás da versão mais
  nova do Plex (e em algumas distros nem há repositório utilizável), então este
  comando baixa o pacote oficial direto (`.deb` ou `.rpm`, conforme a família;
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
