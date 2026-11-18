# Exchange: contrato combinado com o Order

Este documento é para quem vai implementar o **Exchange**. O Order já está pronto e testado contra
o contrato abaixo (inclusive com um Exchange falso, de ponta a ponta). Seguindo este contrato,
o Exchange se integra **sem mudar nada no Order nem no gateway**.

Enunciado: <https://insper.github.io/platform/2026.2/exercises/exchange/>

## Resumo

| Item | Decisão |
|---|---|
| Linguagem | **Python** (obrigatório pelo enunciado; FastAPI sugerido) |
| Nome do serviço | **`exchange`** (no compose, no Service e no Deployment do Kubernetes) |
| Porta | **8080** (ex.: `uvicorn main:app --host 0.0.0.0 --port 8080`) |
| Endpoint | **`GET /exchange/{from}/{to}`** (singular) |
| Health-check | **`GET /exchange/health-check`** → 200, **sem** exigir `id-account` (rota aberta no gateway) |
| Autenticação | header **`id-account`**; sem ele → **401** |
| Resposta 200 | `{"sell": número, "buy": número, "date": "YYYY-MM-DD HH:MM:SS", "id-account": "..."}` |
| Moeda não suportada | **404** (o Order também aceita 400 ou 422) |
| API externa fora do ar | **503** (ou 502) |
| Banco | nenhum |
| Repo sugerido | `EP-PC/Exchange-service` → submódulo `api/exchange-service` no store-pma |

## Endpoint: `GET /exchange/{from}/{to}`

O enunciado escreve `GET /exchanges/{from}/{to}` no título, mas o próprio exemplo dele é
`GET /exchange/USD/EUR`. Escolhemos o **singular** porque o gateway já roteia `/exchange/**`
para `http://exchange:8080` (`api/gateway-service/src/main/resources/application.yaml`). Com o
plural, a rota do gateway (repo do Pedro) teria que mudar.

- `from` e `to`: códigos ISO 4217 de 3 letras (`USD`, `BRL`, `EUR`...). Aceite maiúsculas e
  minúsculas; o Order sempre manda em maiúsculas.
- O Order sempre chama com `from = USD` (o banco guarda tudo em dólar), por exemplo
  `GET http://exchange:8080/exchange/USD/BRL`.
- A cotação é o valor de **1 unidade de `from` em `to`**: `GET /exchange/USD/BRL` com
  `sell = 5.40` significa 1 USD = 5,40 BRL.

## Health-check: `GET /exchange/health-check`

Como nos outros serviços, o gateway deixa `GET /exchange/health-check` **aberto** (sem login;
`RouterValidator.java` do gateway). Por isso a requisição chega **sem** `id-account`: o
health-check responde 200 sem exigir o header. Ele não conflita com `/exchange/{from}/{to}`
(tem um segmento a menos).

## Autenticação: header `id-account`

O Exchange **não** valida JWT. Quem chega pelo gateway já foi autenticado, e o gateway injeta o
header `id-account` (UUID da conta). Quando o Order chama o Exchange (rede interna, sem passar
pelo gateway), ele **repassa o mesmo header** do usuário.

- Sem `id-account` (ou vazio) → **401**.
- O campo `"id-account"` da resposta é o valor desse header (exigência do enunciado).
- No FastAPI, `Header()` converte `_` em `-`: `id_account: str | None = Header(default=None)`
  lê o header `id-account`.

## Resposta 200

Igual ao exemplo do enunciado:

```json
{
    "sell": 5.40,
    "buy": 5.38,
    "date": "2026-11-18 14:23:42",
    "id-account": "0195ae95-5be7-7dd3-b35d-7a7d87c404fb"
}
```

- `sell` e `buy` são **números** (não strings) e maiores que zero.
- `sell` = taxa de **venda** (em APIs como a AwesomeAPI, é o `ask`); `buy` = taxa de **compra**
  (`bid`). Na AwesomeAPI, `GET https://economia.awesomeapi.com.br/json/last/USD-BRL` devolve
  `bid` e `ask` como strings: converta para número.
- **O Order usa `sell`**: para pagar em reais um valor em dólar, o cliente precisa comprar
  dólar, e a casa de câmbio vende. Não troque o significado dos campos.
- `date`: data/hora da cotação no formato `YYYY-MM-DD HH:MM:SS` (o Order não usa, mas o
  enunciado mostra assim).

## Erros

| Situação | Status que o Exchange devolve | O que o Order faz |
|---|---|---|
| Sem `id-account` | 401 | (não acontece: o Order sempre repassa) |
| Moeda inexistente/não suportada (ex.: `XYZ`) | **404** (400 ou 422 também servem) | responde **422** ao cliente |
| API externa fora do ar, erro ou resposta inválida | **503** (ou 502) | responde **503** |
| Demorou mais de 5 s | — | o Order desiste (timeout) e responde **503** |

Dica: o Order espera no máximo **2 s para conectar e 5 s pela resposta**. Defina um timeout menor
na chamada à API externa (ex.: `requests.get(url, timeout=3)`) e, se quiser, guarde a cotação
em memória por alguns segundos para não estourar o limite de requisições da API externa.

## Como o Order usa o Exchange (para referência)

- Só no `GET /orders/{id}?currency=XXX` com `XXX` diferente de `USD`. Sem `currency` ou com
  `USD`, o Order nem chama o Exchange.
- Moeda que não tem 3 letras (ex.: `REAL`) → o Order responde 422 sem chamar o Exchange.
- Converte o total de cada item (`total × sell`, 2 casas, arredondamento `HALF_UP`) e soma os
  itens convertidos para o total do pedido.
- Pedido de outro usuário continua 404, sem chamar o Exchange.
- Código do lado do Order: `api/order-service/src/main/java/store/exchange/ExchangeClient.java`
  e o método `convert` de `OrderService.java`.

## Ponto de partida (sugestão, FastAPI)

```python
from datetime import datetime
from fastapi import FastAPI, Header, HTTPException

app = FastAPI()

@app.get("/exchange/health-check")
def health_check():
    return {}  # 200, sem exigir id-account (rota aberta no gateway)

@app.get("/exchange/{source}/{target}")
def exchange(source: str, target: str, id_account: str | None = Header(default=None)):
    if not id_account:
        raise HTTPException(status_code=401, detail="Not authenticated")
    sell, buy = buscar_cotacao(source.upper(), target.upper())  # API externa; 404 se não suportar
    return {
        "sell": sell,
        "buy": buy,
        "date": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "id-account": id_account,
    }
```

`Dockerfile` (sem `target/*.jar`, diferente dos serviços Java):

```dockerfile
FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
```

Chave da API externa (se a escolhida exigir): **variável de ambiente**, nunca no Git. Local: no
`api/.env` (e o nome, sem valor, no `api/.env.example`); Kubernetes: um Secret.

## Integração no store-pma (checklist)

1. Repo do serviço com push → `git submodule add -b main https://github.com/EP-PC/Exchange-service.git api/exchange-service`.
2. `api/compose.yaml`: descomentar o bloco `exchange` (`build: ./exchange-service`) e passar a
   chave da API externa por variável de ambiente, se houver. O order já chama `http://exchange:8080`.
3. Gateway: **nada a mudar** (a rota `/exchange/**` já existe e exige login, como o enunciado pede).
4. `api/build.sh` / `api/build.ps1`: o Exchange **não entra** (não usa Maven).
5. `k8s/k8s.yaml` no repo do serviço: Deployment + Service `ClusterIP` 8080 com o nome
   `exchange`, `readinessProbe` `tcpSocket` 8080 e requests/limits (modelo:
   `api/product-service/k8s/k8s.yaml`, sem as variáveis do banco e sem `JAVA_TOOL_OPTIONS`).
6. `Jenkinsfile` sem Maven: só `Build & Push Image` e `Deploy to EKS` (copie do
   `api/product-service/Jenkinsfile`, trocando `SERVICE` e `NAME`).
7. `aws/up.ps1`: incluir `'exchange-service'` na lista de manifestos e `'exchange'` no rollout.
8. `README.md` do root: atualizar a linha do Exchange na tabela de serviços.

## Como testar

```bash
# direto no serviço (sem gateway): o header é obrigatório
curl -i -H 'id-account: 0195ae95-5be7-7dd3-b35d-7a7d87c404fb' http://localhost:8080/exchange/USD/BRL   # 200
curl -i http://localhost:8080/exchange/USD/BRL                                                         # 401
curl -i -H 'id-account: 0195ae95-5be7-7dd3-b35d-7a7d87c404fb' http://localhost:8080/exchange/USD/XYZ   # 404
curl -i http://localhost:8080/exchange/health-check                                                    # 200
```

Pelo compose do store-pma:

- `GET http://localhost:8080/exchange/health-check` sem login → 200.

Logado (com o cookie do `POST /auth/login`):

- `GET http://localhost:8080/exchange/USD/BRL` → 200 com o `id-account` do usuário logado.
- `GET http://localhost:8080/orders/{id}?currency=BRL` → pedido com os totais em reais.
- `GET http://localhost:8080/orders/{id}?currency=XYZ` → 422.
