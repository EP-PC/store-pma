# Teste de carga, HPA e gargalos

Exigência do projeto ([Load Testing](https://insper.github.io/platform/2026.2/exercises/project/load-testing/)):
rodar um teste de carga na aplicação e gravar um vídeo mostrando **o teste rodando** e **o HPA funcionando**.

| Arquivo | O que é |
|---|---|
| `hpa-gateway.yaml` | HPA do gateway: CPU 50% do request, 1 a 6 réplicas (equivale ao `kubectl autoscale` da página) |
| `locustfile.py` | Carga realista: visitantes (`GET /products`) e clientes logados (`/products` + `/auth/me`, que passa pelo `/auth/solve`) |
| `requirements.txt` | Locust fixado (`locust==2.46.7`) |

Pré-requisitos: ambiente no ar (`aws/up.ps1`, que já instala o **metrics-server** como add-on do EKS) e `kubectl`
no contexto `eks-store`.

## Como rodar

```powershell
python -m venv .venv-locust                 # fora do Git (ou em outra pasta)
.\.venv-locust\Scripts\pip install -r load-test\requirements.txt
kubectl --context eks-store apply -f load-test\hpa-gateway.yaml

# URL do gateway
kubectl --context eks-store get svc gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Com interface web (http://localhost:8089): bom para o vídeo
.\.venv-locust\Scripts\locust -f load-test\locustfile.py --host http://<load-balancer>:8080

# Sem interface (o --processes não funciona no Windows: 1 master + N workers)
locust -f load-test\locustfile.py --worker            # em 4 terminais
locust -f load-test\locustfile.py --master --expect-workers 4 --host http://<lb>:8080 --headless -u 800 -r 20 -t 3m --csv resultado
```

Alternativa da página do professor (gerador dentro do cluster, sem a latência da internet):

```bash
kubectl run -i --tty load-generator --rm --image=busybox:1.28 --restart=Never -- /bin/sh -c "while sleep 0.01; do wget -q -O- http://gateway:8080/health-check; done"
```

Depois do teste: apagar as contas criadas pelo Locust (e-mail `loadtest.*@teste.local`) com um pod `postgres:17`
temporário e `psql` no RDS (`DELETE FROM accounts.accounts WHERE email LIKE 'loadtest.%@teste.local'`).

## Roteiro do vídeo

Quatro janelas lado a lado:

1. `kubectl --context eks-store get hpa gateway -w` (o HPA: CPU x meta de 50% e número de réplicas)
2. `kubectl --context eks-store get pods -l app=gateway -w` (pods novos do gateway nascendo)
3. `kubectl --context eks-store top pods` repetido (CPU por pod)
4. Locust web (`http://localhost:8089`): 800 usuários, taxa 20/s, abas **Statistics** e **Charts**

Narração sugerida: começa com 1 gateway → a carga sobe → CPU do gateway passa de 50% → o HPA cria réplicas (2, depois 4)
→ a latência p95 cai → para a carga → depois de ~5 min o HPA volta para 1 réplica.

## Resultados (2026-11-12, EKS us-east-2, 2 nós t3.medium, RDS db.t4g.micro)

Gerador: Locust no PC do Pedro (Brasil) → Load Balancer em Ohio. A rede sozinha custa ~160–230 ms por ida e volta,
então o **p50 (~170 ms) é quase todo rede**; o que a carga afeta é a **cauda (p95/p99)**.

| Cenário | Usuários | req/s | Falhas | p50 | p95 | p99 | CPU máx. do gateway |
|---|---|---|---|---|---|---|---|
| Referência, sem HPA | 100 | 77,5 | 0 | 170 ms | 260 ms | 440 ms | 470m* |
| Estresse, sem HPA | 300 | 235 | 0 | 170 ms | 220 ms | 330 ms | 296m |
| **Estresse, sem HPA** | **800** | **566** | **0** | **180 ms** | **770 ms** | **1.400 ms** | **493m / 500m (teto)** |
| **Estresse, com HPA** | **800** | **597** | **0** | **170 ms** | **320 ms** | **910 ms** | dividida em 4 pods |

\* aquecimento da JVM (JIT) nos primeiros minutos depois do deploy; com a JVM quente, 300 usuários gastaram menos CPU.

HPA no teste com 800 usuários: **1 → 2 → 4 réplicas em ~40 s** (eventos `SuccessfulRescale`), estável em 4.

## Gargalos encontrados

1. **Gateway (CPU)**: é a porta de toda requisição e, nas autenticadas, ainda chama o `/auth/solve`. Com 800 usuários bateu
   no limite de CPU do `k8s.yaml` (500m), o Kubernetes estrangulou a CPU (throttling) e as requisições fizeram fila:
   p95 3,5× e p99 4× maiores, sem erros. **Correção: HPA** → p95 −58% (770 → 320 ms), p99 −35% (1.400 → 910 ms).
2. **Aquecimento da JVM**: o primeiro minuto depois de um deploy/escala consome muito mais CPU (JIT). Pods novos do HPA
   demoram ~40 s para atender (o `readinessProbe` evita mandar tráfego antes da hora).
3. **Deploy sem readinessProbe** (achado no CI/CD): ~40 s de HTTP 503 a cada deploy. Corrigido com `readinessProbe`
   tcpSocket 8080 nos 4 serviços (ver `aws/evidencias/2026-11-12-cicd.md`); sobra no máximo 1 requisição cortada no
   término do pod antigo (melhoria seguinte: `preStop` + graceful shutdown).
4. **Capacidade do cluster**: 2 nós t3.medium (4 vCPU) e sem cluster autoscaler: o HPA foi limitado a 6 réplicas do
   gateway; acima disso precisaria de mais nós (Cluster Autoscaler/Karpenter).
5. Folga observada nos demais com 800 usuários: product ~310m, account ~300m, auth ~110m (de 500m): os próximos a
   saturar seriam product e account (ambos consultam o RDS).
