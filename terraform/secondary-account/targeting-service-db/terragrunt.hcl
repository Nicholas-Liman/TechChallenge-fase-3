include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "tfr:///terraform-aws-modules/rds/aws?version=7.2.2"
}

dependency "networking" {
  config_path = "../networking"

  mock_outputs = {
    private_subnet_ids          = ["subnet-mock-a", "subnet-mock-b"]
    targeting_security_group_id = "sg-mock"
  }

  mock_outputs_allowed_terraform_commands = [
    "init",
    "validate",
    "plan"
  ]
}

inputs = {
  identifier = "targeting-service-db"

  engine               = "postgres"
  engine_version       = "17.11"
  family               = "postgres17"
  major_engine_version = "17"
  instance_class       = "db.t3.micro"

  db_name  = "targeting_db"
  username = "targeting"
  port     = 5432

  allocated_storage = 20
  storage_encrypted = true

  manage_master_user_password = true

  create_db_subnet_group = true
  subnet_ids             = dependency.networking.outputs.private_subnet_ids

  vpc_security_group_ids = [
    dependency.networking.outputs.targeting_security_group_id
  ]

  publicly_accessible = false
  multi_az            = false

  backup_retention_period = 1
  deletion_protection     = false

  tags = {
    Project     = "ToggleMaster"
    ManagedBy   = "Terraform"
    Environment = "fase3"
  }
}