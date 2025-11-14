/*
Automate Resource Creation on Azure
*/

## Azure Provider source and version being used
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=4.1.0"
    }
  }
}

## Configure the Microsoft Azure Provider

# Use the azuread provider, not azurerm as azurerm cannot fetch Service Principals.
provider "azuread" {
  # (Optional) specify tenant_id, otherwise it uses az login context
}

# retrieve service principal data
data "azuread_service_principal" "az-classic-app" {}

provider "azurerm" {

#  resource_provider_registrations = "none" 
  features {
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }

# For terraform authentication use install azure cli or service principal #
# Service principals
/*
  subscription_id = ""
  client_id = ""
  client_secret = ""
  tenant_id = ""
*/

#  resource_provider_registrations = "none" 
/* 
  This is only required when the User, Service Principal, 
  or Identity running Terraform lacks the permissions to 
  register Azure Resource Providers.
*/

}

# Resource group
resource "azurerm_resource_group" "ample" {
  name     = "myTFResourceGroup"
  location = "Australia East"

  # Custom Timeouts Configuration
  /*
  If an operation times out and fails (indicated by a context: deadline exceeded error in the CLI output), 
  it means the default time was insufficient for the cloud provider's API to complete the task. 
  In that case, you would use the timeouts block to specify a longer duration.
  Terraform immediately stops waiting for the cloud provider's API to return a success or failure status.
  */
  
  #timeouts {
  #  create = "15m"  # Override the default create timeout
  #  read   = "5m"   # The default read timeout
  #  update = "30m"  # Override the default update timeout
  #  delete = "45m"  # Override the default delete timeout (useful if the RG contains many resources)
  #}
}

# VNET w/ cidr 10.0.0.0/16
resource "azurerm_virtual_network" "vnet1" {
  name                = "v1-network"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.ample.location
  resource_group_name = azurerm_resource_group.ample.name
}

# Subnets w/ network security group
# public subnet (10.0.1.0/28) 
resource "azurerm_subnet" "pubnet1" {
  name                 = "pub1-subnet"
  resource_group_name  = azurerm_resource_group.ample
  virtual_network_name = azurerm_virtual_network.vnet1
  address_prefixes     = ["10.0.1.0/28"]
}
# private subnet (10.0.2.0/24) 
resource "azurerm_subnet" "pvtnet" {
  name                 = "pvt1-subnet"
  resource_group_name  = azurerm_resource_group.ample
  virtual_network_name = azurerm_virtual_network.vnet1
  address_prefixes     = ["10.0.2.0/24"]
}

# Key Vault

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "amplekv" {
  name                        = "amplekeyvault"
  location                    = azurerm_resource_group.ample.location
  resource_group_name         = azurerm_resource_group.ample.name
  enabled_for_disk_encryption = true
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false

  sku_name = "standard"

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    key_permissions = [
      "Get",
    ]

    secret_permissions = [
      "Get",
    ]

    storage_permissions = [
      "Get",
    ]
  }
}

# Storage account

# Enable encyption to storage account

# VMs - linux/windows each 
#Linux VM
/*
resource "azurerm_linux_virtual_machine" "example" {
  name                = "example-vm"
  location            = azurerm_resource_group.example.location
  resource_group_name = azurerm_resource_group.example.name
  size                = "Standard_DS1_v2"
  admin_username      = "adminuser"
  network_interface_ids = [azurerm_network_interface.example.id]

  admin_ssh_key {
    username   = "adminuser"
    public_key = file("~/.ssh/id_rsa.pub")
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts"
    version   = "latest"
  }

  # Configure specific timeouts for the VM resource operations
  #timeouts {
    # Increase create timeout from default (often 30 mins) to 45 mins
  #  create = "45m"
    # Ensure delete operation gets enough time if VM cleanup is slow
  #  delete = "30m"
    # Read/Update timeouts remain default
  #}
}
*/

# Deployment of resources in different regions using loop
