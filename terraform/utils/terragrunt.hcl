# Herda o remote_state e o provider.tf (aws) do pai automaticamente
include "root" {
  path = find_in_parent_folders()
}

# Sem bloco terraform { source = ... }: o terragrunt usa os .tf desta pasta

# Lê os outputs do EKS. Enquanto o cluster não foi aplicado, usa os mocks
# (somente para init/validate; o plan/apply do helm precisa conectar no cluster real)
dependency "eks" {
  config_path = "../eks"

  mock_outputs = {
    cluster_name                       = "eks"
    cluster_endpoint                   = "https://mock.eks.amazonaws.com"
    cluster_certificate_authority_data = "bW9jaw=="
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "destroy"]
}

# Role IRSA do operador do KEDA (lê o tamanho da fila SQS)
dependency "irsa" {
  config_path = "../iam/irsa"

  mock_outputs = {
    role_arns = {
      keda-operator-irsa = "arn:aws:iam::123456789012:role/mock"
    }
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "destroy"]
}

inputs = {
  cluster_name                       = dependency.eks.outputs.cluster_name
  cluster_endpoint                   = dependency.eks.outputs.cluster_endpoint
  cluster_certificate_authority_data = dependency.eks.outputs.cluster_certificate_authority_data
  keda_role_arn                      = dependency.irsa.outputs.role_arns["keda-operator-irsa"]
}
