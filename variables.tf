variable "proxmox_user" {}
variable "proxmox_password" {}
variable "proxmox_addr" {}

variable "cluster_endpoint" {}

variable "initial_users" {
  type = list(string)
}

variable "auth0_domain" {
  type = string
}

variable "auth0_client_id" {
  type = string
}

variable "omni_common_name" {
  type = string
}

variable "acme_email" {
  type = string
}

variable "acme_eab_hmac" {}

variable "acme_eab_kid" {}

variable "vm_hostname" {
  type = string
}

variable "proxmox_target_node" {
  type = string
}

variable "vm_mac_addr" {
  type = string
}

variable "vm_memory" {
  type = string
}
variable "vm_cores" {
  type = string
}
variable "vm_disk_storage" {
  type = string
}

variable "vm_disk_size" {
  type = string
}

variable "vm_gw" {}

variable "vm_ip" {
  type = string
}

variable "proxmox_iso" {
  type = string
}

