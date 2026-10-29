include "root" {
  path = find_in_parent_folders()
}

include "rds" {
  path   = "${get_repo_root()}/terraform/modules/rds/root.hcl"
  expose = true
}

inputs = {
  identifier = "flag-service-db"
  db_name    = "flagdb"
  username = "flag_user"

  
}