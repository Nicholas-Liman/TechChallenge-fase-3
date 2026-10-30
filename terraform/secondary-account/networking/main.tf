provider "aws" {
  alias   = "primary"
  region  = "us-east-1"
  profile = "default"
}

locals {
  secondary_vpc_id = "vpc-0f0a48985e6f78be8"
  primary_vpc_id   = "vpc-0a1793c050d362503"

  primary_private_route_table_id = "rtb-003023460b45ebedf"

  primary_account_id = "854469103470"

  eks_private_cidrs = [
    "10.0.1.0/24",
    "10.0.2.0/24",
    "10.0.3.0/24"
  ]

  common_tags = {
    Project     = "ToggleMaster"
    ManagedBy   = "Terraform"
    Environment = "fase3"
  }
}

resource "aws_subnet" "targeting_private_a" {
  vpc_id                  = local.secondary_vpc_id
  cidr_block              = "172.31.96.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "targeting-private-us-east-1a"
  })
}

resource "aws_subnet" "targeting_private_b" {
  vpc_id                  = local.secondary_vpc_id
  cidr_block              = "172.31.97.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "targeting-private-us-east-1b"
  })
}

resource "aws_route_table" "targeting_private" {
  vpc_id = local.secondary_vpc_id

  tags = merge(local.common_tags, {
    Name = "targeting-private-route-table"
  })
}

resource "aws_route_table_association" "targeting_private_a" {
  subnet_id      = aws_subnet.targeting_private_a.id
  route_table_id = aws_route_table.targeting_private.id
}

resource "aws_route_table_association" "targeting_private_b" {
  subnet_id      = aws_subnet.targeting_private_b.id
  route_table_id = aws_route_table.targeting_private.id
}

resource "aws_vpc_peering_connection" "targeting" {
  vpc_id        = local.secondary_vpc_id
  peer_vpc_id   = local.primary_vpc_id
  peer_owner_id = local.primary_account_id
  peer_region   = "us-east-1"
  auto_accept   = false

  tags = merge(local.common_tags, {
    Name = "togglemaster-primary-secondary-peering"
    Side = "secondary"
  })
}

resource "aws_vpc_peering_connection_accepter" "targeting" {
  provider = aws.primary

  vpc_peering_connection_id = aws_vpc_peering_connection.targeting.id
  auto_accept               = true

  tags = merge(local.common_tags, {
    Name = "togglemaster-primary-secondary-peering"
    Side = "primary"
  })
}

resource "aws_route" "secondary_to_primary" {
  route_table_id            = aws_route_table.targeting_private.id
  destination_cidr_block    = "10.0.0.0/16"
  vpc_peering_connection_id = aws_vpc_peering_connection.targeting.id

  depends_on = [
    aws_vpc_peering_connection_accepter.targeting
  ]
}

resource "aws_route" "primary_to_secondary" {
  provider = aws.primary

  route_table_id            = local.primary_private_route_table_id
  destination_cidr_block    = "172.31.0.0/16"
  vpc_peering_connection_id = aws_vpc_peering_connection.targeting.id

  depends_on = [
    aws_vpc_peering_connection_accepter.targeting
  ]
}

resource "aws_security_group" "targeting_postgres" {
  name        = "targeting-postgres-sg"
  description = "Acesso PostgreSQL somente a partir das subnets privadas do EKS"
  vpc_id      = local.secondary_vpc_id

  ingress {
    description = "EKS private subnet A"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.1.0/24"]
  }

  ingress {
    description = "EKS private subnet B"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.2.0/24"]
  }

  ingress {
    description = "EKS private subnet C"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.3.0/24"]
  }

  egress {
    description = "Saida liberada"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "targeting-postgres-sg"
  })
}
