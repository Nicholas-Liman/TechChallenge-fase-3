# Helm provider v3: kubernetes e exec agora são atributos (com "="), não blocos
provider "helm" {
  kubernetes = {
    host                   = var.cluster_endpoint
    cluster_ca_certificate = base64decode(var.cluster_certificate_authority_data)

    # Gera o token do cluster usando as credenciais da AWS de quem roda o apply
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", "us-east-1"]
    }
  }
}

# Ingress controller (cria o IngressClass "nginx" usado em k8s/09-ingress.yaml)
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.15.1"
  namespace        = "ingress-nginx"
  create_namespace = true

  values = [
    file("${path.module}/ingress-nginx-values.yaml")
  ]
}

# Métricas de CPU/memória dos pods (kubectl top e os gatilhos de CPU do KEDA)
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = "3.14.0"
  namespace  = "kube-system"
}

# KEDA: escala os serviços por CPU e o analytics pelo tamanho da fila SQS (ScaledObjects em k8s/)
resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.21.0"
  namespace        = "keda"
  create_namespace = true

  # O operador usa a role IRSA criada em terraform/iam/irsa para ler a fila
  values = [
    yamlencode({
      podIdentity = {
        aws = {
          irsa = {
            enabled = true
            roleArn = var.keda_role_arn
          }
        }
      }
    })
  ]
}
