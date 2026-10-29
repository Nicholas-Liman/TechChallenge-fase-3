include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "tfr:///terraform-aws-modules/sqs/aws?version=5.2.2"
}

inputs = {
  # Mesmo nome usado no ConfigMap (AWS_SQS_URL) e no ScaledObject do KEDA
  name = "evaluation-service-sqs"

  # Criptografia gerenciada pelo próprio SQS (SSE-SQS), sem precisar de chave KMS
  sqs_managed_sse_enabled = true

  # Long polling: o analytics espera até 20s por mensagem em vez de ficar batendo na API
  receive_wait_time_seconds  = 20
  visibility_timeout_seconds = 30
  message_retention_seconds  = 345600 # 4 dias

  # Dead Letter Queue: mensagem que falhar 5 vezes vai para evaluation-service-sqs-dlq
  create_dlq = true
  redrive_policy = {
    maxReceiveCount = 5
  }

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}
