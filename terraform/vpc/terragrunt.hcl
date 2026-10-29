# Configure the module
#
# The URL used here is a shorthand for
# "tfr://registry.terraform.io/terraform-aws-modules/vpc/aws?version=5.16.0".
#
# You can find the module at:
# https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest
#
# Note the extra `/` after the `tfr` protocol is required for the shorthand
# notation.

# Herda o remote_state e o provider.tf do pai automaticamente
include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "tfr:///terraform-aws-modules/vpc/aws?version=5.16.0"
}

# Aqui fornecemos parametros para o modulo da vpc
# Não são para o Backend. O backend remoto já ficou configurado dentro do remote state
inputs = {
  name = "my-vpc"

  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  create_igw = true

  # NAT permite que os nodes (subnets privadas) baixem imagens da internet/ECR
  enable_nat_gateway = true
  single_nat_gateway = true

  enable_vpn_gateway = false

  # Tags que o EKS usa para descobrir onde criar os Load Balancers
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = {
    Iac = "true"
    Environment = "dev"
  }
}