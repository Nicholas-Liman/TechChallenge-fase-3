# Herda o remote_state e o provider.tf do pai automaticamente
include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "tfr:///terraform-aws-modules/eks/aws?version=21.29.0"
}

# Lê os outputs da VPC. Enquanto a VPC não foi aplicada, usa os mocks
# (somente para init/validate/plan; o apply exige os valores reais)
dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    vpc_id          = "vpc-mock"
    private_subnets = ["subnet-mock-a", "subnet-mock-b", "subnet-mock-c"]
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
}

inputs = {
  name               = "eks"
  kubernetes_version = "1.33"

  vpc_id     = dependency.vpc.outputs.vpc_id
  subnet_ids = dependency.vpc.outputs.private_subnets

  addons = {
    coredns                = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy             = {}
    vpc-cni                = {
      before_compute = true
    }
  }

  endpoint_public_access = true

  # Adds the current caller identity as an administrator via cluster access entry
  enable_cluster_creator_admin_permissions = true

  # EKS Managed Node Group(s)
  eks_managed_node_groups = {
    example = {
      # Starting on 1.30, AL2023 is the default AMI type for EKS managed node groups
      ami_type       = "AL2023_x86_64_STANDARD"
      # Conta no plano Free da AWS só permite tipos "free-tier-eligible"
      # (t3.medium é bloqueado). c7i-flex.large = 2 vCPU / 4 GB, mesma RAM do t3.medium
      instance_types = ["c7i-flex.large"]

      min_size     = 2
      # A quota da conta é de 8 vCPUs on-demand (4 nodes de 2 vCPU no máximo)
      max_size     = 3
      desired_size = 2
    }
  }

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }
}
