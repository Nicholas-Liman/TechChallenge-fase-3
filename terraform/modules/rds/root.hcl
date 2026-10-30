terraform {
  source = "tfr:///terraform-aws-modules/rds/aws?version=7.2.2"
}

# Subnets privadas da VPC criada em terraform/vpc
dependency "vpc" {
  config_path = "${get_repo_root()}/terraform/vpc"

  mock_outputs = {
    private_subnets = ["subnet-mock-a", "subnet-mock-b", "subnet-mock-c"]
  }

  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
}

# Security Group que libera a porta 5432 somente para os nodes do EKS
dependency "sg" {
  config_path = "${get_repo_root()}/terraform/databases/postgres-security-group"

  mock_outputs = {
    security_group_id = "sg-mock"
  }

  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
}

inputs = {
  engine            = "postgres"
  engine_version    = "17"
  instance_class    = "db.t3.micro"
  allocated_storage = 20

  port = "5432"

  # Autenticação por usuário e senha gerenciada pelo AWS Secrets Manager
  iam_database_authentication_enabled = false
  manage_master_user_password         = true

  vpc_security_group_ids = [dependency.sg.outputs.security_group_id]

  tags = {
    Project   = "ToggleMaster"
    ManagedBy = "Terraform"
  }

  create_db_subnet_group = true
  subnet_ids             = dependency.vpc.outputs.private_subnets

  family               = "postgres17"
  major_engine_version = "17"

  parameters = [
    {
      name  = "autovacuum"
      value = "1"
    }
  ]
}