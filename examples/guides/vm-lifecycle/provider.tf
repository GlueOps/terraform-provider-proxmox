terraform {
  required_providers {
    proxmox = {
      source  = "registry.terraform.io/GlueOps/proxmox"
      version = "0.0.1" # x-release-please-version
    }
  }
}

provider "proxmox" {
  endpoint  = var.virtual_environment_endpoint
  api_token = var.virtual_environment_token
  ssh {
    agent    = true
    username = "terraform"
  }
}
