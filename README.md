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
| Order (contrato) | `api/order` | [EP-PC/Order](https://github.com/EP-PC/Order) | EP-PC |
| Order (implementação) | `api/order-service` | [EP-PC/Order-service](https://github.com/EP-PC/Order-service) | EP-PC |
| Exchange | `api/exchange-service` | _pendente_ (contrato combinado com o Order em [EXCHANGE.md](EXCHANGE.md)) | EP-PC |

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
   contratos (`product`, `account`, `order`) e depois `mvn package` nos services:

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

## Observabilidade (order)

Prometheus e Grafana ficam no profile `observability` do `api/compose.yaml` e só sobem quando
pedidos. Hoje coletam as métricas do order (porta de management 8081, só na rede interna);
configuração em `api/observability/`.

```bash
cd api
docker compose --profile observability up --build -d
```

- Grafana: `http://localhost:3000`, painel **Store / Order** (sem login, só leitura).
- Prometheus: `http://localhost:9090`.
- Tráfego de demonstração: `api/observability/traffic.py` (instruções no topo do arquivo).

Para derrubar, use o mesmo profile: `docker compose --profile observability down` (sem `-v`).

## Kubernetes (Minikube)

Os manifestos ficam em cada serviço (`api/<serviço>/k8s/k8s.yaml`) e o banco em `api/postgres/`.
As imagens vêm do Docker Hub (`pedrohmm1/<serviço>`; o order em `enzoperego/order`). Só o `gateway`
é exposto (LoadBalancer 8080).

```bash
minikube start --driver=docker --memory=3072 --cpus=4

# banco (ConfigMap e Secret antes do Deployment)
kubectl apply -f api/postgres/configmap.yaml
kubectl apply -f api/postgres/secrets.yaml
kubectl apply -f api/postgres/deployment.yaml
kubectl apply -f api/postgres/service.yaml

# segredos reais, criados a partir do api/.env (fora do Git)
kubectl create secret generic account-secrets \
  --from-literal=ACCOUNT_ADMIN_EMAIL="..." --from-literal=ACCOUNT_ADMIN_HASH="..."
kubectl create secret generic auth-secrets --from-literal=JWT_SECRET_KEY="..."

# serviços
kubectl apply -f api/account-service/k8s/k8s.yaml
kubectl apply -f api/auth-service/k8s/k8s.yaml
kubectl apply -f api/product-service/k8s/k8s.yaml
kubectl apply -f api/order-service/k8s/k8s.yaml
kubectl apply -f api/gateway-service/k8s/k8s.yaml

kubectl get pods,svc
minikube tunnel    # em outro terminal: expõe o gateway em http://localhost:8080
```

> Logo depois do `minikube start`, o account e o product podem reiniciar algumas vezes
> (`UnknownHostException: postgres`) até o DNS do cluster subir; o Kubernetes se recupera sozinho.
> `minikube stop` libera a memória quando não estiver usando.

## Como atualizar os submódulos

Quando um serviço receber commits novos (já com push no repositório dele):

```bash
git submodule update --remote            # puxa o último commit da main de cada submódulo
git add api/<servico>                    # registra o novo ponteiro
git commit -m "chore: atualiza <servico>"
```
