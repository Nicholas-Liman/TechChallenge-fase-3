# Config compartilhada dos repositórios do ECR. Cada pasta em ecr/<servico> inclui este arquivo
# e só define o repository_name (<servico>-image, o nome usado no scripts/push-ecr.sh e nos manifests do k8s/)
terraform {
  source = "tfr:///terraform-aws-modules/ecr/aws?version=2.3.0"
}

inputs = {
  repository_type = "private"

  # Permite o destroy mesmo com imagens dentro do repositório
  repository_force_delete = false

  # Sem ARNs extras: quem tem acesso é a própria conta (seu usuário e a role dos nodes do EKS)
  repository_read_write_access_arns = []

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1,
        description  = "Keep last 10 images",
        selection = {
          tagStatus     = "tagged",
          tagPrefixList = ["v"],
          countType     = "imageCountMoreThan",
          countNumber   = 10
        },
        action = {
          type = "expire"
        }
      },
      {
        # A cada push da tag latest a imagem anterior fica sem tag; mantém só as 5 últimas
        rulePriority = 2,
        description  = "Expire old untagged images",
        selection = {
          tagStatus   = "untagged",
          countType   = "imageCountMoreThan",
          countNumber = 5
        },
        action = {
          type = "expire"
        }
      }
    ]
  })

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}
