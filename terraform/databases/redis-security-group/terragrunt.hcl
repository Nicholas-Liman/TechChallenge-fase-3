# Herda o remote_state e o provider.tf do pai automaticamente
include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "tfr:///terraform-aws-modules/security-group/aws?version=5.3.0"
}

# Security Group do ElastiCache (Redis) do evaluation
dependency "vpc" {
  config_path = "../../vpc"

  mock_outputs = {
    vpc_id = "vpc-mock"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
}

# Só os nodes do EKS (onde rodam os pods) podem abrir conexão na 6379
dependency "eks" {
  config_path = "../../eks"

  mock_outputs = {
    node_security_group_id = "sg-mock"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
}

inputs = {
  name        = "redis-elasticache-sg"
  description = "Acesso ao Redis (ElastiCache) a partir dos nodes do EKS"
  vpc_id      = dependency.vpc.outputs.vpc_id

  ingress_with_source_security_group_id = [
    {
      rule                     = "redis-tcp"
      source_security_group_id = dependency.eks.outputs.node_security_group_id
    }
  ]

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}
