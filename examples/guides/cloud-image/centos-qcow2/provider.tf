terraform {
  required_providers {
    proxmox = {
      source  = "registry.terraform.io/GlueOps/proxmox"
      version = "0.1.0" # x-release-please-version
    }
  }
}

provider "proxmox" {
  endpoint  = var.virtual_environment_endpoint
  api_token = var.virtual_environment_token
  # SSH configuration is not required for this example
}
