resource "scaleway_instance_security_group" "this" {
  name                   = "sg-${var.name}"
  inbound_default_policy = "drop"

  dynamic "inbound_rule" {
    for_each = var.ports
    content {
      action = "accept"
      port   = inbound_rule.value
    }
  }
}

resource "scaleway_instance_ip" "this" {
  type = "routed_ipv4"
}

resource "scaleway_instance_server" "this" {
  name              = var.name
  type              = var.instance_type
  image             = "ubuntu_jammy"
  ip_id             = scaleway_instance_ip.this.id
  security_group_id = scaleway_instance_security_group.this.id
}
