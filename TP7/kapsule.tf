variable "k8s_version" {
  description = "Version Kapsule supportée — listez-les avec : scw k8s version list"
  default     = "1.35.3"
}

resource "scaleway_vpc_private_network" "kapsule" {
  name = "pn-kapsule-iac-ggodon-dauvel"
}

resource "scaleway_k8s_cluster" "main" {
  name                        = "kapsule-iac-ggodon-dauvel"
  version                     = var.k8s_version
  cni                         = "cilium"
  delete_additional_resources = true
  private_network_id          = scaleway_vpc_private_network.kapsule.id
}

resource "scaleway_k8s_pool" "default" {
  cluster_id = scaleway_k8s_cluster.main.id
  name       = "default"
  node_type  = "DEV1-M"
  size       = 2
}

output "kubeconfig" {
  value     = scaleway_k8s_cluster.main.kubeconfig[0].config_file
  sensitive = true
}
