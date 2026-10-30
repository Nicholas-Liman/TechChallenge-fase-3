# Propriedade nativa do terragrunt. Ele cria o bucket S3 e a tabela do dynamo caso não exista
# Habilita o versionamento no Bucket S3
# Gera o arquivo backend.tf graças ao bloco no generate
remote_state {
  backend = "s3"

  # backend = "local"

  generate = {
    path = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    bucket = "togglemaster-fase3-tfstate-854469103470"

    # Key é o caminho/nome do arquivo no bucket S3. Onde o estado da nossa infraestrutura será armazenado
    key = "${path_relative_to_include()}/terraform.tfstate"
    region = "us-east-1"
    encrypt = true
    # dynamodb_table = "my-lock-table" - Comando depreciado
    
    # Usa um recurso de consistencia e gravação de dados sem ter que usar uma tabela do dynamobd
    # a Grande vantagem dessa propriedade é que ela impede que se duas pessoas derem apply 
    # ao mesmo tempo ele corrompa o .tfstate
    use_lockfile = true
  }

  # Config do backend local (usar junto com backend = "local")
  # config = {
  #   path = "${get_terragrunt_dir()}/terraform.tfstate"
  # }
}

# O OpenTofu/Terraform precisa saber para qual provedor enviara as chamadas de API
# Então aqui informamos as credenciaais da aws, senod assim o proprio terragrunt injeta essa config
# antes de executar os comandos init ou apply.
generate "provider" {
  path = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents = <<EOF
  provider "aws" {
  region = "us-east-1"
}
EOF
}