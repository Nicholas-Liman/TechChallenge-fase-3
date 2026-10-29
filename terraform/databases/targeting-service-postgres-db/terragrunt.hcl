include "root" {
  path = find_in_parent_folders()
}

include "rds" {
  path   = "${get_repo_root()}/terraform/modules/rds/root.hcl"
  expose = true
}

inputs = {
  identifier = "targeting-service-db"
  db_name  = "targeting_db"
  username = "targeting"

  
}
