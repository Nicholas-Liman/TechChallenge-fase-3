# Valores injetados pelo terragrunt.hcl a partir dos outputs do eks, sqs e dynamodb
variable "oidc_provider" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "queue_arn" {
  type = string
}

variable "dynamodb_table_arn" {
  type = string
}
