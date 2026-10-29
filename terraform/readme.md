# Infraestrutura do ToggleMaster (Terraform + Terragrunt)

Toda a infraestrutura AWS da Fase 3 é criada por código: rede, cluster EKS, bancos, fila, repositórios de imagem, permissões IAM e os componentes do cluster (ingress, KEDA, metrics-server). Este guia sobe tudo do zero, implanta os 5 microsserviços e testa o funcionamento e a escalabilidade.

## Sumário

1. [Estrutura](#1-estrutura)
2. [Pré-requisitos](#2-pré-requisitos)
3. [Subir a infraestrutura](#3-subir-a-infraestrutura)
4. [Publicar as imagens no ECR](#4-publicar-as-imagens-no-ecr)
5. [Implantar os serviços](#5-implantar-os-serviços)
6. [Testes](#6-testes)
7. [Limitações da conta no plano Free](#7-limitações-da-conta-no-plano-free)
8. [Problemas comuns](#8-problemas-comuns)
9. [Derrubar tudo](#9-derrubar-tudo)

---

## 1. Estrutura

Cada pasta é uma *unit* do Terragrunt, com o próprio state no S3 (`first-terraform-state-25-10-2026/<pasta>/terraform.tfstate`). Uma unit lê os outputs de outra pelo bloco `dependency`, e é isso que define a ordem de criação.

```
terraform/
├── terragrunt.hcl                  # raiz: backend S3 (com lock) e provider AWS, herdados por todas as units
├── vpc/                            # VPC, subnets públicas/privadas, IGW, NAT
├── eks/                            # cluster EKS 1.33 + node group (2x c7i-flex.large)
├── ecr/<servico>-service/          # 5 repositórios: auth-image, flag-image, targeting-image, evaluation-image, analytics-image
├── databases/
│   ├── postgres-security-group/    # libera a 5432 só para os nodes do EKS
│   ├── auth-service-postgres-db/   # RDS PostgreSQL 17 do auth
│   ├── flag-service-postgres-db/   # RDS PostgreSQL 17 do flag
│   ├── targeting-service-postgres-db/
│   ├── redis-security-group/       # libera a 6379 só para os nodes do EKS
│   ├── evaluation-service-redis/   # ElastiCache Redis 7.1 (cache.t3.micro, TLS)
│   ├── analytics-service-dynamo-db/  # tabela DynamoDB ToggleMasterAnalytics
│   └── evaluation-service-dynamo-db/ # ⚠️ apesar do nome, é a fila SQS evaluation-service-sqs (+ DLQ)
├── iam/irsa/                       # IAM Roles dos pods (IRSA): evaluation, analytics e keda-operator
├── utils/                          # Helm: ingress-nginx, metrics-server e KEDA
└── modules/                        # configs compartilhadas (incluídas pelas units)
    ├── rds/root.hcl
    └── ecr/root.hcl
```

Dependências entre as units:

```
vpc ──► eks ──► postgres-security-group ──► RDS (auth, flag, targeting)
 │       ├────► redis-security-group ─────► evaluation-service-redis
 │       ├────────────────────────────────► iam/irsa ◄── SQS + DynamoDB
 │       └────────────────────────────────► utils ◄───── iam/irsa
 └──────────────────────────────────────────► (RDS e Redis usam as subnets privadas)
```

## 2. Pré-requisitos

| Ferramenta | Para quê |
|---|---|
| `terraform` (>= 1.10) | executar os módulos |
| `terragrunt` (testado na v1.1.6) | orquestrar as units |
| `aws` CLI | credenciais e consultas (`aws sts get-caller-identity` precisa funcionar) |
| `kubectl` | operar o cluster |
| `docker` | buildar as imagens |
| `helm` (opcional) | inspecionar os releases instalados pelo Terraform |

Todos os comandos usam a região `us-east-1`.

## 3. Subir a infraestrutura

### 3.1 Backend (bucket S3 do state)

O bucket do state é criado pelo próprio Terragrunt. Na **primeira vez** (bucket ainda não existe):

```bash
cd terraform/vpc
terragrunt init --backend-bootstrap
```

Se o bucket já existe, basta `terragrunt init`.

### 3.2 Opção A: tudo de uma vez

O Terragrunt lê os `dependency` e aplica na ordem certa:

```bash
cd terraform
terragrunt run --all plan
terragrunt run --all apply
```

> Na conta Free o RDS do flag falha por limite de instâncias. Veja a [seção 7](#7-limitações-da-conta-no-plano-free).

### 3.3 Opção B: passo a passo (recomendado na primeira vez)

Rode sempre `terragrunt plan` antes do `apply` para revisar o que vai ser criado.

```bash
cd terraform

(cd vpc  && terragrunt apply)                                   # ~3 min
(cd eks  && terragrunt apply)                                   # ~15 min

(cd ecr  && terragrunt run --all apply)                         # 5 repositórios ECR

(cd databases/postgres-security-group       && terragrunt apply)
(cd databases/auth-service-postgres-db      && terragrunt apply) # ~5 min cada RDS
(cd databases/flag-service-postgres-db      && terragrunt apply)
(cd databases/targeting-service-postgres-db && terragrunt apply)
(cd databases/redis-security-group          && terragrunt apply)
(cd databases/evaluation-service-redis      && terragrunt apply) # ~5 min
(cd databases/analytics-service-dynamo-db   && terragrunt apply)
(cd databases/evaluation-service-dynamo-db  && terragrunt apply) # fila SQS

(cd iam/irsa && terragrunt apply)
(cd utils    && terragrunt apply)                               # ingress-nginx, metrics-server, KEDA
```

### 3.4 Conferir

```bash
aws eks update-kubeconfig --name eks --region us-east-1

kubectl get nodes                          # 2 nodes Ready
kubectl get pods -n ingress-nginx          # 2 controllers Running
kubectl get pods -n keda                   # 3 pods Running
kubectl top nodes                          # metrics-server respondendo
kubectl get ingressclass                   # "nginx"
```

## 4. Publicar as imagens no ECR

O script builda o `Dockerfile` de cada `services/<servico>-service` e envia para `<servico>-image:latest`:

```bash
cd ..                      # raiz do repositório
./scripts/push-ecr.sh                      # os 5 serviços
./scripts/push-ecr.sh auth flag            # ou só alguns

aws ecr list-images --repository-name auth-image --region us-east-1
```

## 5. Implantar os serviços

Todos os comandos abaixo rodam da **raiz do repositório**.

### 5.1 Conferir os endpoints no Secret

O `k8s/03-secrets.yaml` guarda as connection strings (em base64; o valor legível está no comentário acima de cada uma). Os endpoints do RDS e do Redis mudam se a conta mudar, então confira:

```bash
aws rds describe-db-instances --region us-east-1 \
  --query 'DBInstances[].[DBInstanceIdentifier,Endpoint.Address]' --output text

aws elasticache describe-replication-groups --region us-east-1 \
  --replication-group-id evaluation-service-redis \
  --query 'ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address' --output text
```

| Secret | Formato |
|---|---|
| auth | `postgres://auth:<senha>@<endpoint-auth>:5432/auth_db?sslmode=require` |
| flag | `postgres://flag_user:<senha>@<endpoint-flag>:5432/flagdb?sslmode=require` |
| targeting | `postgres://targeting:<senha>@<endpoint-targeting>:5432/targeting_db?sslmode=require` |
| evaluation | `rediss://<endpoint-redis>:6379` (dois "s": o Redis usa TLS) |

A senha dos RDS é a de `password_wo` em `modules/rds/root.hcl`. Para gerar o base64:

```bash
echo -n 'postgres://...' | base64 -w0
```

### 5.2 Namespaces, ConfigMaps e Secrets

```bash
kubectl apply -f k8s/01-namespaces.yaml -f k8s/02-configMap.yaml -f k8s/03-secrets.yaml
```

### 5.3 Criar as tabelas nos RDS

Os bancos são privados, então o `init.sql` de cada serviço roda num pod temporário dentro do cluster. O do auth também cadastra a chave que o evaluation usa (`SERVICE_API_KEY`).

```bash
./scripts/init-db.sh
```

### 5.4 Deploy

```bash
./scripts/deploy.sh
```

Esperado: **9 pods** `1/1 Running` (2 de auth, flag, targeting e evaluation, mais 1 de analytics).

```bash
kubectl get pods -A | grep -E 'auth|flag|targeting|evaluation|analytics'
kubectl get scaledobject -A      # os 5 com READY True
kubectl get ingress -A
```

## 6. Testes

### 6.1 Acesso pelo ingress

Sem Load Balancer (ver [seção 7](#7-limitações-da-conta-no-plano-free)), o acesso é por um túnel até o ingress-nginx. Deixe aberto num terminal:

```bash
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80
```

Em outro terminal:

```bash
export LB=localhost:8080
curl -i http://$LB/nada          # 404 do nginx = ingress respondendo
```

> Com Load Balancer liberado na conta: `export LB=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')`.

### 6.2 Fluxo completo da aplicação

| Caminho | Serviço | Autenticação |
|---|---|---|
| `/admin/keys` | auth | `MASTER_KEY` |
| `/validate` | auth | chave de API |
| `/flags` | flag | chave de API |
| `/rules` | targeting | chave de API |
| `/evaluate` | evaluation | pública |

```bash
# 1. Criar uma chave de API com a MASTER_KEY
export KEY=$(curl -s -X POST http://$LB/admin/keys \
  -H "Content-Type: application/json" -H "Authorization: Bearer admin-secreto-123" \
  -d '{"name":"minha-chave"}' | sed -E 's/.*"key":"([^"]+)".*/\1/')
echo $KEY

# 2. Validar a chave                    -> {"message":"Chave válida"}
curl -s http://$LB/validate -H "Authorization: Bearer $KEY"

# 3. Criar uma flag
curl -s -X POST http://$LB/flags -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"name":"enable-new-dashboard","description":"Novo dashboard","is_enabled":true}'

# 4. Criar uma regra: liberar para 50% dos usuários
curl -s -X POST http://$LB/rules -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"flag_name":"enable-new-dashboard","is_enabled":true,"rules":{"type":"PERCENTAGE","value":50}}'

# 5. Avaliar (o mesmo user_id sempre recebe o mesmo resultado)
for u in user-1 user-2 user-3 user-4; do
  curl -s "http://$LB/evaluate?user_id=$u&flag_name=enable-new-dashboard"; echo
done
```

Cada avaliação vira uma mensagem no SQS, que o analytics grava no DynamoDB. Para conferir o caminho assíncrono:

```bash
kubectl logs -n evaluation -l app=evaluation --tail=20 | grep -iE 'redis|cache|sqs'
#   "Conectado ao Redis com sucesso!", "Cache HIT", "Evento de avaliação enviado para SQS"

kubectl logs -n analytics -l app=analytics --tail=10
#   "Evento ... salvo no DynamoDB"

aws dynamodb scan --table-name ToggleMasterAnalytics --select COUNT --region us-east-1
```

Se o contador do DynamoDB subir, toda a cadeia funcionou: **ingress → evaluation → flag/targeting/Redis → SQS → analytics → DynamoDB**, incluindo as permissões IRSA.

### 6.3 Escalabilidade: evaluation por CPU

Todos os serviços HTTP escalam pelo KEDA quando a CPU passa de 70% do `requests.cpu`. Em dois terminais extras:

```bash
kubectl get hpa -n evaluation -w
kubectl get pods -n evaluation -w
```

Gere 2 minutos de carga de dentro do cluster:

```bash
kubectl run hey -n evaluation --rm -it --restart=Never --image=williamyeh/hey -- \
  -z 2m -c 50 \
  "http://evaluation.evaluation.svc.cluster.local:8004/evaluate?user_id=user-1&flag_name=enable-new-dashboard"
```

Resultado obtido no teste: **2 → 4 → 8 → 10 pods em ~45 s**, distribuídos entre os 2 nodes, com ~111 mil requisições e 100% de respostas 200. Para ver o motivo de cada decisão:

```bash
kubectl describe hpa keda-hpa-evaluation -n evaluation | grep SuccessfulRescale
```

Depois da carga, os pods voltam ao mínimo (2) após alguns minutos.

### 6.4 Escalabilidade: analytics pela fila SQS

O analytics escala pela quantidade de mensagens na fila (1 pod a cada 5, máximo 5). Ele consome rápido demais para a fila acumular sozinha, então o teste segue a ordem **pausar → encher a fila → despausar**:

```bash
# 1. Pausar: o KEDA mantém o analytics em 0 réplicas
kubectl annotate scaledobject analytics -n analytics autoscaling.keda.sh/paused-replicas="0" --overwrite

# 2. Encher a fila com 100 mensagens
QUEUE_URL=$(aws sqs get-queue-url --queue-name evaluation-service-sqs --region us-east-1 --query QueueUrl --output text)
for i in $(seq 1 100); do
  aws sqs send-message --region us-east-1 --queue-url $QUEUE_URL --message-body \
    "{\"user_id\":\"user-$i\",\"flag_name\":\"enable-new-dashboard\",\"result\":true,\"timestamp\":\"$(date -u +%FT%TZ)\"}" >/dev/null
done
aws sqs get-queue-attributes --region us-east-1 --queue-url $QUEUE_URL --attribute-names ApproximateNumberOfMessages

# 3. Despausar e observar (em outro terminal: kubectl get pods -n analytics -w)
kubectl annotate scaledobject analytics -n analytics autoscaling.keda.sh/paused-replicas-
```

Esperado: 0 → 1 → 5 pods, a fila zera e os eventos aparecem no DynamoDB. A fila de erros (`evaluation-service-sqs-dlq`) deve continuar vazia. O KEDA volta para 1 pod depois de ~5 minutos de fila vazia.

> Se rodar o teste 6.3 antes, a fila já recebe um evento por requisição (dezenas de milhares). O analytics vai a 5 pods do mesmo jeito e esvazia a fila em ~2 minutos.

## 7. Limitações da conta no plano Free

A conta AWS no plano Free bloqueia alguns recursos. As adaptações feitas:

| Bloqueio | Erro | Adaptação |
|---|---|---|
| Tipos de instância fora do Free Tier | `The specified instance type is not eligible for Free Tier` (o node group fica "creating" para sempre) | Nodes `c7i-flex.large` (2 vCPU / 4 GB) em vez de `t3.medium` |
| Load Balancers | `This AWS account currently does not support creating load balancers` | Ingress como `NodePort` + `kubectl port-forward`. A config do NLB está comentada em `utils/ingress-nginx-values.yaml` |
| Máximo de 2 instâncias RDS | `InstanceQuotaExceeded` no RDS do flag | **Só para teste:** o banco `flagdb` foi criado dentro da instância do targeting e o Secret do flag aponta para ela (URL original comentada no `03-secrets.yaml`) |
| Quota de 8 vCPUs on-demand | — | `max_size = 3` no node group |

Para criar o `flagdb` na instância do targeting (contorno do limite de RDS):

```bash
kubectl run psql-createdb -n targeting --rm -i --restart=Never --image=postgres:17-alpine -- \
  psql "postgres://targeting:<senha>@<endpoint-targeting>:5432/targeting_db?sslmode=require" \
  -c "CREATE DATABASE flagdb;"
```

**Para a entrega** (3 RDS + Load Balancer), faça upgrade da conta em *Billing → Account plan*, aplique `databases/flag-service-postgres-db`, volte a URL original do flag no `03-secrets.yaml` e troque o bloco `service` do `ingress-nginx-values.yaml` pelo do NLB.

## 8. Problemas comuns

| Sintoma | Causa e solução |
|---|---|
| `Error acquiring the state lock` | Outro `apply` da mesma unit está rodando (às vezes parado esperando o `yes` em outro terminal). Termine ou feche esse processo. Só use `terragrunt force-unlock <ID>` se tiver certeza de que nenhum está rodando |
| Node group "Still creating..." por 20+ min | Instância não permitida na conta. Veja os eventos do Auto Scaling Group: `aws autoscaling describe-scaling-activities --auto-scaling-group-name <asg>` |
| Helm `context deadline exceeded` no utils | Algum recurso não ficou pronto (ex.: Load Balancer bloqueado). Investigue com `kubectl get events -n <namespace> --sort-by=.lastTimestamp` |
| Push no ECR: `gpg: decryption failed: No passphrase given` | Credencial do Docker Desktop guardada no `pass`. O `push-ecr.sh` já usa um config temporário do Docker para evitar isso |
| `ImagePullBackOff` | Imagem não publicada no ECR (rode o `push-ecr.sh`) |
| Pod em `CrashLoopBackOff` | Veja `kubectl logs -n <ns> <pod>`. Normalmente é endpoint ou senha errados no `03-secrets.yaml`, ou o `init-db.sh` não foi rodado |
| `the path "k8s/..." does not exist` | Os comandos de `kubectl apply` e `scripts/` rodam da raiz do repositório, não de dentro de `terraform/` |

## 9. Derrubar tudo

O ambiente custa cerca de **US$ 10/dia** (EKS, 2 nodes, NAT, 2–3 RDS, Redis). Destrua quando terminar.

A ordem importa: o que está dentro do cluster e depende da VPC sai primeiro.

```bash
# remove os serviços (libera recursos criados pelo Kubernetes)
kubectl delete -f k8s/ --ignore-not-found

cd terraform
terragrunt run --all destroy
```

Ou unit por unit, na ordem inversa da criação:

```bash
(cd utils && terragrunt destroy)
(cd iam/irsa && terragrunt destroy)
for d in databases/evaluation-service-redis databases/redis-security-group \
         databases/auth-service-postgres-db databases/flag-service-postgres-db \
         databases/targeting-service-postgres-db databases/postgres-security-group \
         databases/analytics-service-dynamo-db databases/evaluation-service-dynamo-db; do
  (cd $d && terragrunt destroy)
done
(cd ecr && terragrunt run --all destroy)
(cd eks && terragrunt destroy)
(cd vpc && terragrunt destroy)
```

Sobram depois do `destroy`:
- **Snapshots finais dos RDS**: o módulo cria um snapshot ao destruir cada banco (`skip_final_snapshot` não está ligado). Apague em *RDS → Snapshots* se não precisar.
- **Bucket do state** (`first-terraform-state-25-10-2026`): apague pelo console se não for mais usar.
