# IRSA (IAM Roles for Service Accounts): cada ServiceAccount do k8s assume uma IAM Role,
# então os pods acessam SQS/DynamoDB sem chave de acesso. Substitui o "eksctl create iamserviceaccount".
# A ServiceAccount precisa da annotation eks.amazonaws.com/role-arn com o ARN da role (ver k8s/07 e k8s/08).
locals {
  service_accounts = {
    # Publica o resultado de cada avaliação na fila
    evaluation-sa-irsa = {
      namespace = "evaluation"
      name      = "evaluation-sa"
      statements = [
        {
          actions   = ["sqs:SendMessage", "sqs:GetQueueUrl", "sqs:GetQueueAttributes"]
          resources = [var.queue_arn]
        }
      ]
    }

    # Consome a fila e grava cada evento no DynamoDB
    analytics-sa-irsa = {
      namespace = "analytics"
      name      = "analytics-sa"
      statements = [
        {
          actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueUrl", "sqs:GetQueueAttributes"]
          resources = [var.queue_arn]
        },
        {
          actions   = ["dynamodb:PutItem", "dynamodb:DescribeTable"]
          resources = [var.dynamodb_table_arn]
        }
      ]
    }

    # O KEDA lê o tamanho da fila para escalar o analytics
    keda-operator-irsa = {
      namespace = "keda"
      name      = "keda-operator"
      statements = [
        {
          actions   = ["sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
          resources = [var.queue_arn]
        }
      ]
    }
  }
}

# Só a ServiceAccount <namespace>/<name> deste cluster pode assumir a role
data "aws_iam_policy_document" "assume" {
  for_each = local.service_accounts

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:sub"
      values   = ["system:serviceaccount:${each.value.namespace}:${each.value.name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "permissions" {
  for_each = local.service_accounts

  dynamic "statement" {
    for_each = each.value.statements

    content {
      actions   = statement.value.actions
      resources = statement.value.resources
    }
  }
}

resource "aws_iam_role" "this" {
  for_each = local.service_accounts

  name               = each.key
  assume_role_policy = data.aws_iam_policy_document.assume[each.key].json

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

resource "aws_iam_role_policy" "this" {
  for_each = local.service_accounts

  name   = "${each.key}-policy"
  role   = aws_iam_role.this[each.key].id
  policy = data.aws_iam_policy_document.permissions[each.key].json
}
