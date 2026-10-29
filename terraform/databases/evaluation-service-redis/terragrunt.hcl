# Herda o remote_state e o provider.tf do pai automaticamente
include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "tfr:///terraform-aws-modules/elasticache/aws?version=1.11.2"
}

# Subnets privadas da VPC criada em terraform/vpc
dependency "vpc" {
  config_path = "../../vpc"

  mock_outputs = {
    private_subnets = ["subnet-mock-a", "subnet-mock-b", "subnet-mock-c"]
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
}

# Security Group que libera a 6379 só para os nodes do EKS
dependency "sg" {
  config_path = "../redis-security-group"

  mock_outputs = {
    security_group_id = "sg-mock"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
}

inputs = {
  # Cluster Redis do evaluation (1 node, sem réplica: ambiente de estudo)
  replication_group_id = "evaluation-service-redis"
  description          = "Cache do evaluation-service"

  engine         = "redis"
  engine_version = "7.1"
  # cache.t3.micro é elegível ao Free Tier (o Serverless sairia bem mais caro)
  node_type          = "cache.t3.micro"
  num_cache_clusters = 1

  # Com 1 node só não existe failover
  automatic_failover_enabled = false
  multi_az_enabled           = false

  # TLS ligado: a URL no Secret do k8s usa rediss:// (com dois "s")
  transit_encryption_enabled = true
  at_rest_encryption_enabled = true

  apply_immediately = true

  create_security_group = false
  security_group_ids    = [dependency.sg.outputs.security_group_id]

  subnet_group_name = "evaluation-service-redis"
  subnet_ids        = dependency.vpc.outputs.private_subnets

  create_parameter_group = true
  parameter_group_family = "redis7"

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}
