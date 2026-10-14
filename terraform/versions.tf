terraform {
  required_version = ">= 1.10"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.0" }
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }

  # Configuração parcial: bucket/key/region chegam via -backend-config (scripts/tf-init.sh)
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.tags
  }
}

# Autenticação via variáveis ARM_* (no pipeline: ARM_USE_OIDC + ARM_CLIENT_ID/TENANT_ID/SUBSCRIPTION_ID)
provider "azurerm" {
  features {}
}
