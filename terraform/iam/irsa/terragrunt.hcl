# Herda o remote_state e o provider.tf (aws) do pai automaticamente
include "root" {
  path = find_in_parent_folders()
}

# Sem bloco terraform { source = ... }: o terragrunt usa os .tf desta pasta

# OIDC do cluster: é ele que permite um pod "assumir" uma IAM Role (IRSA)
dependency "eks" {
  config_path = "../../eks"

  mock_outputs = {
    oidc_provider     = "oidc.eks.us-east-1.amazonaws.com/id/MOCK"
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/MOCK"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
}

# Fila SQS (evaluation -> analytics)
dependency "sqs" {
  config_path = "../../databases/evaluation-service-dynamo-db"

  mock_outputs = {
    queue_arn = "arn:aws:sqs:us-east-1:123456789012:mock"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
}

# Tabela DynamoDB do analytics
dependency "dynamodb" {
  config_path = "../../databases/analytics-service-dynamo-db"

  mock_outputs = {
    dynamodb_table_arn = "arn:aws:dynamodb:us-east-1:123456789012:table/mock"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
}

inputs = {
  oidc_provider      = dependency.eks.outputs.oidc_provider
  oidc_provider_arn  = dependency.eks.outputs.oidc_provider_arn
  queue_arn          = dependency.sqs.outputs.queue_arn
  dynamodb_table_arn = dependency.dynamodb.outputs.dynamodb_table_arn
}
