# store-pma

Aplicação web de compra e venda de produtos, feita de microserviços, para a disciplina
**Platforms, Microservices, DevOps and APIs** (Insper, 2026.2).

Este é o repositório **root**: ele incorpora cada microserviço como **submódulo git** em `api/`
e tem o `compose.yaml` que sobe tudo junto.

## Arquitetura

```
internet → gateway (:8080) → auth | account | product | order | exchange → db (PostgreSQL)
```

O **gateway** é o único ponto de entrada (só ele publica porta). Ele valida o JWT
(cookie `__store_jwt_token`) no auth e repassa a identidade aos serviços nos headers
`id-account` e `id-role` (`USER`/`ADMIN`).

## Serviços

| Serviço | Path | Repositório | Responsável |
|---|---|---|---|
| Product (contrato) | `api/product` | [EP-PC/Product](https://github.com/EP-PC/Product) | EP-PC |
| Product (implementação) | `api/product-service` | [EP-PC/Product-service](https://github.com/EP-PC/Product-service) | EP-PC |
| Account (contrato) | `api/account` | [EP-PC/Account](https://github.com/EP-PC/Account) | EP-PC |
| Account (implementação) | `api/account-service` | [EP-PC/Account-service](https://github.com/EP-PC/Account-service) | EP-PC |
| Auth | `api/auth-service` | [EP-PC/Auth-service](https://github.com/EP-PC/Auth-service) | EP-PC |
| Gateway | `api/gateway-service` | [EP-PC/Gateway](https://github.com/EP-PC/Gateway) | EP-PC |
| Order | `api/order-service` | _pendente_ | EP-PC |
| Exchange | `api/exchange-service` | _pendente_ | EP-PC |

## Pré-requisitos

- Java 25 e Maven 3.9+
- Docker (com Docker Compose)
- Acesso de leitura à organização `EP-PC` no GitHub (os repositórios são privados)

## Como clonar

```bash
git clone --recurse-submodules https://github.com/EP-PC/store-pma.git
```

Se já clonou sem `--recurse-submodules`:

```bash
git submodule update --init
```

## Como buildar e subir

Tudo é feito dentro de `api/`.

1. Crie o `.env` a partir do exemplo e preencha (chave JWT e seed do admin; o arquivo
   explica como gerar cada valor). O `.env` **não** é versionado.

   ```bash
   cd api
   cp .env.example .env
   ```

2. Gere os jars (os Dockerfiles copiam `target/*.jar`). O script faz `mvn install` nos
   contratos (`product`, `account`) e depois `mvn package` nos services:

   ```bash
   ./build.sh        # Linux/macOS/Git Bash
   .\build.ps1       # Windows PowerShell
   ```

3. Suba os containers:

   ```bash
   docker compose up --build -d
   docker compose ps
   ```

   A API fica em `http://localhost:8080` (ex.: `GET http://localhost:8080/products`).

4. Para derrubar (**sem** `-v`, para manter o volume do banco):

   ```bash
   docker compose down
   ```

> Os repositórios dos serviços também têm compose próprios com `name: store` e a porta 8080.
> Deixe só um de pé por vez.

## Como atualizar os submódulos

Quando um serviço receber commits novos (já com push no repositório dele):

```bash
git submodule update --remote            # puxa o último commit da main de cada submódulo
git add api/<servico>                    # registra o novo ponteiro
git commit -m "chore: atualiza <servico>"
```
