
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

## Resource Group

resource "azurerm_resource_group" "prodmyapp" {
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

## Storage Account

# Can manually check available name using az cli, then enter here.
resource "azurerm_storage_account" "prodmyapp" {
  name                = "prodmyapptfstate01"
  resource_group_name = azurerm_resource_group.prodmyapp.name
  location            = azurerm_resource_group.prodmyapp.location
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

## Storage Container

resource "azurerm_storage_container" "prodmyapp" {
  name                  = "mytfstate"
  storage_account_name = azurerm_storage_account.prodmyapp.name
  container_access_type = "private"
  
  depends_on = [azurerm_storage_account.prodmyapp]  # ensures storage account creates first
}




###               PHASE-II               ###
# State Migration & Creation of Key vault to store SP secrets

# After core resource creation configure backened.tf file. Move terraform statefile to Storage Container. 
# Perform init -upgrade after configuring.

# backened.tf 
terraform {
  backend "azurerm" {
    resource_group_name  = "myTFResourceGroup"
    storage_account_name = "prodmyapptfstate01"
    container_name       = "mytfstate"
    key                  = "terraform.tfstate"       # folder/file name/directory inside container
    #use_azuread_auth     = true                      # When using entra id for authentication
    #use_cli              = true  
    # use_cli uses logged-in az cli context for authentication, comment out when switching to pipeline
  }
}

#Get current authenticated principal details automatically from authenticated session via AZ CLI
#data source needs the provider to be configured first, place it in secrets.tf or main.tf after provider block
data "azurerm_client_config" "current" {}        

## Key Vault

resource "azurerm_key_vault" "prodmyapp" {
  name                        = "prodmyappkv"
  location                    = azurerm_resource_group.prodmyapp.location
  resource_group_name         = azurerm_resource_group.prodmyapp.name
  enabled_for_disk_encryption = true
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false
  
  enable_rbac_authorization = true         # enabled RBAC (not using access polices)
  
  sku_name = "standard"

}

# Move Secrets to Key Vault (secrets.tf)
# Get current authenticated principal details automatically from 
# data "azurerm_client_config" "current" {} , mentioned above in code

# Store current SP Client ID (if using SP login) or app ID
resource "azurerm_key_vault_secret" "sp_client_id" {
  name         = "sp-client-id"
  value        = data.azurerm_client_config.current.client_id
  
  #value        = var.arm_client_id             # when exported ARM_CLIENT_ID to env vars
  #value        = data.azurerm_client_config.current.client_id != null ? data.azurerm_client_config.current.client_id : "04b07795-8ddb-461a-bbee-02f9e1bf7b46"  # fallback
  
  key_vault_id = azurerm_key_vault.prodmyapp.id
  depends_on   = [azurerm_key_vault.prodmyapp]
}

# Store current Client Secret 
variable "arm_client_secret" {
  type      = string
  sensitive = true
  default   = ""              # empty string allows env var to populate
  description = "ARM_CLIENT_SECRET from environment variable"
}

resource "azurerm_key_vault_secret" "sp_client_secret" {
  name         = "sp-client-secret"
  value        = var.arm_client_secret          # var when exported ARM_CLIENT_SECRET to EC2/VM env vars
  
  # Secrets as code (version controlled) - Secret rotation 
  # Update ARM_CLIENT_SECRET env var > terraform apply > Key Vault updates automatically.
  
  key_vault_id = azurerm_key_vault.prodmyapp.id
  depends_on   = [azurerm_key_vault.prodmyapp]
}

# Store Tenant ID (auto-detected)
resource "azurerm_key_vault_secret" "sp_tenant_id" {
  name         = "sp-tenant-id"
  value        = data.azurerm_client_config.current.tenant_id
  #value        = var.arm_tenant_id             # When exported ARM_TENANT_ID to env vars
  key_vault_id = azurerm_key_vault.prodmyapp.id
  depends_on   = [azurerm_key_vault.prodmyapp]
}

# Store Subscription ID (auto-detected)  
resource "azurerm_key_vault_secret" "sp_subscription_id" {
  name         = "sp-subscription-id"
  value        = data.azurerm_client_config.current.subscription_id 
  
  #value        = var.arm_subscription_id       
  #When exported ARM_SUBSCRIPTION_ID to env vars both ways - data and var can be used
  
  key_vault_id = azurerm_key_vault.prodmyapp.id
  depends_on   = [azurerm_key_vault.prodmyapp]
}

###               PHASE-III               ###

## User Enable encyption to storage account

# After setting-up pipeline,
# Create key, Storage Account, user_assigned_identity, role assignment, link them together and after
# Grant storage the access to Key Vault using User-Assigned Identity and role definition,
# Link storage account with Link the identity and key 
# (Creating new storage account resource block to avoid confusion between phases and changes in phases)

#RBAC for Terraform key vault created 'prodmyappkv'
resource "azurerm_role_assignment" "tf_kv_admin" {
  scope                = azurerm_key_vault.prodmyapp.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

#A small wait before key creation (prod pipelines only): (Wait for RBAC propagation)
resource "time_sleep" "wait_for_kv_rbac" {
  depends_on      = [azurerm_role_assignment.tf_kv_admin]
  create_duration = "60s"
}

# Create User-Assigned Identity: Grant access to Key Vault.
resource "azurerm_user_assigned_identity" "prodmyapp_sa_identity" {
  name                = "my-storage-identity"
  location            = azurerm_resource_group.prodmyapp.location
  resource_group_name = azurerm_resource_group.prodmyapp.name
}

resource "azurerm_role_assignment" "storage_kv_crypto" {
  scope                = azurerm_key_vault.prodmyapp.id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_user_assigned_identity.prodmyapp_sa_identity.principal_id
}

#Create Storage Account (CMK): Link the identity and key.
resource "azurerm_storage_account" "prodmyapp_cmk" {
  name                     = "prodmyappsacmk01"
  location                 = azurerm_resource_group.prodmyapp.location
  resource_group_name      = azurerm_resource_group.prodmyapp.name
  account_tier             = "Standard"
  account_replication_type = "LRS"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.prodmyapp_sa_identity.id]
  }
  
  #lifecycle {
  #  ignore_changes = [
  #    customer_managed_key
  #  ]
  #}
}

# Create key with explicit rotation policy

resource "azurerm_key_vault_key" "prodmyapp_key" {
  name         = "my-storage-cmk"
  key_vault_id = azurerm_key_vault.prodmyapp.id
  key_type     = "RSA"
  key_size     = 2048

  key_opts = [
    "encrypt",
    "decrypt",
    "wrapKey",
    "unwrapKey"
  ]

  #rotation_policy {
  #  expire_after         = "P90D"
  #  notify_before_expiry = "P30D"
#
  #  automatic {
  #    time_before_expiry = "P30D"
  #  }
  #}

  depends_on = [
    azurerm_key_vault.prodmyapp,
    time_sleep.wait_for_kv_rbac
  ]
}


/*
resource "azurerm_storage_account_customer_managed_key" "prodmyapp_sa_cmk" {
  storage_account_id = azurerm_storage_account.prodmyapp_cmk.id
  key_vault_id       = azurerm_key_vault.prodmyapp.id
  key_name          = azurerm_key_vault_key.prodmyapp_key.name
  key_version       = azurerm_key_vault_key.prodmyapp_key.version

  depends_on = [
    azurerm_role_assignment.storage_kv_crypto,
    azurerm_key_vault_key.prodmyapp_key
  ]
}
*/

/*
## VNET w/ cidr 10.0.0.0/16
resource "azurerm_virtual_network" "vnet1" {
  name                = "v1-network"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.ample.location
  resource_group_name = azurerm_resource_group.ample.name
}

## Subnets w/ network security group
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

-----------------
azurerm_resource_group: To contain your network resources.
azurerm_virtual_network: Defines the VNet and its overall address space.
azurerm_subnet: Creates individual subnets (public/private) within the VNet, specifying their address prefixes.
azurerm_public_ip: For resources needing direct internet access (e.g., VMs in public subnet).
azurerm_network_security_group: Applies firewall rules to control traffic.
azurerm_network_interface: Attaches network settings (IP, NSG) to a VM.
azurerm_network_interface_security_group_association: Links NSGs to network interfaces
-----------------
*/



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
