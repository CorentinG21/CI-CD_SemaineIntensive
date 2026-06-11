terraform {
  required_providers {
    scaleway = { source = "scaleway/scaleway" }
  }
}

provider "scaleway" {
  zone   = "fr-par-1"
  region = "fr-par"
}
