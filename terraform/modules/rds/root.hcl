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

# Security Group que libera a 5432 só para os nodes do EKS
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
  # RDS não oferece a família t3a, por isso db.t3.micro
  instance_class    = "db.t3.micro"
  # Mínimo do gp2/gp3 para PostgreSQL é 20 GB
  allocated_storage = 20

  port     = "5432"

  iam_database_authentication_enabled = true

  # Senha fixa (ambiente de estudo). Sem isso o RDS gera a senha no Secrets Manager
  # e troca a cada 7 dias, o que quebraria o DATABASE_URL estático do k8s
  manage_master_user_password = false
  # Na v7 do módulo a variável se chama password_wo (write-only: não fica salva no state)
  password_wo                 = "12345678" # mínimo de 8 caracteres exigido pelo RDS
  password_wo_version         = 1          # incremente para aplicar uma troca de senha

  vpc_security_group_ids = [dependency.sg.outputs.security_group_id]


  tags = {
    Owner       = "user"
    Environment = "dev"
  }

  # DB subnet group
  create_db_subnet_group = true
  subnet_ids             = dependency.vpc.outputs.private_subnets

  # DB parameter group
  family = "postgres17"

  # DB option group
  major_engine_version = "17"

  # Database Deletion Protection

  parameters = [
    {
      name  = "autovacuum"
      value = 1
    },
    {
      name  = "client_encoding"
      value = "utf8"
    }
  ]
}
