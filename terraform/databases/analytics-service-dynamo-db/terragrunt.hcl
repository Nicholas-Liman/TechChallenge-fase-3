include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "tfr:///terraform-aws-modules/dynamodb-table/aws?version=5.5.2"
}

inputs = {
  # Mesmo nome usado no ConfigMap (AWS_DYNAMODB_TABLE)
  name     = "ToggleMasterAnalytics"
  hash_key = "event_id"

  # Paga por requisição, sem precisar dimensionar capacidade
  billing_mode = "PAY_PER_REQUEST"

  attributes = [
    {
      name = "event_id"
      type = "S"
    }
  ]

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}
