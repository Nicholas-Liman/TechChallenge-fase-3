<p align="center">
  <a href="https://www.fiap.com.br/"><img src="assets/fiap-logo.svg" alt="FIAP" width="240"></a>
</p>

<h3 align="center">POSTECH DevOps e Arquitetura Cloud · Tech Challenge · Fase 2</h3>

<p align="center">
  <b>ToggleMaster</b>: 5 microsserviços conteinerizados e orquestrados no Kubernetes da AWS (EKS)
</p>

<p align="center">
  📄 <a href="docs/tech-challenge-fase-3.pdf"><b>Clique aqui para ver o enunciado do desafio (PDF)</b></a>
</p>

---

## Sumário

1. [Visão geral](#1-visão-geral)
2. [Arquitetura da aplicação](#2-arquitetura-da-aplicação)
3. [Arquitetura AWS e estratégia de duas contas](#3-arquitetura-aws-e-estratégia-de-duas-contas)
4. [Infraestrutura como código com Terraform](#4-infraestrutura-como-código-com-terraform)
5. [Kubernetes e operação no EKS](#5-kubernetes-e-operação-no-eks)
6. [CI/CD e DevSecOps](#6-cicd-e-devsecops)
7. [GitOps com ArgoCD](#7-gitops-com-argocd)
8. [Estrutura do repositório](#8-estrutura-do-repositório)
9. [Tecnologias utilizadas](#9-tecnologias-utilizadas)
10. [Executar localmente](#10-executar-localmente)
11. [Operação e comandos úteis](#11-operação-e-comandos-úteis)
12. [Segurança e boas práticas](#12-segurança-e-boas-práticas)
13. [Demonstração e entregáveis](#13-demonstração-e-entregáveis)
14. [Decisões técnicas e aprendizados](#14-decisões-técnicas-e-aprendizados)
15. [Autor](#15-autor)

---

## 1. Visão geral

O **ToggleMaster** é uma plataforma de gerenciamento e avaliação de *Feature Flags*. O projeto evoluiu de um MVP monolítico para uma arquitetura composta por cinco microsserviços independentes, conteinerizados e executados em Kubernetes na AWS.

Além da implementação da aplicação, o projeto trabalha o ciclo de vida da infraestrutura e da entrega de software:

- Provisionamento de infraestrutura em nuvem com **Terraform**;
- Execução dos microsserviços em **Amazon EKS**;
- Armazenamento e distribuição de imagens por **Amazon ECR**;
- Automação de build, validações e publicação com **GitHub Actions**;
- Verificações de segurança com **Bandit** e **Trivy**;
- Autenticação entre GitHub Actions e AWS por **OpenID Connect (OIDC)**;
- Acesso dos workloads aos serviços AWS por **IAM Roles for Service Accounts (IRSA)**;
- Gerenciamento declarativo dos recursos Kubernetes com **ArgoCD**;
- Escalabilidade orientada a métricas e eventos com **KEDA**.

O repositório reúne o código dos serviços, os workflows, os manifestos Kubernetes e os arquivos de infraestrutura como código utilizados pelo projeto.

## 2. Arquitetura da aplicação

A aplicação é dividida em cinco microsserviços:

| Serviço | Linguagem | Porta | Responsabilidade | Persistência / integração |
|---|---:|---:|---|---|
| `auth-service` | Go | 8001 | Criação e validação de chaves de API | RDS PostgreSQL |
| `flag-service` | Python | 8002 | CRUD das Feature Flags | RDS PostgreSQL |
| `targeting-service` | Python | 8003 | Gerenciamento das regras de segmentação | RDS PostgreSQL |
| `evaluation-service` | Go | 8004 | Avaliação de uma flag para um usuário; publica eventos de avaliação | ElastiCache Redis e SQS |
| `analytics-service` | Python | 8005 | Consumo dos eventos e gravação dos dados analíticos | SQS e DynamoDB |

### Fluxo funcional

1. Um consumidor utiliza a API para criar e configurar uma Feature Flag.
2. O `auth-service` valida a chave de API utilizada nas operações protegidas.
3. O `flag-service` armazena as definições das flags.
4. O `targeting-service` mantém as regras de segmentação associadas às flags.
5. O `evaluation-service` consulta os dados necessários, utiliza Redis como cache e determina se a flag será habilitada para o usuário.
6. O resultado da avaliação é publicado no Amazon SQS.
7. O `analytics-service` consome as mensagens e persiste os eventos no DynamoDB.

### Por que utilizar mais de um tipo de armazenamento?

| Serviço AWS | Tipo | Utilização | Justificativa arquitetural |
|---|---|---|---|
| Amazon RDS for PostgreSQL | Banco relacional | `auth`, `flag` e `targeting` | Dados estruturados, relacionamentos e operações transacionais. O isolamento por serviço reduz o acoplamento entre os domínios. |
| Amazon ElastiCache for Redis | Cache em memória | `evaluation` | Reduz a latência do caminho crítico de avaliação, evitando consultas repetidas aos serviços de configuração. |
| Amazon SQS | Mensageria | Comunicação entre `evaluation` e `analytics` | Desacopla a avaliação síncrona do processamento analítico assíncrono. |
| Amazon DynamoDB | Banco NoSQL | `analytics` | Persistência de eventos com modelo flexível e capacidade de atender a operações de escrita distribuídas. |

### Visão simplificada

```text
                         Consumidores / Clientes
                                  |
                                  v
                         Network Load Balancer
                                  |
                                  v
                       NGINX Ingress Controller
                                  |
             +--------------------+--------------------+
             |                    |                    |
             v                    v                    v
         auth-service         flag-service       targeting-service
             |                    |                    |
             +--------------------+--------------------+
                                  |
                                  v
                          evaluation-service
                             |          |
                             v          v
                       ElastiCache     Amazon SQS
                                          |
                                          v
                                    analytics-service
                                          |
                                          v
                                      DynamoDB

                Os cinco serviços são executados no Amazon EKS.
```

O `analytics-service` é um worker assíncrono e não precisa ser exposto diretamente pelo Ingress. Os endpoints HTTP dos demais serviços são publicados por meio do controlador de Ingress.

## 3. Arquitetura AWS e estratégia de duas contas

### 3.1 Por que duas contas AWS?

A infraestrutura utiliza **duas contas AWS distintas**. Essa divisão foi adotada devido a limitações de quota de recursos do Amazon RDS na conta inicialmente utilizada.

Em vez de manter toda a infraestrutura condicionada à quota disponível em uma única conta, os recursos foram distribuídos entre os dois ambientes AWS. Isso permitiu dar continuidade ao provisionamento e manter a arquitetura operacional.

A separação também exige que cada ambiente tenha suas próprias configurações de identidade, permissões, região e estado do Terraform. Os providers e as credenciais utilizados em cada implantação precisam apontar para a conta correspondente.

Em linhas gerais:

- **Conta principal:** hospeda o cluster Amazon EKS, os repositórios Amazon ECR dos cinco microsserviços e as integrações de identidade utilizadas pelo GitHub Actions e pelos workloads.
- **Conta secundária:** recebe os recursos provisionados no ambiente Terraform secundário, utilizados para distribuir a infraestrutura entre as contas diante da limitação de quota do RDS.

Os identificadores numéricos das contas não são publicados neste README. O mesmo cuidado deve ser aplicado a endpoints privados, credenciais, senhas, tokens e valores de Secrets.

### 3.2 Recursos e integrações

Na conta principal, os recursos e integrações confirmados incluem:

- Cluster Amazon EKS na região `us-east-1`;
- Repositórios Amazon ECR para `auth`, `flag`, `targeting`, `evaluation` e `analytics`;
- IAM Role `GitHubActionsAuthECRRole`, utilizada pela automação de CI/CD via OIDC;
- IAM Roles vinculadas às ServiceAccounts `evaluation-sa` e `analytics-sa` por IRSA;
- Amazon SQS utilizado no fluxo de eventos entre avaliação e analytics;
- Amazon DynamoDB utilizado pelo serviço de analytics.

A conta secundária é mantida como um ambiente separado de infraestrutura. Não se deve presumir que recursos, ARNs, endpoints ou permissões de uma conta estejam disponíveis na outra sem configuração explícita de acesso entre contas.

### 3.3 Região

A região AWS utilizada pelos recursos principais descritos neste projeto é `us-east-1` (N. Virginia). Verifique a região configurada nos providers Terraform, nos workflows e nos manifests antes de executar qualquer operação de infraestrutura.

## 4. Infraestrutura como código com Terraform

O Terraform é utilizado para declarar e provisionar a infraestrutura AWS. A definição de recursos em código permite versionar as configurações, revisar alterações antes de aplicá-las e repetir o provisionamento de forma controlada.

O projeto mantém configurações Terraform para os ambientes AWS utilizados, incluindo o ambiente secundário. Como existem duas contas, é importante executar cada configuração com o contexto de credenciais e provider correspondente.

### Fluxo recomendado de execução

Os comandos abaixo devem ser executados no diretório que contém o módulo/root module Terraform do ambiente desejado:

```bash
terraform init
terraform fmt -check
terraform validate
terraform plan
terraform apply
```

Para remover recursos, revise cuidadosamente o plano de destruição antes de confirmar qualquer `terraform destroy`.

### Cuidados com duas contas

- Confirme a identidade AWS antes de executar Terraform:

  ```bash
  aws sts get-caller-identity
  ```

- Utilize o perfil ou mecanismo de credenciais correspondente à conta do ambiente que será provisionado.
- Mantenha os estados Terraform dos ambientes separados. Não reutilize o mesmo backend/state para recursos de contas distintas.
- Revise região, IDs de conta, ARNs, VPCs, subnets e dependências entre os ambientes antes de aplicar mudanças.
- Não versione arquivos de estado, arquivos `.tfvars` com dados sensíveis, credenciais ou outputs que exponham segredos.

> **Atenção:** o Terraform pode criar recursos AWS com cobrança contínua. Sempre revise `terraform plan`, monitore os recursos provisionados e remova os ambientes que não forem mais necessários, conforme as dependências de cada módulo.

## 5. Kubernetes e operação no EKS

Os cinco microsserviços são executados no Amazon EKS e organizados em namespaces próprios:

- `auth`
- `flag`
- `targeting`
- `evaluation`
- `analytics`

Cada serviço possui os recursos Kubernetes necessários para execução, incluindo Deployments, Services e ConfigMaps. Os serviços que precisam acessar recursos AWS utilizam ServiceAccounts associadas a IAM Roles por IRSA.

### 5.1 Manifestos Kubernetes

Os manifestos acompanhados pelo ArgoCD ficam no diretório raiz `k8s/`:

| Arquivo | Responsabilidade |
|---|---|
| `01-namespaces.yaml` | Criação dos namespaces dos microsserviços |
| `02-configMap.yaml` | Configurações não sensíveis, como região, URLs e nomes de recursos |
| `03-secrets.yaml` | Referência/definição de valores sensíveis utilizados pelos serviços; é excluído da leitura automática do ArgoCD |
| `04-authService.yaml` | Deployment e Service do `auth-service` |
| `05-flag-service.yaml` | Deployment e Service do `flag-service` |
| `06-targeting-service.yaml` | Deployment e Service do `targeting-service` |
| `07-evaluation-service.yaml` | Deployment, Service e recursos de escalabilidade do `evaluation-service` |
| `08-analytics-service.yaml` | Deployment, Service e recursos associados ao `analytics-service` |
| `09-ingress.yaml` | Regras de entrada HTTP para os serviços expostos |

Os manifests em `k8s/` são a fonte de verdade usada pelo ArgoCD. O diretório `FIAP-DevOps-Fase-02/k8s/`, quando presente, não é o caminho monitorado pela aplicação ArgoCD atual.

### 5.2 IRSA — acesso dos pods aos serviços AWS

O projeto utiliza **IAM Roles for Service Accounts (IRSA)** para permitir que workloads específicos acessem serviços AWS sem armazenar access keys estáticas nos Secrets do Kubernetes.

As ServiceAccounts relevantes incluem:

- `evaluation-sa`, no namespace `evaluation`;
- `analytics-sa`, no namespace `analytics`.

Cada ServiceAccount é associada a uma IAM Role por meio de uma anotação. As permissões efetivas dependem da trust policy e das policies vinculadas à role.

### 5.3 KEDA e escalabilidade

O KEDA é utilizado para criar e gerenciar escalabilidade orientada a métricas e eventos. O projeto inclui ScaledObjects para os microsserviços.

O `analytics-service` possui uma característica específica: como processa mensagens de uma fila, a quantidade de mensagens pendentes no SQS é um indicador mais direto da demanda do que apenas o uso de CPU.

O KEDA permite escalar o worker de acordo com o tamanho da fila, respeitando os limites configurados no ScaledObject. A configuração efetiva de mínimo, máximo e gatilhos deve ser consultada nos manifests versionados.

## 6. CI/CD e DevSecOps

O GitHub Actions automatiza as etapas de validação, análise de segurança, construção e publicação das imagens dos microsserviços.

O repositório possui cinco workflows independentes:

```text
.github/workflows/
├── analytics-service-pipeline.yaml
├── auth-pipeline.yaml
├── evaluation-service-pipeline.yaml
├── flag-service-pipeline.yaml
└── targeting-service-pipeline.yaml
```

### 6.1 Pipeline do Analytics

O workflow `analytics-service-pipeline.yaml` executa as seguintes etapas:

1. Checkout do repositório;
2. Configuração do Python 3.12;
3. Instalação das dependências de `requirements.txt`;
4. Verificação de consistência com `pip check`;
5. Compilação dos arquivos Python com `compileall`;
6. Análise estática com Bandit;
7. Análise das dependências com Trivy;
8. Construção da imagem Docker;
9. Análise da imagem Docker com Trivy;
10. Configuração de credenciais AWS por OIDC;
11. Login no Amazon ECR;
12. Publicação da imagem com tag baseada no SHA do commit;
13. Atualização automática do manifesto GitOps `k8s/08-analytics-service.yaml`;
14. Commit e push da alteração do manifesto para a branch `main`.

As verificações Trivy do workflow do Analytics estão configuradas para bloquear vulnerabilidades `CRITICAL`, com `ignore-unfixed` habilitado. A política configurada deve ser conferida no YAML do workflow antes de reproduzir os testes de segurança.

### 6.2 Autenticação GitHub Actions → AWS com OIDC

O GitHub Actions assume a IAM Role `GitHubActionsAuthECRRole` utilizando OIDC. Isso evita manter access keys permanentes da AWS nos Secrets do GitHub.

O workflow declara as permissões necessárias para solicitar o token OIDC e, no pipeline do Analytics, atualizar o manifesto no próprio repositório. A permissão de escrita do workflow também precisa estar habilitada nas configurações de Actions do repositório.

### 6.3 Tags imutáveis por commit

As imagens são publicadas no ECR utilizando o SHA do commit como tag. Essa estratégia permite relacionar:

- o código-fonte que originou a imagem;
- a tag publicada no ECR;
- a referência registrada no manifesto Kubernetes;
- a versão executada pelo Deployment.

Isso melhora a rastreabilidade e evita depender exclusivamente de uma tag mutável como `latest`.

### 6.4 Escopo atual da automação GitOps

A automação de atualização de manifesto foi implementada e validada no workflow do **Analytics**. Os outros quatro workflows existem e automatizam seus respectivos pipelines; não se deve assumir que todos atualizam manifestos GitOps da mesma maneira sem conferir cada arquivo de workflow.

## 7. GitOps com ArgoCD

O ArgoCD mantém o cluster alinhado ao estado desejado declarado no Git.

A aplicação configurada no cluster possui as seguintes características:

| Propriedade | Configuração |
|---|---|
| Nome da aplicação | `togglemaster` |
| Namespace | `argocd` |
| Repositório | `Nicholas-Liman/TechChallenge-fase-3` |
| Branch | `main` |
| Diretório monitorado | `k8s/` |
| Exclusão | `03-secrets.yaml` |
| Automated Sync | Habilitado |
| Prune | Desabilitado (`false`) |
| Self Heal | Habilitado (`true`) |
| Respect Ignore Differences | Habilitado |

### 7.1 Fluxo GitOps validado

O fluxo validado no Analytics é:

1. O pipeline constrói e publica uma imagem no ECR.
2. O workflow atualiza a tag em `k8s/08-analytics-service.yaml`.
3. O GitHub Actions cria um commit de deploy e envia a alteração para `main`.
4. O ArgoCD identifica a nova revisão do repositório.
5. Com Automated Sync habilitado, o ArgoCD aplica a alteração sem comando manual de sincronização.
6. O Kubernetes executa o rollout do Deployment.
7. O estado final é conferido como `Synced` e `Healthy`.

Esse fluxo foi exercitado com novas execuções do workflow Analytics, incluindo atualização automática do manifesto, commit pelo `github-actions[bot]`, detecção pelo ArgoCD e atualização da imagem no Deployment do namespace `analytics`.

### 7.2 Política de sincronização

O ArgoCD está configurado com:

- `automated`: aplica alterações detectadas no Git;
- `prune: false`: não exclui automaticamente recursos removidos do Git;
- `selfHeal: true`: corrige divergências manuais entre o cluster e o estado declarado no Git;
- `RespectIgnoreDifferences=true`: respeita regras de diferenças ignoradas.

A opção `Prune=false` também está presente em `syncOptions`. A configuração foi mantida para evitar exclusões automáticas durante a sincronização.

### 7.3 Conferir o estado da aplicação

```bash
kubectl get application togglemaster -n argocd

kubectl get application togglemaster -n argocd \
  -o jsonpath='{.status.sync.status}{" | "}{.status.health.status}{"\n"}'
```

Conferir a imagem do Analytics efetivamente declarada no Deployment:

```bash
kubectl get deployment analytics -n analytics \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Comparar com a imagem no manifesto versionado:

```bash
grep -n 'analytics-image:' k8s/08-analytics-service.yaml
```

Durante uma implantação, o estado pode passar temporariamente por `Progressing`. Ao concluir o rollout, o resultado esperado é `Synced` e `Healthy`.

> Não execute `argocd app sync` durante uma demonstração de sincronização automática: isso esconderia a evidência de que o ArgoCD aplicou a alteração por conta própria.

## 8. Estrutura do repositório

Os diretórios principais do projeto estão organizados da seguinte forma:

```text
.
├── .github/
│   └── workflows/                  # Pipelines dos cinco microsserviços
├── assets/                          # Imagens e identidade visual do README
├── docs/                            # Enunciados e documentação de apoio
├── FIAP-DevOps-Fase-02/
│   └── services/                    # Código-fonte e Dockerfiles dos serviços
│       ├── analytics-service/
│       ├── auth-service/
│       ├── evaluation-service/
│       ├── flag-service/
│       └── targeting-service/
├── k8s/                             # Manifestos Kubernetes monitorados pelo ArgoCD
│   ├── 01-namespaces.yaml
│   ├── 02-configMap.yaml
│   ├── 03-secrets.yaml
│   ├── 04-authService.yaml
│   ├── 05-flag-service.yaml
│   ├── 06-targeting-service.yaml
│   ├── 07-evaluation-service.yaml
│   ├── 08-analytics-service.yaml
│   └── 09-ingress.yaml
└── README.md
```

As configurações Terraform dos ambientes AWS ficam nos diretórios próprios de infraestrutura do projeto. A árvore acima destaca os diretórios da aplicação, dos workflows e dos manifestos Kubernetes, sem presumir um único caminho para os módulos Terraform das duas contas.

## 9. Tecnologias utilizadas

| Categoria | Tecnologias |
|---|---|
| Linguagens e aplicação | Go, Python, Flask, Gunicorn, Boto3 |
| Containers | Docker |
| Orquestração | Kubernetes, Amazon EKS |
| Infraestrutura como código | Terraform |
| Registro de imagens | Amazon ECR |
| Banco relacional | Amazon RDS for PostgreSQL |
| Cache | Amazon ElastiCache for Redis |
| Mensageria | Amazon SQS |
| Banco NoSQL | Amazon DynamoDB |
| Escalabilidade | KEDA, Kubernetes HPA |
| CI/CD | GitHub Actions |
| Segurança | Bandit, Trivy, AWS IAM, OIDC, IRSA |
| GitOps | ArgoCD |
| Entrada HTTP | NGINX Ingress Controller, Network Load Balancer |

## 10. Executar localmente

O ambiente local da Fase 2 utiliza Docker Compose para executar os microsserviços e suas dependências locais. O arquivo `docker-compose.yaml` na raiz do repositório define os serviços do ambiente de desenvolvimento.

### Pré-requisitos

- Docker Engine;
- Docker Compose v2;
- `curl` para os testes HTTP.

Verifique a instalação:

```bash
docker --version
docker compose version
```

Suba o ambiente:

```bash
docker compose up -d --build
docker compose ps
```

Para consultar os logs:

```bash
docker compose logs -f
```

As portas utilizadas na configuração local da Fase 2 são:

| Serviço | URL local |
|---|---|
| auth | `http://localhost:8001` |
| flag | `http://localhost:8002` |
| targeting | `http://localhost:8003` |
| evaluation | `http://localhost:8004` |
| analytics | `http://localhost:8005/health` |
| DynamoDB Admin | `http://localhost:9002` |
| ElasticMQ (SQS) | `http://localhost:9324` |

Teste os endpoints de health:

```bash
for port in 8001 8002 8003 8004 8005; do
  printf 'Porta %s: ' "$port"
  curl -sS "http://localhost:${port}/health"
  echo
done
```

Encerre o ambiente:

```bash
# Para os containers, preservando os volumes
docker compose down

# Para remover também os volumes locais (apaga os dados persistidos)
docker compose down -v
```

> **Observação sobre o ambiente local:** a documentação da Fase 2 registrava uma limitação na integração do `evaluation-service` com o endpoint SQS local do ElasticMQ. Antes de utilizar o Compose como demonstração de ponta a ponta da mensageria, confira se o serviço continua configurado para ler `SQS_ENDPOINT` e se a configuração local foi atualizada. No EKS, o fluxo de produção utiliza o Amazon SQS.

## 11. Operação e comandos úteis

Os comandos abaixo são úteis para acompanhar o ambiente existente. Execute-os com o contexto `kubectl` apontando para o cluster correto.

### Verificar contexto e cluster

```bash
kubectl config current-context
kubectl get nodes
```

### Verificar namespaces, Deployments e Pods

```bash
kubectl get namespaces
kubectl get deployments -A
kubectl get pods -A
```

### Verificar escalabilidade

```bash
kubectl get scaledobjects -A
kubectl get hpa -A
```

### Verificar logs

```bash
kubectl logs -n analytics deployment/analytics --tail=100
kubectl logs -n evaluation deployment/evaluation --tail=100
```

### Acompanhar o rollout do Analytics

```bash
kubectl rollout status deployment/analytics -n analytics
kubectl get pods -n analytics -o wide
```

### Acompanhar workflows

```bash
gh run list --workflow analytics-service-pipeline.yaml --limit 5
```

Acompanhe uma execução usando o ID retornado pelo comando:

```bash
gh run watch ID_DA_EXECUCAO --exit-status
```

### Publicação e deploy

No fluxo atual do Analytics, a publicação da imagem e a atualização do manifesto são feitas pelo GitHub Actions. Evite executar `kubectl set image`, `kubectl rollout restart` ou editar manualmente o manifesto para uma demonstração de GitOps, pois isso altera o estado fora do fluxo versionado.

Para os outros serviços, consulte o workflow correspondente e o estado atual da aplicação antes de publicar ou atualizar imagens.

## 12. Segurança e boas práticas

O projeto utiliza diferentes mecanismos de segurança ao longo do ciclo de desenvolvimento e execução:

- **OIDC:** autenticação do GitHub Actions na AWS sem access keys permanentes armazenadas no repositório;
- **IAM Roles:** permissões concedidas por função, com escopo definido nas policies e trust policies;
- **IRSA:** identidade AWS associada às ServiceAccounts dos workloads que precisam acessar recursos AWS;
- **Bandit:** análise estática do código Python;
- **Trivy:** análise de vulnerabilidades nas dependências e nas imagens Docker;
- **Tags por SHA:** rastreabilidade entre commit, imagem e implantação;
- **Separação de configuração:** ConfigMaps para parâmetros não sensíveis e Secrets para valores sensíveis;
- **Exclusão de `03-secrets.yaml` no ArgoCD:** evita que esse arquivo seja aplicado pelo diretório monitorado da aplicação.

### Informações que não devem ser versionadas

Nunca publique no repositório:

- Access keys ou secret keys da AWS;
- Senhas de bancos de dados;
- Tokens pessoais ou de automação;
- Conteúdo de kubeconfig;
- Arquivos Terraform state;
- Arquivos `.tfvars` contendo credenciais ou informações sensíveis;
- Secrets em texto puro.

Valores codificados em Base64 não são criptografia. A proteção de Secrets precisa considerar controle de acesso ao repositório e ao cluster, além de mecanismos apropriados para armazenamento de segredos.

## 13. Demonstração e entregáveis

A demonstração em vídeo tem como objetivo apresentar o ciclo de infraestrutura, segurança e implantação. O roteiro previsto contempla:

- Provisionamento ou apresentação da infraestrutura criada com Terraform;
- Recursos AWS e justificativa da utilização de duas contas;
- Execução de pipeline no GitHub Actions;
- Bloqueio de uma alteração vulnerável pelas verificações de segurança;
- Correção da vulnerabilidade e execução bem-sucedida do pipeline;
- Publicação da imagem no Amazon ECR;
- Atualização automática do manifesto Kubernetes pelo pipeline;
- Detecção da nova revisão e sincronização automática pelo ArgoCD;
- Atualização do Deployment no EKS.

**Vídeo:** _adicionar link da gravação quando publicado._

## 14. Decisões técnicas e aprendizados

### Separação em microsserviços

Os domínios de autenticação, gerenciamento de flags, targeting, avaliação e analytics possuem responsabilidades distintas. Isso permite evoluir e implantar cada componente separadamente.

### Processamento assíncrono de analytics

A avaliação de uma Feature Flag precisa responder rapidamente. O processamento analítico é desacoplado por SQS para que a gravação dos eventos não faça parte do caminho síncrono de resposta.

### Duas contas AWS

A distribuição da infraestrutura entre duas contas foi uma decisão prática para contornar limitações de quota do RDS. Essa escolha traz a necessidade de administrar separadamente permissões, providers, regiões, estados Terraform e dependências entre contas.

### Segurança integrada ao pipeline

As verificações estáticas e de dependências são executadas antes da publicação das imagens. O pipeline pode impedir a progressão quando encontra vulnerabilidades que atendem ao limite definido na configuração do scanner.

### GitOps como fonte de verdade

A tag publicada no registro de imagens é registrada em um manifesto Kubernetes versionado. O ArgoCD observa o repositório e reconcilia o cluster com o estado declarado no Git, reduzindo a necessidade de comandos manuais de implantação.

## 15. Autor

Desenvolvido por **Nicholas Lima**.

- GitHub: [Nicholas-Liman](https://github.com/Nicholas-Liman)
- Repositório: [TechChallenge-fase-3](https://github.com/Nicholas-Liman/TechChallenge-fase-3)

---

<p align="center">
  <a href="docs/tech-challenge-fase-2.pdf">Enunciado do Tech Challenge — Fase 2</a>
</p>
