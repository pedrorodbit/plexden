# plexden

[![CI](https://github.com/t00ls-dev/plexden/actions/workflows/ci.yml/badge.svg)](https://github.com/t00ls-dev/plexden/actions/workflows/ci.yml)

Um servidor de mídia caseiro — **Plex + qBittorrent + Cloudflare Tunnel** — que
roda em qualquer Linux e é tocado por um único script Python. Sem framework, sem
dependência exótica: só a biblioteca padrão do Python e utilitários comuns de
linha de comando (`curl`, `pgrep`, `su` e afins).

Foi feito pensando no cenário mais chato: um sistema sem systemd nem cron, onde
o PID 1 é literalmente um `bash` e nada sobe sozinho — é o que você encontra num
container minimalista, por exemplo. Isso funciona bem na família Debian; já onde
o Plex vem em `.rpm`, o próprio pacote se recusa a instalar sem systemd (os
detalhes estão em [distros suportadas](#distros-suportadas)).

Mas não é só para esse cenário chato: num Linux comum, com systemd, o plexden
também roda numa boa, e você pode deixar o systemd cuidar do autostart. Em
qualquer um dos dois casos, o `plexden services` gerencia os três serviços —
inclusive o cloudflared, detectando sozinho se ele roda via systemd ou SysV.

## Instalando

Numa máquina nova, como root, uma linha resolve:

```bash
curl -fsSL https://raw.githubusercontent.com/t00ls-dev/plexden/main/install.sh | sudo bash
```

> **Sobre distros:** o instalador (e o `plexden update`) detecta sozinho o seu
> gerenciador de pacotes — `apt` ou `dnf`/`yum` — e segue a partir daí. O Plex
> tem repositório oficial nas duas famílias. Detalhes na tabela de
> [distros suportadas](#distros-suportadas).

O usuário que roda os serviços é sempre quem instalou: quem chamou o `sudo`,
ou o próprio `root` se você já estiver numa sessão root. Não dá mais para
escolher outro usuário por variável de ambiente.

Já o caminho onde a stack vive, o instalador **pergunta durante a instalação**
(padrão `/srv/plexden`) — não precisa passar nada, é só responder quando ele
perguntar. A variável `PLEXDEN_HOME` serve para pular essa pergunta em
automação ou CI.

Antes de mexer em qualquer coisa, ele te conta duas coisas — nenhuma delas
trava a instalação, é só informativo:

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

O **tier** é o mesmo da tabela de [distros suportadas](#distros-suportadas): o
instalador já te avisa com o que você pode contar, sem você precisar ir atrás.
O **veredito** é `roda com folga`, `dá conta` ou `no limite`, com o motivo de
cada ressalva. Ele mede núcleos, RAM e disco — não a velocidade de
transcodificação, que depende do modelo da CPU e nenhum número aqui capta.
Quer só ver isso, sem instalar nada? `./provision.sh --check`.

O instalador baixa o `plexden`, o `provision.sh` e o modelo de credenciais,
instala as dependências (`python3`, `qbittorrent-nox`, o Plex e o
`cloudflared`), monta a estrutura de pastas e sobe os serviços. No meio do
caminho, com terminal disponível, ele também **pergunta** pelas três coisas
que não cabem num repositório público — senha do qBittorrent, claim do Plex e,
se você quiser, o Cloudflare Tunnel — em vez de deixar isso para depois (mais
detalhes em [Os segredos ficam com você](#os-segredos-ficam-com-você)). No
fim, mostra só o que ainda ficou pendente.

Se o Plex ou a WebUI do qBittorrent não responderem no fim, o instalador
**para com erro** e aponta o log, em vez de anunciar sucesso sobre uma stack
que não subiu. O túnel não conta nessa checagem: ele é opcional, e não estar
configurado ainda é normal.

## Distros suportadas

O `plexden` é escrito só com a biblioteca padrão do Python, então roda em
qualquer lugar que tenha `python3`. Quem depende da distro é a **instalação**
(o `provision.sh`) e o **`plexden update`** — e os dois detectam o gerenciador
sozinhos. Os pacotes base e o `cloudflared` (binário estático) são iguais em
toda parte; o que muda é como o Plex chega até você.

| Família | Distros | Gerenciador | Plex | Suporte |
|---|---|---|---|---|
| Debian | Debian, Ubuntu, Mint e derivados | `apt` | pacote oficial | **Tier 1** |
| RPM | Fedora, RHEL, Rocky, Alma, CentOS Stream | `dnf` / `yum` | pacote oficial | **Tier 1** |

### O que cada tier promete

Testar e prometer são coisas diferentes. A tabela acima diz onde o código passa;
esta diz com o que você pode contar:

| Tier | Promessa | Onde vale |
|---|---|---|
| **1** | instalação completa roda a cada push; regressão segura o merge | Debian estável, Ubuntu 24.04, Fedora |
| **2** | só o dry-run roda a cada push; regressão vira issue, não bloqueia | AlmaLinux 9 |
| **3** | melhor esforço, sem teste nenhum; issue e PR são bem-vindos | as demais distros das famílias acima — Mint, Rocky… |
| **—** | fora de alcance, e não por falta de vontade | Alpine e qualquer sistema musl, NixOS, Gentoo |

O tier vale para a **distro nomeada**, não para a família inteira. O Mint
herda o caminho de código do Ubuntu, mas ninguém instalou o plexden nele de
verdade — por isso é Tier 3, e não Tier 1 só por parentesco. O `provision.sh`
te diz em que nível você está antes de instalar qualquer coisa.

Sobre o último tier, pra ninguém perder tempo descobrindo na prática:

- **Alpine e outros sistemas musl** — o Plex Media Server só é distribuído em
  builds contra a glibc; não existe versão musl. Isso não é uma lacuna de
  teste que dá pra fechar, é o fim da linha mesmo para esta stack. Se você
  quer um servidor de mídia em container mínimo, o caminho é uma base glibc
  enxuta (`debian:slim`), não o Alpine.
- **NixOS e Gentoo** — o modelo de instalação é outro. Um instalador
  imperativo que grava em `/usr/local/bin` e `/etc/init.d` não é "difícil" no
  NixOS, é inaplicável. O jeito certo seria um pacote Nix próprio, e isso este
  repositório não tem.

Antes desses dois, existe um terceiro nível de teste que não depende de
distro nenhuma: a pasta `tests/` guarda formas de resposta simuladas do
qBittorrent no login. Ela existe porque o qB 5.2 trocou o `200 Ok.` por um
`204` sem corpo, e o `plexden` recusava um login que na verdade tinha
funcionado. Hoje o Fedora exercita essa forma de resposta no CI, mas por
acaso — se ele mudar de versão, essa cobertura some sem nada ficar vermelho.
Os testes simulados não dependem dessa coincidência.

Tem dois níveis de teste de instalação, e a diferença entre eles é o que
separa o Tier 1 do Tier 2:

- **Instalação completa** — três imagens: `debian:stable-slim`,
  `ubuntu:24.04` e `fedora:latest`. A cada push, a stack é instalada do zero
  num container: baixa tudo, sobe os serviços e confere que o Plex responde
  em `:32400`, que a WebUI do qBittorrent responde em `:8081` e autentica com
  a senha gerada, que `pause`/`resume` realmente mudam o estado do torrent,
  que o `postprocess` cria um hardlink de verdade na biblioteca, e que o
  `links --apply` remove o hardlink cuja fonte sumiu — sem tocar num arquivo
  colocado na biblioteca por fora.

  O Ubuntu está na lista por um motivo além de ser um derivado popular: ele
  empacota a série **4.x** do qBittorrent, enquanto as outras imagens trazem
  a **5.x**. Como o qB 5 renomeou os endpoints de `pause`/`resume` para
  `stop`/`start`, é o Ubuntu que garante que o lado antigo desse desvio
  também é testado a cada push.
- **Dry-run** — o `provision.sh --check` roda também em `almalinux:9` e
  confere se o gerenciador certo foi detectado e se o `plexden` compila sob o
  Python de lá. Para o **AlmaLinux, esse é o único nível de teste**: valida
  detecção e sintaxe, não a instalação em si.

Três ressalvas honestas:

- **Onde o Plex vem em `.rpm`, ele exige systemd.** Isso não é escolha nossa:
  o pacote tem um scriptlet que aborta a instalação com *"Plex Media Server
  requires systemd"*. O `.deb` não faz essa checagem, então a promessa de
  rodar num sistema sem init vale para a família Debian, não para RPM. Num
  Fedora ou RHEL normal, que já vem com systemd, isso nem chega a importar.

- **O repositório do Plex nem sempre é aceito, e aí entra o pacote oficial.**
  O instalador tenta o repositório primeiro — é o caminho preferido, porque
  deixa o `apt`/`dnf upgrade` cuidando das atualizações. Mas desde fevereiro
  de 2026 o apt do Debian 13+ passou a verificar assinaturas com o Sequoia,
  que recusa a chave do Plex porque a assinatura de vínculo dela é SHA1. Veja
  o que acontece em cada distro do CI:

  | Distro | Repositório do Plex |
  |---|---|
  | Debian stable | ❌ recusado → cai no pacote oficial |
  | Ubuntu LTS | ✅ funciona |
  | Fedora | ✅ funciona |

  Quando o repositório é recusado, o instalador **remove a entrada** — senão
  todo `apt update` seu passaria a dar erro dali em diante — e baixa o pacote
  oficial direto. Só nesse caso o Plex deixa de ser atualizado pelo
  `apt upgrade`; aí é usar o `plexden update`.
- **Fedora/RHEL** — se o SELinux estiver em *enforcing*, ele pode impedir o
  Plex de seguir os hardlinks da biblioteca ou de varrer pastas fora do lugar
  esperado. Se a biblioteca aparecer vazia mesmo com os arquivos lá, dá uma
  olhada no `audit.log` — geralmente é isso.

## Os segredos ficam com você

Este repositório é público, então por princípio ele **não** guarda nada sensível:
nem senha, nem token do Plex, nem as credenciais do túnel. Isso é de propósito —
segredo em histórico de Git é para sempre.

Por isso essas três coisas nunca vêm prontas — mas também não precisam ser
feitas na mão. Se o `provision.sh` rodar com um terminal interativo de
verdade (é o caso normal do `curl | sudo bash`, contanto que você não tenha
redirecionado a entrada), ele **pergunta cada uma na hora**: senha da WebUI do
qBittorrent, o token de claim do Plex, e — se você quiser — o login e a
criação do Cloudflare Tunnel, tudo por perguntas simples, sem editar nenhum
arquivo. Rodar sem terminal (automação, CI, um script que não é interativo)
pula as perguntas sem travar, e o instalador avisa no fim o que ficou
pendente.

Se você pulou alguma pergunta, ou está automatizando a instalação, dá pra
fazer cada uma na mão a qualquer momento:

1. **qBittorrent** — copie o modelo e coloque sua senha:
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
3. **Cloudflare Tunnel** (opcional) — o `provision.sh` já instalou o binário
   do `cloudflared`; falta só autenticar, criar o túnel e apontar as rotas.
   Isso é feito uma vez, na própria máquina do servidor:

   ```bash
   cloudflared tunnel login                  # abre um link; autorize no navegador
   cloudflared tunnel create plexden         # gera o <UUID>.json e imprime o UUID
   ```

   O `login` deixa um `cert.pem` em `~/.cloudflared/`, e o `create` deixa um
   `<UUID>.json` no mesmo lugar. Mova os dois para dentro do volume persistente
   (é de lá que o `provision.sh` restaura tudo depois, inclusive numa
   reinstalação do zero) e escreva o `config.yml` ao lado:

   ```bash
   mv ~/.cloudflared/cert.pem ~/.cloudflared/*.json "$PLEXDEN_HOME/cloudflared/"
   cat > "$PLEXDEN_HOME/cloudflared/config.yml" <<EOF
   tunnel: <UUID>
   credentials-file: /etc/cloudflared/<UUID>.json

   ingress:
     - hostname: plex.seudominio.com
       service: https://localhost:32400
       originRequest:
         noTLSVerify: true
     - hostname: qb.seudominio.com
       service: http://localhost:8081
     - service: http_status:404
   EOF
   ```

   Falta apontar o DNS para o túnel (também uma vez só, por hostname):

   ```bash
   cloudflared tunnel route dns plexden plex.seudominio.com
   cloudflared tunnel route dns plexden qb.seudominio.com
   ```

   Com os três arquivos (`cert.pem`, `<UUID>.json`, `config.yml`) no lugar,
   rode o `provision.sh` de novo — ele copia tudo para `/etc/cloudflared/` e
   instala o serviço:

   ```bash
   sudo $PLEXDEN_HOME/provision.sh
   plexden services status              # cloudflared deve aparecer rodando
   ```

   (é exatamente isso que o assistente interativo faz por você, só que
   perguntando em vez de você digitar os comandos.)

   > ⚠️ **A rota do Plex no `config.yml` precisa apontar para `https://`, não
   > `http://`.** O Plex serve TLS na mesma porta 32400 e decide o esquema do
   > redirect da web app pelo protocolo de entrada — com origem `http://` ele
   > devolve `Location: http://.../web/index.html`, e se seu domínio for
   > HSTS-preloaded o navegador recusa o redirect e a web app não carrega (a
   > API em `/identity` continua respondendo 200 normalmente, o que engana).
   > Como o certificado interno do Plex é `*.plex.direct`, a rota também
   > precisa de `originRequest.noTLSVerify: true`. O qBittorrent não tem essa
   > exigência — pode ir com `http://` de boa.

## O dia a dia

```bash
sudo plexden services {start|stop|restart|watch [segundos]}
plexden services status                      # só leitura: dispensa root
plexden qb {list|paths|pause [busca]|resume [busca]|setlocation <dest> [hash]}
plexden postprocess "<nome>" "<caminho>"     # o AutoRun do qBittorrent chama isso
plexden links [--apply]                      # download apagado? tira o link da biblioteca
plexden links --scan [--apply]               # redescobre pares por inode (nunca remove)
sudo plexden update                          # atualiza o Plex pelo pacote oficial (.deb/.rpm)
sudo plexden uninstall [--purge] [--yes]     # desinstala a stack (--purge apaga a mídia também)
plexden doctor                                # diagnóstico rápido, só leitura
```

O que cada comando faz:

- **`services`** — sobe, derruba e vigia Plex + qBittorrent + cloudflared. Ele
  checa a saúde de verdade (por HTTP, não só "o processo existe"), então um
  serviço travado é derrubado e reerguido em vez de continuar fingindo que
  está tudo bem.
- **`qb`** — conversa com a WebUI do qBittorrent, usando o usuário/senha
  guardados em `~/.qbcreds`. Dá pra listar, pausar, retomar e mover torrents
  sem abrir o navegador. A busca de `pause`/`resume` é por **trecho do
  nome**, então um termo curto pode pegar vários torrents de uma vez — por
  isso o comando sempre lista o que vai atingir, com estado e progresso de
  cada um, e repete o total no fim. Se aparecer algo como `stalledUP 100%` na
  lista, cuidado: você está prestes a mexer num torrent que já estava
  completo e semeando.

  > Se você adiciona magnets pausados direto pela WebUI (e não pelo
  > `plexden`): em algumas versões do qBittorrent (visto na série 4.5) um
  > torrent adicionado com "iniciar pausado" pode retomar sozinho assim que
  > os metadados do magnet chegam. Depois de adicionar um lote assim, confira
  > com `plexden qb list` e use `plexden qb pause "<termo>"` se algum tiver
  > voltado a baixar.
- **`postprocess`** — quando um download termina, ele decide se é filme ou
  série e cria um **hardlink** na biblioteca. Isso não duplica espaço, e o
  torrent continua semeando a partir do arquivo original.

  Uma ressalva que importa: hardlink não cruza sistema de arquivos. Se
  `torrents/` e a biblioteca estiverem em discos diferentes, ele **copia** em
  vez de linkar — e aí o espaço é duplicado de verdade. O `logs/autorun.log`
  registra qual dos dois aconteceu; mantendo tudo no mesmo volume, esse
  problema nem aparece.

  Outro detalhe que evita confusão: vídeos com menos de **100 MB** são
  ignorados de propósito, pra filtrar amostras e trailers que costumam vir
  junto do torrent. Se um arquivo legítimo e pequeno sumir da biblioteca, é
  por causa disso — e o `autorun.log` registra o descarte.

  Séries são agrupadas por nome do show e temporada, tirados do próprio nome
  do arquivo: `The.Office.S04E01...` vira `series/The Office/Season 04/`.
  Assim, temporadas vindas de torrents diferentes caem na mesma pasta, em vez
  de virarem dez séries soltas.
- **`links`** — o download pode sumir a qualquer momento: você apaga pra
  liberar espaço, perde o interesse, ou o próprio qBittorrent remove o
  torrent junto com os arquivos. O hardlink na biblioteca sobrevive a isso,
  porque passa a segurar o dado sozinho — e o Plex continua anunciando um
  item que às vezes você nem quer mais. Esse comando reconcilia: **fonte
  apagada, o link vai junto**, o diretório de temporada que ficou vazio é
  removido, e o Plex recebe um pedido de rescan.

  O critério usado é procedência, não `nlink`. Toda vez que o `postprocess`
  cria um link, ele anota o par destino → origem em `config/links.json`, e o
  `links` só olha para o que está registrado ali. Isso é proposital: o sinal
  fácil seria "`st_nlink == 1`, então ninguém mais aponta pra esse arquivo" —
  só que isso descreve igualmente bem toda mídia que você copiou pra
  biblioteca na mão, que seria apagada por engano. **O que o `plexden` nunca
  linkou, o `plexden` nunca remove**, e isso vale também para tudo que já
  estava na biblioteca antes de você atualizar pra esta versão.

  Sem `--apply`, ele só lista, não mexe em nada. Duas outras decisões que
  valem saber: se o arquivo na biblioteca não está mais onde foi registrado
  (você renomeou ou moveu), o `plexden` **não sai caçando** — só esquece a
  entrada; e nada fora de `movies/`/`series/` é removido, aconteça o que
  acontecer com o registro. Pra automatizar, basta uma linha de cron:
  `0 4 * * * plexden links --apply`.

  **`links --scan`** resolve o problema de quem já tinha uma biblioteca antes
  desse registro existir: ele nasce vazio, então nada do acervo antigo fica
  acompanhado. A varredura redescobre os pares **pelo inode** — hardlink e
  fonte são o mesmo inode, então o vínculo dá pra identificar sem adivinhar
  por nome ou tamanho. Com `--apply` ela grava os pares que encontrou; **em
  nenhum modo ela apaga arquivo nenhum**. O que não bate fica de fora e
  continua assim: um arquivo sem fonte viva pode ter vindo de um torrent já
  apagado, ou pode ter sido copiado ali na mão — e não dá pra distinguir
  depois do fato. Na dúvida, não se apaga.

  De quebra, ela também mostra a direção inversa: vídeo grande em
  `torrents/` que nunca chegou na biblioteca, ou seja, um `postprocess` que
  não rodou. Numa biblioteca real de 140 arquivos, essa varredura identificou
  93 pares e deixou 47 de fora.
- **`update`** — o que o repositório entrega costuma ficar atrás da versão
  mais nova do Plex (e em algumas distros nem existe repositório
  utilizável), então esse comando baixa o pacote oficial direto (`.deb` ou
  `.rpm`, conforme a família), faz backup do banco e reinstala. Não exige
  servidor reivindicado: sem token ele usa o canal público, e com token
  respeita o canal da sua conta. Se a instalação do pacote falhar, ele sai
  com erro apontando o backup — em vez de deixar você com o Plex parado e um
  "Pronto" na tela.
- **`uninstall`** — para os serviços, desinstala Plex/qBittorrent/cloudflared
  e limpa tudo que o `provision.sh` criou no sistema (stubs, `/etc/plexden.conf`
  etc.). Se houver um Cloudflare Tunnel configurado, ele também é **revogado
  de verdade na Cloudflare** (`cloudflared tunnel delete`), não só apagado
  localmente — o registro DNS que aponta pra ele, porém, não some sozinho;
  isso precisa ser removido à mão pelo painel da Cloudflare. Por padrão
  `$PLEXDEN_HOME` (mídia, banco do Plex, torrents) **fica intacto**; use
  `--purge` se quiser apagar isso também — que pede uma segunda confirmação
  específica (digitar `APAGAR`), inclusive quando `--yes` já foi passado, já
  que essa parte não tem volta. Sem terminal interativo, `--purge` se recusa
  a rodar; a desinstalação normal aceita `--yes` para automação.
- **`doctor`** — só leitura, dispensa root: roda uma bateria de checagens
  (usuário da stack, `/etc/plexden.conf`, pacotes do Plex/qBittorrent
  instalados, os três serviços respondendo, `credentials.env`, espaço em
  disco) e resume tudo como `[OK]`, `[AVISO]` ou `[ERRO]`. Não muda nada no
  sistema — é o primeiro comando pra rodar quando algo parece errado, antes
  de ir atrás de log.

## Problemas comuns

Coisas que já aconteceram numa instalação de verdade e não são óbvias pelo
sintoma:

**A web do Plex para de carregar, mas `https://.../identity` responde 200 —**
é o sintoma clássico do Cloudflare Tunnel apontando o Plex para `http://` em
vez de `https://` no `config.yml`. Veja a ressalva na seção do túnel, acima.
O qBittorrent não sofre disso (ingress HTTP puro), então se só o Plex cair
com esse padrão, é a pista.

**Trocar a senha da sua conta Plex derruba o túnel do Plex (não o do
qBittorrent) —** o efeito é uma cascata só, não vários problemas:

```
troca de senha na conta Plex
  → o token salvo em Preferences.xml é revogado (plex.tv passa a responder 401)
    → o servidor perde o claim (claimed="0")
      → sem token válido, o Plex não renova o certificado *.plex.direct
        → o TLS na porta 32400 para de responder
          → o ingress que aponta pra https://localhost:32400 recebe conexão
            recusada → 502 no domínio do túnel
```

Diagnóstico — o campo `claimed` cai para `"0"` em `/identity`, e um `curl` no
`/api/v2/user` da conta Plex com o token antigo responde `401`. A correção é
só reivindicar de novo (token novo de [plex.tv/claim](https://plex.tv/claim),
mesmo comando do passo 2 acima) — **não mexa no túnel**, a configuração dele
continua certa, só falta o certificado. Biblioteca e metadados não são
afetados: ficam no banco local. Trocar o ingress para `http://` "resolve" o
sintoma e esconde a causa real (o token revogado) — evite fazer isso.

**`claimed` some depois de reiniciar, mesmo sem trocar senha —** normalmente é
o Plex subindo sem `PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR` configurado, o
que faz ele rodar sem enxergar o banco. Suba sempre pelo
`plexden services start`/`restart` (ou o stub que ele instala) — nunca chame o
binário direto com `nohup`, porque é esse comando que exporta a variável certa.

**`pkill -f` via SSH pode derrubar a própria sessão —** um padrão como
`pkill -f "Plex Media Server"` também casa com a linha de comando do processo
SSH que você está usando pra rodar o comando, e mata a própria conexão. Use
`pkill -x` (nome exato) ou rode a partir de um script no servidor em vez de um
one-liner interativo.

## Ajustando ao seu setup

O `plexden` procura configuração nesta ordem: variável de ambiente →
`/etc/plexden.conf` → um valor padrão razoável.

| Variável | Default | Para quê |
|---|---|---|
| `PLEXDEN_HOME` | `/srv/plexden` | onde a stack vive (de preferência, um volume que persista) |
| `PLEXDEN_USER` | *(quem instalou)* | usuário que roda os serviços — não dá pra escolher outro à parte |
| `CF_TUNNEL_UUID` | *(auto)* | UUID do túnel; se em branco, ele acha sozinho pelo `*.json` em `cloudflared/` |

O `provision.sh` grava esses valores em `/etc/plexden.conf` — então, se você
rodar de novo mais tarde (pra reprovisionar), ele lembra do que foi decidido
na primeira instalação, mesmo que seja outro admin rodando o comando dessa vez.

## Como as peças se encaixam

Tudo mora em `$PLEXDEN_HOME`, que de preferência fica num volume que persiste
— assim você reinstala (ou recria o container, se for o caso) sem perder seus
dados. Nos lugares onde algo externo espera um caminho fixo, deixamos um stub
de uma linha que só chama o `plexden`:

| Arquivo | Chama |
|---|---|
| `/etc/init.d/plexmediaserver` | `plexden _init "$@"` |
| `/usr/local/bin/plex-stack-start` | `plexden services start` (bom para o entrypoint) |
| `~/bin/plex-start` | `plexden plex-exec` |
| AutoRun no `qBittorrent.conf` | `plexden postprocess "%N" "%F"` |

Um lembrete: num sistema sem init, **nada sobe sozinho** (lembra do PID 1 =
bash?). Pra ter autostart, chame `plexden services start` no boot — um
serviço systemd, o entrypoint do container, o que fizer mais sentido no seu
setup — ou deixe um `plexden services watch` rodando em segundo plano pra
reerguer o que cair.

## Sobre a autoria

Este projeto foi escrito por uma IA (Claude, da Anthropic) em parceria com um
humano — que trouxe o problema, as manhas do servidor e os "não, assim não",
revisou cada passo e testou tudo num servidor de verdade.

Nada aqui foi publicado no escuro: rodou, quebrou, foi consertado e rodou de
novo. Ainda assim, é código da internet — use por sua conta e risco, e abra uma
issue se achar algo torto.

## Licença

MIT — veja [LICENSE](LICENSE). Faça o que quiser, só não me culpe se pegar fogo.
