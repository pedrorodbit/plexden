#!/usr/bin/env python3
"""'plexden uninstall': deteccao das credenciais do Cloudflare Tunnel.

So cobre a parte pura (sem tocar em pacotes, servicos ou no sistema de
arquivos fora de um diretorio temporario): _cf_tunnel_uuid() precisa achar o
par UUID/cert.pem certo, preferindo o volume persistente sobre /etc (que pode
estar desatualizado numa reinstalacao), e nao explodir quando nada esta
configurado. O resto do comando (parar servicos, remover pacotes, revogar o
tunnel na Cloudflare) e destrutivo por natureza e foi validado manualmente
com binarios falsos, nao aqui.
"""
import importlib.machinery
import importlib.util
import os
import tempfile
import unittest

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _carrega_plexden(home):
    os.environ["PLEXDEN_HOME"] = home
    loader = importlib.machinery.SourceFileLoader(
        "plexden_uninstall", os.path.join(RAIZ, "plexden"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class TestCfTunnelUuid(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.persist = self._tmp.name
        self.addCleanup(self._tmp.cleanup)
        self.mod = _carrega_plexden(self.persist)
        # /etc/cloudflared de verdade nao deve vazar para o teste.
        self._etc_tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._etc_tmp.cleanup)
        self.mod.CF_ETC = os.path.join(self._etc_tmp.name, "cloudflared")

    def test_sem_credenciais_devolve_none(self):
        self.assertEqual(self.mod._cf_tunnel_uuid(), (None, None))

    def test_acha_uuid_e_cert_no_volume_persistente(self):
        cfdir = os.path.join(self.persist, "cloudflared")
        os.makedirs(cfdir)
        open(os.path.join(cfdir, "cert.pem"), "w").close()
        uuid = "12345678-1234-1234-1234-123456789012"
        open(os.path.join(cfdir, f"{uuid}.json"), "w").close()

        achado_uuid, achado_cert = self.mod._cf_tunnel_uuid()
        self.assertEqual(achado_uuid, uuid)
        self.assertEqual(achado_cert, os.path.join(cfdir, "cert.pem"))

    def test_prefere_volume_persistente_sobre_etc(self):
        """/etc pode ter sobrado de uma instalacao antiga — o volume manda."""
        cfdir = os.path.join(self.persist, "cloudflared")
        os.makedirs(cfdir)
        open(os.path.join(cfdir, "cert.pem"), "w").close()
        uuid_bom = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        open(os.path.join(cfdir, f"{uuid_bom}.json"), "w").close()

        os.makedirs(self.mod.CF_ETC)
        open(os.path.join(self.mod.CF_ETC, "cert.pem"), "w").close()
        uuid_velho = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        open(os.path.join(self.mod.CF_ETC, f"{uuid_velho}.json"), "w").close()

        achado_uuid, _ = self.mod._cf_tunnel_uuid()
        self.assertEqual(achado_uuid, uuid_bom)

    def test_cai_para_etc_se_persist_nao_tem_cert(self):
        os.makedirs(self.mod.CF_ETC)
        open(os.path.join(self.mod.CF_ETC, "cert.pem"), "w").close()
        uuid = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        open(os.path.join(self.mod.CF_ETC, f"{uuid}.json"), "w").close()

        achado_uuid, achado_cert = self.mod._cf_tunnel_uuid()
        self.assertEqual(achado_uuid, uuid)
        self.assertEqual(achado_cert, os.path.join(self.mod.CF_ETC, "cert.pem"))

    def test_cert_sem_json_nao_conta(self):
        """cert.pem sozinho, sem nenhum <UUID>.json, e' credencial incompleta."""
        cfdir = os.path.join(self.persist, "cloudflared")
        os.makedirs(cfdir)
        open(os.path.join(cfdir, "cert.pem"), "w").close()

        self.assertEqual(self.mod._cf_tunnel_uuid(), (None, None))


if __name__ == "__main__":
    unittest.main(verbosity=2)
