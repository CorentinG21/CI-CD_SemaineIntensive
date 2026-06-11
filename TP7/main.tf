module "staging" {
  source        = "./modules/app-instance"
  name          = "staging-iac-ggodon-dauvel"
  instance_type = "DEV1-S"
}

module "prod" {
  source        = "./modules/app-instance"
  name          = "prod-iac-ggodon-dauvel"
  instance_type = "DEV1-S"
}

output "staging_ip" {
  value = module.staging.ip
}

output "prod_ip" {
  value = module.prod.ip
}

resource "scaleway_object_bucket" "tfstate" {
  name   = "tfstate-iac-ggodon-dauvel"
  region = "fr-par"
}
