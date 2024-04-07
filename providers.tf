terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.1-rc1"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.4"
    }

    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }

    acme = {
      source  = "vancluever/acme"
      version = "~> 2.21"
    }

    gpg = {
      source  = "olivr/gpg"
      version = "~> 0.2"
    }
  }
}

