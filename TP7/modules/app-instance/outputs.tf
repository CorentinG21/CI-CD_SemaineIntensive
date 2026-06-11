output "ip" {
  value = scaleway_instance_ip.this.address
}

output "id" {
  value = scaleway_instance_server.this.id
}
