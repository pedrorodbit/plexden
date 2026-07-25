#!/usr/bin/env python3
"""'plexden links': fonte do torrent apagada, o hardlink vai junto.

O download pode sumir por muito motivo — a pessoa apaga para poupar espaco,
perde o interesse, ou o qBittorrent remove o torrent com os arquivos. O que
sobra e uma entrada na biblioteca que o Plex exibe e que da erro ao abrir.

O teste que importa aqui e o test_arquivo_de_fora_nunca_e_tocado: o criterio
ingenuo para achar orfaos seria st_nlink == 1, so que isso tambem descreve toda
a midia copiada para a biblioteca por fora do plexden. Numa biblioteca real
esse criterio apagaria acervo que o plexden nunca linkou.
"""
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import tempfile
import unittest
from contextlib import redirect_stdout

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _carrega_plexden(home):
    """Carrega o plexden com PLEXDEN_HOME apontando para um diretorio de teste.

    As constantes de caminho sao resolvidas no import, entao cada cenario
    precisa da sua propria copia do modulo.
    """
    os.environ["PLEXDEN_HOME"] = home
    loader = importlib.machinery.SourceFileLoader(
        "plexden_links", os.path.join(RAIZ, "plexden"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    # Nao ha Plex no ambiente de teste; o scan e efeito colateral, nao criterio.
    mod._trigger_scan = lambda _d: None
    return mod


class TestLinks(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="plexden-links-")
        self.completo = os.path.join(self.home, "torrents", "complete")
        os.makedirs(self.completo)
        self.p = _carrega_plexden(self.home)
        os.makedirs(self.p.MOVIES, exist_ok=True)
        os.makedirs(self.p.SERIES, exist_ok=True)

    def tearDown(self):
        shutil.rmtree(self.home, ignore_errors=True)
        os.environ.pop("PLEXDEN_HOME", None)

    # -- auxiliares ---------------------------------------------------------
    def _video(self, nome, diretorio=None):
        """Cria um video acima do MIN_VIDEO_MB, senao o postprocess ignora."""
        caminho = os.path.join(diretorio or self.completo, nome)
        os.makedirs(os.path.dirname(caminho), exist_ok=True)
        with open(caminho, "wb") as f:
            f.write(b"\0" * ((self.p.MIN_VIDEO_MB + 1) * 1024 * 1024))
        return caminho

    def _links(self, *args):
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = self.p.cmd_links(list(args))
        return rc, buf.getvalue()

    def _razao(self):
        with open(self.p.LINKS_DB) as f:
            return json.load(f)["links"]

    # -- cenarios -----------------------------------------------------------
    def test_postprocess_registra_o_par_destino_origem(self):
        src = self._video("Blade.Runner.2049.2017.1080p.mkv")
        self.p.cmd_postprocess(["Blade.Runner.2049.2017.1080p", src])
        dst = os.path.join(self.p.MOVIES, "Blade.Runner.2049.2017.1080p.mkv")
        self.assertIn(dst, self._razao())
        self.assertEqual(self._razao()[dst]["src"], src)

    def test_fonte_presente_nada_e_removido(self):
        src = self._video("Blade.Runner.2049.2017.1080p.mkv")
        self.p.cmd_postprocess(["Blade.Runner.2049.2017.1080p", src])
        dst = os.path.join(self.p.MOVIES, "Blade.Runner.2049.2017.1080p.mkv")
        rc, saida = self._links("--apply")
        self.assertEqual(rc, 0)
        self.assertTrue(os.path.exists(dst), "removeu com a fonte ainda no lugar")
        self.assertIn("removidos 0 link(s)", saida)

    def test_fonte_apagada_o_link_vai_junto(self):
        src = self._video("Blade.Runner.2049.2017.1080p.mkv")
        self.p.cmd_postprocess(["Blade.Runner.2049.2017.1080p", src])
        dst = os.path.join(self.p.MOVIES, "Blade.Runner.2049.2017.1080p.mkv")
        os.remove(src)                                  # o download some
        rc, saida = self._links("--apply")
        self.assertEqual(rc, 0)
        self.assertFalse(os.path.exists(dst), "o hardlink orfao ficou")
        self.assertNotIn(dst, self._razao())
        self.assertIn("removidos 1 link(s)", saida)

    def test_sem_apply_apenas_lista(self):
        src = self._video("Blade.Runner.2049.2017.1080p.mkv")
        self.p.cmd_postprocess(["Blade.Runner.2049.2017.1080p", src])
        dst = os.path.join(self.p.MOVIES, "Blade.Runner.2049.2017.1080p.mkv")
        os.remove(src)
        rc, saida = self._links()
        self.assertEqual(rc, 0)
        self.assertTrue(os.path.exists(dst), "removeu sem --apply")
        self.assertIn("nada foi removido", saida)
        self.assertIn(dst, saida)

    def test_arquivo_de_fora_nunca_e_tocado(self):
        """O ponto do desenho: st_nlink == 1 nao e criterio de orfandade.

        Este arquivo tem nlink 1 e fonte nenhuma — exatamente o perfil da midia
        que a pessoa copiou direto para a biblioteca.
        """
        alheio = os.path.join(self.p.MOVIES, "Filme Que Eu Copiei Na Mao.mkv")
        with open(alheio, "wb") as f:
            f.write(b"\0" * 1024)
        self.assertEqual(os.stat(alheio).st_nlink, 1)
        src = self._video("Blade.Runner.2049.2017.1080p.mkv")
        self.p.cmd_postprocess(["Blade.Runner.2049.2017.1080p", src])
        os.remove(src)
        self._links("--apply")
        self.assertTrue(os.path.exists(alheio),
                        "apagou midia que o plexden nunca linkou")

    def test_serie_poda_temporada_vazia(self):
        src = self._video("The.Office.S04E01.1080p.WEB.mkv")
        self.p.cmd_postprocess(["The.Office.S04E01.1080p.WEB", src])
        temporada = os.path.join(self.p.SERIES, "The Office", "Season 04")
        self.assertTrue(os.path.isdir(temporada))
        os.remove(src)
        self._links("--apply")
        self.assertFalse(os.path.exists(temporada),
                         "'Season 04' vazia sobrou na biblioteca")
        self.assertFalse(os.path.exists(os.path.join(self.p.SERIES, "The Office")))

    def test_poda_para_na_raiz_da_biblioteca(self):
        """movies/ e series/ sao do provision.sh: podar ate elas quebra a stack."""
        src = self._video("Blade.Runner.2049.2017.1080p.mkv")
        self.p.cmd_postprocess(["Blade.Runner.2049.2017.1080p", src])
        os.remove(src)
        self._links("--apply")
        self.assertTrue(os.path.isdir(self.p.MOVIES), "podou o proprio movies/")

    def test_destino_sumido_so_limpa_a_razao(self):
        """Acordado: se o destino nao esta mais onde foi registrado, nao cacamos."""
        src = self._video("Blade.Runner.2049.2017.1080p.mkv")
        self.p.cmd_postprocess(["Blade.Runner.2049.2017.1080p", src])
        dst = os.path.join(self.p.MOVIES, "Blade.Runner.2049.2017.1080p.mkv")
        renomeado = os.path.join(self.p.MOVIES, "Blade Runner 2049.mkv")
        os.rename(dst, renomeado)                       # renomeado na biblioteca
        os.remove(src)
        rc, saida = self._links("--apply")
        self.assertEqual(rc, 0)
        self.assertTrue(os.path.exists(renomeado), "apagou o arquivo renomeado")
        self.assertEqual(self._razao(), {})
        self.assertIn("1 entrada(s) obsoleta(s)", saida)

    def test_destino_fora_da_biblioteca_e_ignorado(self):
        """Razao adulterada ou PLEXDEN_HOME trocado: nao se remove nada de fora."""
        de_fora = os.path.join(self.home, "nao-e-biblioteca.mkv")
        with open(de_fora, "wb") as f:
            f.write(b"\0")
        self.p._links_save({de_fora: {"src": "/fonte/que/nao/existe.mkv",
                                      "modo": "link"}})
        rc, saida = self._links("--apply")
        self.assertEqual(rc, 0)
        self.assertTrue(os.path.exists(de_fora), "removeu arquivo fora da biblioteca")
        self.assertIn("IGNORADO", saida)

    def test_razao_corrompida_nao_derruba(self):
        """Uma razao ilegivel vira 'nada registrado', nao um traceback."""
        os.makedirs(os.path.dirname(self.p.LINKS_DB), exist_ok=True)
        with open(self.p.LINKS_DB, "w") as f:
            f.write("{isto nao e json")
        rc, saida = self._links("--apply")
        self.assertEqual(rc, 0)
        self.assertIn("vazia", saida)

    def test_razao_sobrevive_a_dois_postprocess(self):
        """Um torrent nao pode apagar o registro do anterior."""
        a = self._video("Blade.Runner.2049.2017.1080p.mkv")
        self.p.cmd_postprocess(["Blade.Runner.2049.2017.1080p", a])
        b = self._video("Arrival.2016.1080p.mkv")
        self.p.cmd_postprocess(["Arrival.2016.1080p", b])
        self.assertEqual(len(self._razao()), 2)

    def test_legenda_acompanha_o_filme(self):
        src = self._video("Blade.Runner.2049.2017.1080p.mkv")
        leg = os.path.join(self.completo, "Blade.Runner.2049.2017.1080p.srt")
        with open(leg, "w") as f:
            f.write("1\n")
        self.p.cmd_postprocess(["Blade.Runner.2049.2017.1080p", src])
        dst_leg = os.path.join(self.p.MOVIES, "Blade.Runner.2049.2017.1080p.srt")
        self.assertIn(dst_leg, self._razao())
        os.remove(src)
        os.remove(leg)
        self._links("--apply")
        self.assertFalse(os.path.exists(dst_leg), "a legenda orfa ficou")

    def test_razao_ilegivel_nao_derruba_o_postprocess(self):
        """O postprocess roda dentro do AutoRun do qB: traceback ali some.

        Se a razao nao puder ser gravada, a midia ainda tem de ser organizada —
        perde-se a procedencia, nao o trabalho.
        """
        os.makedirs(os.path.dirname(self.p.LINKS_DB), exist_ok=True)
        os.mkdir(self.p.LINKS_DB)                   # diretorio no lugar do arquivo
        src = self._video("Blade.Runner.2049.2017.1080p.mkv")
        rc = self.p.cmd_postprocess(["Blade.Runner.2049.2017.1080p", src])
        self.assertEqual(rc, 0)
        self.assertTrue(
            os.path.exists(os.path.join(
                self.p.MOVIES, "Blade.Runner.2049.2017.1080p.mkv")),
            "a midia deixou de ser linkada por causa da razao")

    # -- varredura por inode (--scan) ---------------------------------------
    def _linka_na_mao(self, nome, destino_rel):
        """Simula o acervo anterior a razao: hardlink feito fora do plexden."""
        src = self._video(nome)
        dst = os.path.join(self.home, destino_rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        os.link(src, dst)
        return src, dst

    def test_scan_adota_quem_tem_fonte_viva(self):
        src, dst = self._linka_na_mao("Heat.1995.1080p.mkv", "movies/Heat.1995.1080p.mkv")
        rc, saida = self._links("--scan", "--apply")
        self.assertEqual(rc, 0)
        self.assertEqual(self._razao()[dst]["src"], src)
        self.assertIn("1 par(es) gravado(s)", saida)

    def test_scan_sem_apply_nao_grava(self):
        self._linka_na_mao("Heat.1995.1080p.mkv", "movies/Heat.1995.1080p.mkv")
        rc, saida = self._links("--scan")
        self.assertEqual(rc, 0)
        self.assertFalse(os.path.exists(self.p.LINKS_DB), "gravou sem --apply")
        self.assertIn("grava na razao", saida)

    def test_scan_ignora_quem_nao_tem_fonte(self):
        """O caso dos 47: nlink 1, procedencia desconhecida, fica de fora."""
        alheio = os.path.join(self.p.MOVIES, "Copiado Na Mao.mkv")
        with open(alheio, "wb") as f:
            f.write(b"\0" * 1024)
        rc, saida = self._links("--scan", "--apply")
        self.assertEqual(rc, 0)
        self.assertIn("sem fonte identificavel:            1", saida)
        self.assertIn(alheio, saida)                    # listado, nao adotado
        self.assertTrue(os.path.exists(alheio))
        self.assertFalse(os.path.exists(self.p.LINKS_DB),
                         "adotou arquivo de procedencia desconhecida")

    def test_scan_nunca_remove_nada(self):
        """Mesmo com --apply: a varredura adota, quem remove e o outro modo."""
        src, dst = self._linka_na_mao("Heat.1995.1080p.mkv", "movies/Heat.1995.1080p.mkv")
        os.remove(src)                                  # fonte ja apagada
        rc, saida = self._links("--scan", "--apply")
        self.assertEqual(rc, 0)
        self.assertTrue(os.path.exists(dst), "a varredura removeu um arquivo")
        self.assertIn("nada novo a adotar", saida)

    def test_adotado_passa_a_ser_reconciliado(self):
        """O ponto do --scan: trazer o acervo antigo para dentro do 'links'."""
        src, dst = self._linka_na_mao("Heat.1995.1080p.mkv", "movies/Heat.1995.1080p.mkv")
        self._links("--scan", "--apply")
        os.remove(src)
        rc, saida = self._links("--apply")
        self.assertEqual(rc, 0)
        self.assertFalse(os.path.exists(dst), "o adotado nao foi reconciliado")
        self.assertIn("removidos 1 link(s)", saida)

    def test_scan_e_idempotente(self):
        self._linka_na_mao("Heat.1995.1080p.mkv", "movies/Heat.1995.1080p.mkv")
        self._links("--scan", "--apply")
        rc, saida = self._links("--scan", "--apply")
        self.assertEqual(rc, 0)
        self.assertEqual(len(self._razao()), 1)
        self.assertIn("ja na razao:", saida)
        self.assertIn("nada novo a adotar", saida)

    def test_scan_aponta_baixado_fora_da_biblioteca(self):
        """Video grande em torrents/ sem link: o postprocess nao rodou."""
        solto = self._video("Sicario.2015.1080p.mkv")
        rc, saida = self._links("--scan")
        self.assertEqual(rc, 0)
        self.assertIn("baixado sem link na biblioteca:", saida)
        self.assertIn(solto, saida)

    def test_scan_nao_reclama_de_lixo_do_torrent(self):
        """.txt, capa e amostra pequena nao sao 'faltando na biblioteca'."""
        with open(os.path.join(self.completo, "LEIA.txt"), "w") as f:
            f.write("x")
        with open(os.path.join(self.completo, "amostra.mkv"), "wb") as f:
            f.write(b"\0" * 1024)
        rc, saida = self._links("--scan")
        self.assertEqual(rc, 0)
        self.assertIn("baixado sem link na biblioteca:     0", saida)

if __name__ == "__main__":
    unittest.main(verbosity=2)
