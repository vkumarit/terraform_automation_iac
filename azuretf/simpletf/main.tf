
## Automate Resource Creation on Azure ##

## Azure Provider source and version
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=4.1.0"
    }
  }
}

###               PHASE-I               ###
# Create Core Resources - Resource Group, Storage Account, Storage Container.
# using azcli and/or env vars for SP terraform azure authentication on ec2.
# Perform init plan apply.

## Configure the Microsoft Azure Provider
provider "azurerm" {
  features {
  #  key_vault {
  #    purge_soft_delete_on_destroy    = true
  #    recover_soft_deleted_key_vaults = true
  #  }
  
  #  resource_provider_registrations = "none" 
  /* 
  This is only required when the User, Service Principal, or Identity running Terraform lacks
  the permissions to register Azure Resource Providers. 
  */
  }
  
  ## A) use this when local/bootstrap, logged in to azure using cli as an User, to authenticate to azure.
  # Not required under automation/SP/pipeline condition.
  #use_cli = true
  
  ## B) Add key value as below required by version >= 4.1.0 for azure authentication.
  #subscription_id = "2b2f02f7-xxxx-47db-xxxx-47d2182721ae"
  /* 
  OR,
  ## Export subscription_id to env vars, it will be auto-read by terraform for authentication,
  $ export ARM_SUBSCRIPTION_ID="<our-subscription-id>" 
  AND, 
  if needed, after exporting id explicitly reference as a variable and call it in provider block,
  #subscription_id  = var.subscription_id   
  */
    
}

# Resource Group

resource "azurerm_resource_group" "mytfstate" {
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

# Storage Account

# Can manually check available name using az cli, then enter here.
resource "azurerm_storage_account" "mytfstate" {
  name                = "prodmyapptfstate01"
  resource_group_name = azurerm_resource_group.mytfstate.name
  location            = azurerm_resource_group.mytfstate.location
  account_tier        = "Standard"
  account_replication_type = "LRS"
  allow_nested_items_to_be_public = false
}

/*
# How to solve the problem of storage account name already taken?
# Avoiding name already taken error by using random_string resource block with conditions #
resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
  keepers = {
    # Recreate storage account only if preferred name becomes available and 
    # random-named storage account is deleted before recreating preferred name storage account.
    preferred_exists = length(data.azurerm_storage_account.preferred)
  }
  #The random_string.keepers prevents unnecessary recreation.
  
}

# random-naming of storage account
resource "azurerm_storage_account" "mytfstate" {
  name                 = "prodmyapptfstate${random_string.suffix.result}"
  resource_group_name  = azurerm_resource_group.mytfstate.name
  location             = azurerm_resource_group.mytfstate.location  # Use RG data/variable
  account_tier         = "Standard"
  account_replication_type = "LRS"
  allow_nested_items_to_be_public = false
  depends_on = [azurerm_resource_group.mytfstate]  # Ensure RG exists first
  
  # Add other config (sku, tags, network_rules, etc.)
}
*/


# Storage Container
resource "azurerm_storage_container" "mytfstate" {
  name                  = "mytfstate"
  storage_account_name = azurerm_storage_account.mytfstate.name
  container_access_type = "private"
  
  depends_on = [azurerm_storage_account.mytfstate]  # ensures storage account creates first
}




###               PHASE-II               ###
# Move terraform statefile to Storage Container.
# After core resource creation configure backened.tf file.
# Perform init after configuring.
/*
# backened.tf 
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "<storage_account_name>"
    container_name       = "tfstate"
    key                  = "terraform.tfstate"
    use_azuread_auth     = true
    use_cli              = true
  }
}
*/

/*
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
*/

# Key Vault
/*
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
*/

/*  
For production save service principal details in azure key vault and pull it using data block and use in provider block.
# can put in secrets.tf
data "azurerm_key_vault_secret" "client_id" {
  name         = "client-id"
  key_vault_id = var.key_vault_id
}

# can put in provider.tf
provider "azurerm" {
  client_id       = data.azurerm_key_vault_secret.client_id.value
  tenant_id       = data.azurerm_key_vault_secret.tenant_id.value
  client_secret   = data.azurerm_key_vault_secret.client_secret.value
  subscription_id = data.azurerm_key_vault_secret.subscription_id.value
  features        = {}
}
*/

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
