include "root" {
  path = find_in_parent_folders()
}

include "rds" {
  path   = "${get_repo_root()}/terraform/modules/rds/root.hcl"
  expose = true
}

inputs = {
  identifier = "auth-service-db"
  db_name  = "auth_db"
  username = "auth"
  port     = "5432"

}
