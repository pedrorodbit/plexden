#!/usr/bin/env python3
"""Formas de resposta do login da Web API do qBittorrent.

Existe por causa de um bug real: ate o qB 5.1 o /auth/login respondia 200 com o
corpo "Ok."; o 5.2 passou a responder 204 sem corpo nenhum, entregando so o
cookie de sessao. O plexden exigia o literal "Ok." e recusava um login que
tinha funcionado — quem estivesse numa distro com qB 5.2 nao usava 'plexden qb'.

O e2e cobre as duas formas hoje, mas por acaso: o Fedora empacota o 5.2 e as
outras tres imagens empacotam versoes anteriores. Se essa coincidencia acabar, a
cobertura some **sem nada ficar vermelho** — os testes passariam igual, porque o
codigo trata as duas formas. Um teste que passa antes e depois de perder a
cobertura nao e uma guarda.

Aqui as respostas sao simuladas, entao a cobertura nao depende de o Fedora
continuar empacotando o que empacota. So biblioteca padrao, como o resto.
"""
import importlib.machinery
import importlib.util
import os
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Cenario corrente, lido pelo handler. Trocado por cada teste.
CENARIO = "ok_200"


class FakeQB(BaseHTTPRequestHandler):
    """Um qBittorrent de mentira que so sabe responder ao /auth/login."""

    def do_POST(self):
        if self.path != "/api/v2/auth/login":
            self.send_error(404)
            return
        self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))

        if CENARIO == "ok_200":            # qB <= 5.1
            corpo = b"Ok."
            self.send_response(200)
            self.send_header("Set-Cookie", "SID=abc123; path=/; HttpOnly")
            self.send_header("Content-Length", str(len(corpo)))
            self.end_headers()
            self.wfile.write(corpo)

        elif CENARIO == "ok_204":          # qB >= 5.2: so o cookie
            self.send_response(204)
            self.send_header("Set-Cookie",
                             "QBT_SID_8081=abc123; path=/; HttpOnly")
            self.end_headers()

        elif CENARIO == "senha_errada":    # 200, mas sem cookie
            corpo = b"Fails."
            self.send_response(200)
            self.send_header("Content-Length", str(len(corpo)))
            self.end_headers()
            self.wfile.write(corpo)

        elif CENARIO == "banido":          # qB baniu o IP apos tentativas
            self.send_error(403, "Forbidden")

        elif CENARIO == "204_sem_cookie":  # 2xx nao basta: tem que vir sessao
            self.send_response(204)
            self.end_headers()

        else:
            self.send_error(500)

    def log_message(self, *args):
        pass                                # silencio no output do teste


def _carrega_plexden(porta, creds):
    """Importa o plexden apontado para o servidor falso.

    QB_URL e' resolvido no nivel do modulo, entao as variaveis de ambiente
    precisam estar no lugar antes do import.
    """
    os.environ["QB_HOST"] = f"http://127.0.0.1:{porta}"
    os.environ["QB_CREDS"] = creds
    caminho = os.path.join(RAIZ, "plexden")     # sem extensao .py
    loader = importlib.machinery.SourceFileLoader("plexden", caminho)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class TestLoginQB(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = ThreadingHTTPServer(("127.0.0.1", 0), FakeQB)
        cls.thread = threading.Thread(target=cls.srv.serve_forever, daemon=True)
        cls.thread.start()

        fd, cls.creds = tempfile.mkstemp(prefix="qbcreds-teste-")
        with os.fdopen(fd, "w") as f:
            f.write("QB_USER=fulano\nQB_PASS=senha-de-teste\n")

        cls.plexden = _carrega_plexden(cls.srv.server_address[1], cls.creds)

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()
        os.unlink(cls.creds)

    def _login(self, cenario):
        global CENARIO
        CENARIO = cenario
        self.plexden.QB().login()

    # ---------------------------------------------------------- sucesso ---
    def test_ok_200_qb_ate_5_1(self):
        """A forma antiga: 200 com o corpo 'Ok.'."""
        self._login("ok_200")

    def test_ok_204_qb_5_2(self):
        """A forma nova: 204 sem corpo, so o cookie. E a regressao de 2026-07:
        exigir o literal 'Ok.' recusava um login que tinha funcionado."""
        self._login("ok_204")

    # ------------------------------------------------------------ falha ---
    def test_senha_errada(self):
        with self.assertRaises(SystemExit):
            self._login("senha_errada")

    def test_ip_banido(self):
        with self.assertRaises(SystemExit):
            self._login("banido")

    def test_2xx_sem_cookie_nao_e_sucesso(self):
        """Guarda de projeto: o criterio e o cookie de sessao, nao '2xx me
        basta'. Se alguem simplificar para 'if status < 300: return', este
        caso pega — um 204 sem sessao nao autentica coisa nenhuma."""
        with self.assertRaises(SystemExit):
            self._login("204_sem_cookie")


if __name__ == "__main__":
    unittest.main(verbosity=2)
