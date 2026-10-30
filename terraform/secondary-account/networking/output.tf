output "private_subnet_ids" {
  description = "Subnets privadas para o RDS Targeting"
  value = [
    aws_subnet.targeting_private_a.id,
    aws_subnet.targeting_private_b.id
  ]
}

output "targeting_security_group_id" {
  description = "Security Group do PostgreSQL Targeting"
  value       = aws_security_group.targeting_postgres.id
}

output "vpc_peering_connection_id" {
  description = "ID da conexão VPC Peering"
  value       = aws_vpc_peering_connection.targeting.id
}

output "private_route_table_id" {
  description = "Route table privada da conta secundária"
  value       = aws_route_table.targeting_private.id
}
