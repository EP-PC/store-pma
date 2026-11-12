"""Teste de carga do store pelo gateway (Locust).

Dois perfis, como o uso real da loja:
- Visitante (sem login): so navega na vitrine (GET /products) -> gateway -> product -> RDS.
- Cliente (role USER): cadastra uma conta de teste, faz login (cookie JWT) e alterna entre vitrine
  e GET /auth/me. Toda requisicao autenticada passa pelo gateway, que valida o cookie chamando
  o auth (/auth/solve), e o auth consulta o account: e o caminho mais caro do sistema.

Nao usa a conta admin (nenhuma senha real aqui). As contas de teste tem o e-mail
loadtest.<uuid>@teste.local e sao apagadas no fim (ver load-test/README.md).

Uso:  locust -f load-test/locustfile.py --host http://<load-balancer>:8080
"""
import uuid

from locust import HttpUser, between, task


class Visitante(HttpUser):
    weight = 3
    wait_time = between(0.5, 1.5)

    @task
    def vitrine(self):
        self.client.get("/products", name="GET /products (anonimo)")


class Cliente(HttpUser):
    weight = 1
    wait_time = between(0.5, 1.5)

    def on_start(self):
        email = f"loadtest.{uuid.uuid4().hex[:12]}@teste.local"
        senha = "LoadTest123!"
        self.client.post(
            "/auth/register",
            json={"name": "Load Test", "email": email, "password": senha},
            name="POST /auth/register",
        )
        # o cookie __store_jwt_token fica na sessao do cliente e vai nas proximas requisicoes
        self.client.post(
            "/auth/login",
            json={"email": email, "password": senha},
            name="POST /auth/login",
        )

    @task(3)
    def vitrine(self):
        self.client.get("/products", name="GET /products (logado)")

    @task(2)
    def perfil(self):
        self.client.get("/auth/me", name="GET /auth/me")
