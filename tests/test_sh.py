#!/usr/bin/env python3
"""Comportamento do sh() quando o binario nao existe.

Existe por causa de uma regressao concreta: o _qb_legal_flag() passou a chamar
'qbittorrent-nox --help' para decidir se a flag do aviso legal e suportada. Numa
maquina onde o qBittorrent nao esta instalado, isso levantava FileNotFoundError
e derrubava 'plexden services start' com traceback — onde antes a stack apenas
reportava "qBittorrent FALHOU".

Nao e cenario exotico: acontece em toda instalacao interrompida no meio, que e
justamente quando a pessoa mais precisa de uma mensagem legivel.
"""
import importlib.machinery
import importlib.util
import os
import unittest

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _carrega_plexden():
    loader = importlib.machinery.SourceFileLoader(
        "plexden_sh", os.path.join(RAIZ, "plexden"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class TestSh(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plexden = _carrega_plexden()

    def test_binario_ausente_vira_127(self):
        """127 e a convencao do shell para 'command not found'."""
        r = self.plexden.sh(["nao-existe-esse-binario-plexden"])
        self.assertEqual(r.returncode, 127)

    def test_binario_ausente_nao_levanta(self):
        """O ponto todo: nada de traceback subindo ate o usuario."""
        try:
            self.plexden.sh(["nao-existe-esse-binario-plexden", "--help"])
        except Exception as e:                      # noqa: BLE001
            self.fail(f"sh() deixou escapar {type(e).__name__}: {e}")

    def test_qb_legal_flag_sem_qbittorrent(self):
        """Sem o binario, a resposta certa e 'sem flag' — nao uma excecao."""
        self.assertEqual(self.plexden._qb_legal_flag(), "")

    def test_pgrep_x_sobrevive_a_pgrep_ausente(self):
        """pgrep_x alimenta o status, que qualquer um roda sem root."""
        r = self.plexden.sh(["pgrep", "-x", "nao-existe-esse-processo"])
        self.assertIn(r.returncode, (1, 127))       # 1 = nao achou, 127 = sem pgrep

    def test_comando_valido_continua_funcionando(self):
        """A guarda nao pode mascarar execucao normal."""
        r = self.plexden.sh(["echo", "plexden"])
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), "plexden")


if __name__ == "__main__":
    unittest.main(verbosity=2)
