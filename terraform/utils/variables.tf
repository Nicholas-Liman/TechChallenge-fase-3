# Valores injetados pelo terragrunt.hcl a partir dos outputs do ../eks
variable "cluster_name" {
  type = string
}

variable "cluster_endpoint" {
  type = string
}

variable "cluster_certificate_authority_data" {
  type = string
}

# Injetado a partir dos outputs do ../iam/irsa
variable "keda_role_arn" {
  type = string
}
