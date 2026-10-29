# ARN de cada role, ex.: role_arns["keda-operator-irsa"] (lido pelo terraform/utils)
output "role_arns" {
  value = { for k, role in aws_iam_role.this : k => role.arn }
}
