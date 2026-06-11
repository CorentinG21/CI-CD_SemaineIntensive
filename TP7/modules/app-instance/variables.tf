variable "name" {
  description = "Nom de l'instance"
  type        = string
}

variable "instance_type" {
  description = "Type d'instance Scaleway"
  type        = string
  default     = "DEV1-S"
}

variable "ports" {
  description = "Ports ouverts en entrée"
  type        = list(number)
  default     = [22, 80, 443]
}
