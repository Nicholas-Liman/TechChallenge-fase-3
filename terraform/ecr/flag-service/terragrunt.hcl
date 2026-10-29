include "root" {
  path = find_in_parent_folders()
}

include "ecr" {
  path   = "${get_repo_root()}/terraform/modules/ecr/root.hcl"
  expose = true
}

inputs = {
  repository_name = "flag-image"
}
