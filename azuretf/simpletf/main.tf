
## Automate Resource Creation on Azure ##

## Azure Provider source and version
terraform {
  required_providers {

    # azure resource manager 
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=4.1.0"
    }

    # Microsoft Entra ID - formerly, Microsoft Azure Active Directory(AD)
    # Cloud-based identity and access management (IAM) solution.
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.50"
    }

    # TLS provides utilities for working with Transport Layer Security keys and certificates.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }

    # Local provider is used to manage local resources, such as files.
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}


###               PHASE-I               ###
# Create Core Resources - Resource Group, User-Assigned Identity, Storage Account (CMK), Storage Container.
# using azcli and/or env vars for SP terraform azure authentication on ec2.
# Perform init plan apply.

# Adds run_id to every resource automatically
variable "run_id" {
  description = "Pipeline run identifier"
  type        = string
  default     = ""

  #default     = "manual" 
  # a fallback value for local runs when variable from CLI, environment variable, or tfvars isn't recieved,
  # helps when someone runs Terraform locally. 
  # Prevents error - `The argument "run_id" is required but no definition was found.`

  #  validation {
  #    condition     = length(local.effective_run_id) > 0
  #    error_message = "run_id must be provided in pipeline."
  #  }

}

variable "deployment_id" {
  type    = string
  default = "prodmyapp"
}

variable "environment" {
  description = "Environment for pipeline"
  type        = string
}

# Tagging Resources
locals {
  effective_run_id = (
    var.run_id != "" ?
    var.run_id :
    "local-${timestamp()}-${terraform.workspace}"
  )

  common_tags = {
    managed_by      = "terraform"
    deployment_id   = var.deployment_id
    environment     = var.environment
    creation_run_id = local.effective_run_id
    creation_time   = timestamp() 
  }
}

output "debug_tags" {
  value = local.common_tags
}

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
  subscription_id = "2b2f02f7-dde2-47db-974c-47d2182721ae"
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

  #timeouts {
  #  create = "15m"  # Override the default create timeout
  #  read   = "5m"   # The default read timeout
  #  update = "30m"  # Override the default update timeout
  #  delete = "45m"  # Override the default delete timeout (useful if the RG contains many resources)
  #}

  tags = merge(local.common_tags, {
    Name = "rg-prodmyapp"
  })

  lifecycle {
    ignore_changes = [
      tags["creation_run_id"],
      tags["creation_time"]
    ]
  }
}

## DENY Policy for Tagging at Resource Group (`policy-deny-tags-rg.tf`)

resource "azurerm_policy_definition" "require_managed_by" {
  name         = "require-managed-by-tag"
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "Require managed_by tag"

  policy_rule = jsonencode({
    if = {
      field  = "tags['managed_by']"
      exists = "false"
    }
    then = {
      effect = "deny"
    }
  })
}

resource "azurerm_policy_definition" "require_deployment_id" {
  name         = "require-deployment-id-tag"
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "Require deployment_id tag"

  policy_rule = jsonencode({
    if = {
      field  = "tags['deployment_id']"
      exists = "false"
    }
    then = {
      effect = "deny"
    }
  })
}

resource "azurerm_policy_definition" "require_environment" {
  name         = "require-environment-tag"
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "Require environment tag"

  policy_rule = jsonencode({
    if = {
      field  = "tags['environment']"
      exists = "false"
    }
    then = {
      effect = "deny"
    }
  })
}

# Assign policies to Resource Group

resource "azurerm_resource_group_policy_assignment" "rg_managed_by" {
  name                 = "rg-require-managed-by"
  resource_group_id    = azurerm_resource_group.prodmyapp.id
  policy_definition_id = azurerm_policy_definition.require_managed_by.id
}

resource "azurerm_resource_group_policy_assignment" "rg_deployment_id" {
  name                 = "rg-require-deployment-id"
  resource_group_id    = azurerm_resource_group.prodmyapp.id
  policy_definition_id = azurerm_policy_definition.require_deployment_id.id
}

resource "azurerm_resource_group_policy_assignment" "rg_environment" {
  name                 = "rg-require-environment"
  resource_group_id    = azurerm_resource_group.prodmyapp.id
  policy_definition_id = azurerm_policy_definition.require_environment.id
}

## Storage Account
/*
# Create User-Assigned Identity: Grant access to Key Vault.
resource "azurerm_user_assigned_identity" "prodmyapp_sa_identity" {
  name                = "my-storage-identity"
  location            = azurerm_resource_group.prodmyapp.location
  resource_group_name = azurerm_resource_group.prodmyapp.name

  tags = merge(local.common_tags, {
    Name = "identity-storage"
  })

  lifecycle {
    ignore_changes = [
      tags["creation_run_id"],
      tags["creation_time"]
    ]    
  }
  # Add lifecycle block from the beginning, 
  # when creating a new resource.
}

# Can manually check available name using az cli, then enter here.
# Create Storage Account (CMK): Set backened then Link the identity and key later.
resource "azurerm_storage_account" "prodmyapp" {
  name                     = "prodmyappsacmk01"
  location                 = azurerm_resource_group.prodmyapp.location
  resource_group_name      = azurerm_resource_group.prodmyapp.name
  account_tier             = "Standard"
  account_replication_type = "LRS"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.prodmyapp_sa_identity.id]
  }

  tags = merge(local.common_tags, {
    Name = "st-tfstate-cmk"
  })

  lifecycle {
    ignore_changes = [
      customer_managed_key,
      tags["creation_run_id"],
      tags["creation_time"]
    ]
  }
}

## Storage Container

resource "azurerm_storage_container" "prodmyapp" {
  name                  = "mytfstate"
  storage_account_name  = azurerm_storage_account.prodmyapp.name
  container_access_type = "private"
  depends_on            = [azurerm_storage_account.prodmyapp] # ensures storage account creates first
}

## Backend Access Role
data "azuread_service_principal" "prodmyapp" {
  display_name = "az-classic-app"
  #Or,
  #object_id      = "52f32d06-bfbe-464b-bc9b-77ff908d68ef"
  #Or,
  #application_id = "52f32d06-bfbe-464b-bc9b-77ff908d68ef"  (Client ID)
}

resource "azurerm_role_assignment" "terraform_backend_storage_access" {
  scope                = azurerm_storage_container.prodmyapp.resource_manager_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azuread_service_principal.prodmyapp.object_id

  depends_on = [
    azurerm_storage_account.prodmyapp,
    azurerm_storage_container.prodmyapp
  ]

  #lifecycle {
  #  prevent_destroy = true
  #}
}


###               PHASE-II               ###
# State Migration & Creation of Key vault to store SP secrets

# After core resource creation configure backened.tf file. Move terraform statefile to Storage Container. 
# Perform init -upgrade after configuring.
/*
# backened.tf 
terraform {
  backend "azurerm" {
    resource_group_name  = "myTFResourceGroup"
    storage_account_name = "prodmyappsacmk01"
    container_name       = "mytfstate"

    key = "prod/terraform.tfstate" # folder/file name/directory inside container

    #key = "${var.environment}/terraform.tfstate"    
    #when keeping separate statefile for each environment

    #use_azuread_auth     = true                      # When want to use entra id for authentication
    #use_cli = true
    # use_cli uses logged-in az cli context for authentication, comment out when switching to pipeline
  }
}

#Get current authenticated principal details automatically from authenticated session via AZ CLI
#data source needs the provider to be configured first, place it in secrets.tf or main.tf after provider block
data "azurerm_client_config" "current" {}

## Key Vault
/*
resource "azurerm_key_vault" "prodmyapp" {
  name                        = "prodmyappkv"
  location                    = azurerm_resource_group.prodmyapp.location
  resource_group_name         = azurerm_resource_group.prodmyapp.name
  enabled_for_disk_encryption = true
  tenant_id                   = data.azurerm_client_config.current.tenant_id

  soft_delete_retention_days = 7
  purge_protection_enabled   = true # for Encryption of storage accounts

  enable_rbac_authorization = true # enabled RBAC (not using access polices)

  sku_name = "standard"

  tags = merge(local.common_tags, {
    Name = "kv-prodmyapp"
  })

  lifecycle {
    ignore_changes = [
      tags["creation_run_id"],
      tags["creation_time"]
    ]
  }

}

###               PHASE-III               ###
/*
## User Enable encyption to storage account

# After setting-up pipeline,
# Create key, role assignment, link them together and after
# Grant storage the access to Key Vault using User-Assigned Identity and role definition,
# Link storage account with Link the identity and key 

#RBAC for Terraform key vault created 'prodmyappkv'
resource "azurerm_role_assignment" "tf_kv_admin" {
  scope                = azurerm_key_vault.prodmyapp.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

#A small wait before key creation (prod pipelines only): (Wait for RBAC propagation)
resource "time_sleep" "wait_for_kv_rbac" {
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.tf_kv_admin]
}

resource "azurerm_role_assignment" "storage_kv_crypto" {
  scope                = azurerm_key_vault.prodmyapp.id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_user_assigned_identity.prodmyapp_sa_identity.principal_id
}

# Helps with permissions for viewing the keys via dashboard
/*
resource "azurerm_role_assignment" "human_kv_crypto_officer" {
  scope                = azurerm_key_vault.prodmyapp.id
  role_definition_name = "Key Vault Crypto Officer"
  principal_id         = "USER_OBJECT_ID_HERE"        
  # Hardcode object IDs of known humans or service accounts. 
  # Like DevOps lead or security engineer’s object IDs. 
}
*/

# Create key with explicit rotation policy
/*
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

  #  automatic {
  #    time_before_expiry = "P30D"
  #  }
  #}

  depends_on = [
    azurerm_key_vault.prodmyapp,
    time_sleep.wait_for_kv_rbac
  ]

  tags = merge(local.common_tags, {
    Name = "kv-key-cmk_prodmyapp"
  })

  lifecycle {
    ignore_changes = [
      tags["creation_run_id"],
      tags["creation_time"]
    ]
  }
}

resource "azurerm_storage_account_customer_managed_key" "prodmyapp_sa_cmk" {
  storage_account_id = azurerm_storage_account.prodmyapp.id
  key_vault_id       = azurerm_key_vault.prodmyapp.id
  key_name           = azurerm_key_vault_key.prodmyapp_key.name
  key_version        = azurerm_key_vault_key.prodmyapp_key.version

  user_assigned_identity_id = azurerm_user_assigned_identity.prodmyapp_sa_identity.id

  depends_on = [
    azurerm_role_assignment.storage_kv_crypto,
    azurerm_key_vault_key.prodmyapp_key,
    azurerm_storage_account.prodmyapp
  ]
}

# Move Secrets to Key Vault (secrets.tf)
# Secrets as code (version controlled) - Secret rotation 
# Update ARM_CLIENT_SECRET env var > terraform apply > Key Vault updates automatically.

# Use Terraform only to create Key Vault. 
# Immediately use Azure CLI to inject secret.
# Avoid storing secret in state

# Get current authenticated principal details automatically from 
# data "azurerm_client_config" "current" {} , mentioned above in code

# Store current SP Client ID (if using SP login) or app ID
resource "azurerm_key_vault_secret" "sp_client_id" {
  name  = "sp-client-id"
  value = data.azurerm_client_config.current.client_id

  #value        = var.arm_client_id             # when exported ARM_CLIENT_ID to env vars

  key_vault_id = azurerm_key_vault.prodmyapp.id
  depends_on   = [azurerm_key_vault.prodmyapp]
}

# Store Tenant ID (auto-detected)
resource "azurerm_key_vault_secret" "sp_tenant_id" {
  name  = "sp-tenant-id"
  value = data.azurerm_client_config.current.tenant_id
  #value        = var.arm_tenant_id             # When exported ARM_TENANT_ID to env vars
  key_vault_id = azurerm_key_vault.prodmyapp.id
  depends_on   = [azurerm_key_vault.prodmyapp]
}

# Store Subscription ID (auto-detected)  
resource "azurerm_key_vault_secret" "sp_subscription_id" {
  name  = "sp-subscription-id"
  value = data.azurerm_client_config.current.subscription_id

  #value        = var.arm_subscription_id       
  #When exported ARM_SUBSCRIPTION_ID to env vars both ways - data and var can be used

  key_vault_id = azurerm_key_vault.prodmyapp.id
  depends_on   = [azurerm_key_vault.prodmyapp]
}


# Store current Client Secret 
variable "arm_client_secret" {
  type        = string
  sensitive   = true
  default     = "" # empty string allows env var to populate (takes variable from environment),
  description = "ARM_CLIENT_SECRET from environment variable"

  #validation {
  #  condition = (
  #    var.arm_client_secret == "" ||
  #    length(var.arm_client_secret) > 20
  #  )
  #  error_message = "Client secret appears invalid."
  #}
}

resource "azurerm_key_vault_secret" "sp_client_secret" {
  name  = "sp-client-secret"
  value = var.arm_client_secret # var when exported ARM_CLIENT_SECRET to EC2/VM env vars
  #value = "placeholder"

  # Secrets as code (version controlled) - Secret rotation 
  # Update ARM_CLIENT_SECRET env var > terraform apply > Key Vault updates automatically.

  key_vault_id = azurerm_key_vault.prodmyapp.id

  lifecycle {
    ignore_changes = [] # Allow rotation, available value will be taken

    #ignore_changes = [value]
    #Never update the secret after first creation, freeze secret forever
    #Used when not managing secret rotation using terraform, az cli used for secret rotation

    #prevent_destroy = true  
    #Allows rotation, prevents accidental deletion
    #Used not managing secret rotation using terraform, az cli used for secret rotation
  }

  depends_on = [azurerm_key_vault.prodmyapp]
}

# Store GitHub Token 
variable "github_token" {
  type      = string
  sensitive = true

  default = ""
  # empty string allows env var to populate (takes variable from environment),
  # export value as `export TF_VAR_github_token=ghp_k7pt3nlRS6xxxxZFaYjcSjJpL02CN1rCmwl`

  description = "GitHub token for Key Vault"

  validation {
    condition = (
      var.github_token == "" ||
      length(var.github_token) > 20
    )
    error_message = "GitHub token appears invalid."
  }
}

resource "azurerm_key_vault_secret" "github_token" {
  name  = "githubtoken"
  value = var.github_token # var when exported TF_VAR_github_token to EC2/VM env vars

  #value = "placeholder"
  #Used when not managing secret rotation using terraform, az cli used for secret rotation

  key_vault_id = azurerm_key_vault.prodmyapp.id

  lifecycle {
    ignore_changes = [] # Allow rotation, available value will be taken

    #ignore_changes = [value]
    #Never update the secret after first creation, freeze secret forever
    #Used when not managing secret rotation using terraform, az cli used for secret rotation

    #prevent_destroy = true  
    #Allows rotation, prevents accidental deletion
    #Used not managing secret rotation using terraform, az cli used for secret rotation
  }

  depends_on = [azurerm_key_vault.prodmyapp]
}


###               PHASE-IV               ###

/*
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

## Virtual Network w/ cidr 10.0.0.0/16 and Subnets
/*
# Network Security Group (All allowed for testing)
resource "azurerm_network_security_group" "prodmyapp_sg_linux" {
  name                = "open-security-group"
  location            = azurerm_resource_group.prodmyapp.location
  resource_group_name = azurerm_resource_group.prodmyapp.name

  security_rule {
    name                   = "AllowAllInbound"
    priority               = 100 # ranges 100-4096; lower process first (i.e, 100 before 101)
    direction              = "Inbound"
    access                 = "Allow"
    protocol               = "*"  # Tcp, Udp, Icmp, Esp, Ah
    source_port_range      = "*"  # ports ranges 0-65535, `*` equivalent to "0-65535"
    destination_port_range = "22" # `22` for SSH (Only Inbound)

    source_address_prefix = "*"
    # "AzureCloud" (Azure DevOps Microsoft-hosted agent) / "*" (`*` equivalent to  "0.0.0.0/0") 
    # Or, "<AGENT_PUBLIC_IP>/32"  # strongly recommended for Azure VM, EC2, on-prem VM with static IP
    # Best: Bastion - No public IP , SSH NSG rule, 

    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowAllOutbound"
    priority                   = 101 # ranges 100-4096; lower process first (i.e, 100 before 101)
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*" # Tcp, Udp, Icmp, Esp, Ah
    source_port_range          = "*" # ports ranges 0-65535, `*` equivalent to "0-65535"
    destination_port_range     = "*"
    source_address_prefix      = "*" # `*` equivalent to  "0.0.0.0/0"
    destination_address_prefix = "*"
  }

  tags = merge(local.common_tags, {
    Name = "nsg-open_prodmyapp"
  })

  lifecycle {
    ignore_changes = [
      tags["creation_run_id"],
      tags["creation_time"]
    ]
  }
}

# VNET
resource "azurerm_virtual_network" "prodmyapp_vnet" {
  name                = "prodmyapp_virtual-network"
  location            = azurerm_resource_group.prodmyapp.location
  resource_group_name = azurerm_resource_group.prodmyapp.name

  address_space = ["10.0.0.0/16"]

  # When want to delete subnets created using inline subnets code like below we do `subnet=[]`
  #subnet {
  #  name           = "prodmyapp_pub_subnet1"
  #  address_prefixes = ["10.0.1.0/28"]
  #}

  # CRITICAL: Explicitly empty to force deletion
  #subnet = []

  tags = merge(local.common_tags, {
    Name = "vnet-prodmyapp"
  })

  lifecycle {
    ignore_changes = [
      tags["creation_run_id"],
      tags["creation_time"]
    ]
  }
}

# Subnets w/ Network Security Group

# public subnet (10.0.1.0/28) 
resource "azurerm_subnet" "pub_subnet" {
  name                 = "prodmyapp_pub_subnet1"
  resource_group_name  = azurerm_resource_group.prodmyapp.name
  virtual_network_name = azurerm_virtual_network.prodmyapp_vnet.name
  address_prefixes     = ["10.0.1.0/28"]
  
  tags = merge(local.common_tags, {
    Name = "pub_subnet_prodmyapp"
  })

  lifecycle {
    ignore_changes = [
      tags["creation_run_id"],
      tags["creation_time"]
    ]
  }
}

# private subnet (10.0.2.0/24) 
resource "azurerm_subnet" "pvt_subnet" {
  name                 = "prodmyapp_pvt_subnet2"
  resource_group_name  = azurerm_resource_group.prodmyapp.name
  virtual_network_name = azurerm_virtual_network.prodmyapp_vnet.name
  address_prefixes     = ["10.0.2.0/24"]
  
  tags = merge(local.common_tags, {
    Name = "pvt_subnet_prodmyapp"
  })

  lifecycle {
    ignore_changes = [
      tags["creation_run_id"],
      tags["creation_time"]
    ]
  }
}

# Separate Subnet NSG associations 
# recommended over inline subnet.security_group, prevents recreation issues
# First implement vnet and subnet then implement association

resource "azurerm_subnet_network_security_group_association" "pub_subnet_nsg" {
  subnet_id                 = azurerm_subnet.pub_subnet.id
  network_security_group_id = azurerm_network_security_group.prodmyapp_sg_linux.id
}

resource "azurerm_subnet_network_security_group_association" "pvt_subnet_nsg" {
  subnet_id                 = azurerm_subnet.pvt_subnet.id
  network_security_group_id = azurerm_network_security_group.prodmyapp_sg_linux.id
}

# Public IP (used to expose VMs' to internet)
resource "azurerm_public_ip" "prodmyapp_pub_ips" {
  name                = "prodmyapp_public_ip1"
  resource_group_name = azurerm_resource_group.prodmyapp.name
  location            = azurerm_resource_group.prodmyapp.location

  allocation_method = "Static"
  # Static - User supplied IP address will be used or 
  # Dynamic - allotted after IP attached to a VM/Resource. An IP is automatically assigned during creation.
  # Can use data block `azurerm_public_ip` to obtain IP Address also.

  tags = merge(local.common_tags, {
    Name = "pip-prodmyapp"
  })

  lifecycle {
    ignore_changes = [
      tags["creation_run_id"],
      tags["creation_time"]
    ]
  }
}

# Output the public IP for SSH login to VM it is atteched to.
output "vm_public_ip" {
  value = azurerm_public_ip.prodmyapp_pub_ips.ip_address
}

# Output "vm_public_ip" - "20.5.121.162"

## Network Interface (NIC) (NSG & IP + VM)
resource "azurerm_network_interface" "prodmyapp_nic_linux" {
  name                = "prodmyapp-nic1"
  location            = azurerm_resource_group.prodmyapp.location
  resource_group_name = azurerm_resource_group.prodmyapp.name

  # there can be multiple ip_configuration blocks
  ip_configuration {
    name      = "ip_config_1"
    subnet_id = azurerm_subnet.pub_subnet.id #public for internet facing VMs

    #private_ip_address_version    = "IPv4"                # IPv4/IPv6
    private_ip_address_allocation = "Dynamic" # Static/Dynamic
    #private_ip_address            = [""]                  # Static IP Address

    # Public IP Address to associate w/ interface
    public_ip_address_id = azurerm_public_ip.prodmyapp_pub_ips.id

    #primary                      = true                  
    # true if multiple blocks and this is first/primary ip_configurations 
  }

  depends_on = [
    azurerm_public_ip.prodmyapp_pub_ips
  ]

  tags = merge(local.common_tags, {
    Name = "nic-prodmyapp"
  })

  lifecycle {
    ignore_changes = [
      tags["creation_run_id"],
      tags["creation_time"]
    ]
  }
}

# Network Interface & Security Group Association
resource "azurerm_network_interface_security_group_association" "nic_nsg_assn_linux" {
  network_interface_id      = azurerm_network_interface.prodmyapp_nic_linux.id
  network_security_group_id = azurerm_network_security_group.prodmyapp_sg_linux.id
}


###               PHASE-V               ###


## VM - linux (Small scale production-grade)

/*
--------------------------------------------
SSH Key generartion, create `tls_private_key`.
Writing private key to local file (.pem).
Writing public key to local file (.pub).
Create variables `environment` and `size_alias` for VM. 
Define locals vm_sizes, locals vm_images based on dev, test, prod.
Create `null_resource` to `validate_vm_size`.
Create a Disk Encryption Set resource and link it to Key Vault CMK, then attach it to the VM OS disk 
with key `disk_encryption_set_id` inside OS disk block in VM.
Assign `Key Vault Crypto Service Encryption User` role to disk encryption set identity `principal_id`.
Create linux VM resource using all above and other keys and values.
--------------------------------------------
*/

## SSH Key Generation (tls provider block required)
/*
# Creating Key
resource "tls_private_key" "vm_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096 # 2048 Min. required, 4096 for better security (production)
}

# Writing for SSH purpose
#> Write the private key to a local file with secure permissions
resource "local_sensitive_file" "private_key_pem" {
  filename             = pathexpand("~/.ssh/prodmyapp_vm1.pem")
  content              = tls_private_key.vm_ssh.private_key_pem
  file_permission      = "0400" # Owner: read only (4) Group: no access  (0) Others: no access (0)
  directory_permission = "0700"
}

#> Write the public key to a local file (standard permissions)
resource "local_file" "public_key_openssh" {
  filename        = pathexpand("~/.ssh/prodmyapp_vm1.pub")
  content         = tls_private_key.vm_ssh.public_key_openssh
  file_permission = "0644" # Owner: read+write (6) Group: read only  (4) Others: read only (4)
}

# Define variable for VM selection
# Scalable approach avoids repeating validation lists
# Will create for dev environment & small size mentioned below in code 
variable "environment" {
  description = "Deployment environment"
  type        = string

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "Environment must be dev, test, or prod."
  }
}

variable "size_alias" {
  description = "Logical VM size"
  type        = string

  #validation {
  #  condition = contains(
  #    keys(local.vm_sizes[var.environment]),
  #    var.size_alias
  #  )
  #  error_message = "Invalid size_alias for selected environment."
  #}
}

# VM size selection
locals {
  vm_sizes = {
    dev = {
      small  = "Standard_B2s"    # cpu - 2, ram - 4, storage - data-2, local-4
      medium = "Standard_D2s_v3" # cpu - 2, ram - 8, storage - data-4/local-16
      large  = "Standard_D4s_v3" # cpu - 4, ram - 16, storage - data-8/local-32
    }
    # dev - cheap / burstable allowed

    test = {
      small  = "Standard_B2s"
      medium = "Standard_D4s_v3"
      large  = "Standard_D8s_v3" # cpu - 8, ram - 32, storage - data-16/local-64
    }
    #test - closer to prod

    prod = {
      small = "Standard_B2s" # cpu - 2, ram - 4, storage - data-2, local-4
      #small  = "Standard_D4s_v6" # cpu - 4, ram - 16, storage - data-12/local-N/A
      medium = "Standard_D8s_v6" # cpu - 8, ram - 32, storage - data-24/local-16
      large  = "Standard_D16s_v6"
    }
    # prod - production-grade SKUs only
  }

  # validation helper
  valid_size_alias = contains(
    keys(local.vm_sizes[var.environment]),
    var.size_alias
  )

  # final selected VM size
  selected_vm_size = local.vm_sizes[var.environment][var.size_alias]
}

# Validation Resource (to help validate size)
resource "null_resource" "validate_vm_size" {

  lifecycle {
    precondition {
      condition     = local.valid_size_alias
      error_message = "Invalid size_alias '${var.size_alias}' for environment '${var.environment}'."
    }
  }
}

# For creating VM, when we can't pass environment and size_alias like in below cmd,
# $ terraform apply -var="environment=dev" -var="size_alias=xlarge"
# We will export them as Environment variables (TF_VAR_*), most common in pipelines. Or,
# Use TF_VAR_environment and TF_VAR_size_alias pipeline variables in pipeline yaml file

# VM image selection w/ environment
locals {
  vm_images = {
    dev = {
      linux = {
        publisher = "cognosys"
        offer     = "centos-8-3-free"
        sku       = "centos-8-3-free"
        version   = "latest"
      }
      windows = {
        publisher = "MicrosoftWindowsServer"
        offer     = "WindowsServer"
        sku       = "2019-Datacenter"
        version   = "latest"
      }
    }
    # Dev > latest

    test = {
      linux = {
        publisher = "Canonical"
        offer     = "0001-com-ubuntu-server-focal"
        sku       = "20_04-lts"
        version   = "20.04.202401220"
      }
      windows = {
        publisher = "MicrosoftWindowsServer"
        offer     = "WindowsServer"
        sku       = "2019-Datacenter"
        version   = "17763.8511.260305"
      }
    }
    # Test > pinned

    prod = {
      linux = {
        publisher = "cognosys"
        offer     = "centos-8-3-free"
        sku       = "centos-8-3-free"
        version   = "1.2019.0810"
      }
      windows = {
        publisher = "MicrosoftWindowsServer"
        offer     = "WindowsServer"
        sku       = "2019-Datacenter"
        version   = "17763.8511.260305"
      }
    }
    # Prod > pinned and controlled
  }
}

# Azure Disk Encryption (CMK-backed disks) (Prod VMs) 
# (Optional to `encryption_at_host_enabled` at needs to be enabled at subscription level)
# 1) Create a Disk Encryption Set and Link it to Key Vault CMK

resource "azurerm_disk_encryption_set" "prod_des" {
  name                = "prod-des"
  resource_group_name = azurerm_resource_group.prodmyapp.name
  location            = azurerm_resource_group.prodmyapp.location
  key_vault_key_id    = azurerm_key_vault_key.prodmyapp_key.id

  identity {
    type = "SystemAssigned"
  }

  tags = merge(local.common_tags, {
    Name = "des-prodmyapp"
  })

  lifecycle {
    ignore_changes = [
      tags["creation_run_id"],
      tags["creation_time"]
    ]
  }
}

# and,

# 2) Attach it to the VM OS disk
#os_disk {
#  ...
#  disk_encryption_set_id = azurerm_disk_encryption_set.prod_des.id
#}

#Disk Encryption Set identity must be granted an RBAC role on the Key Vault.
resource "azurerm_role_assignment" "des_kv_crypto" {
  scope                = azurerm_key_vault.prodmyapp.id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_disk_encryption_set.prod_des.identity[0].principal_id
}

#FLOW: Create Key Vault (RBAC enabled) > Create Key > Create Disk Encryption Set (SystemAssigned identity) >
# > Assign DES identity to KV role > Wait 60 seconds > Create VM using DES

#Flow looks like, VM > OS Disk > Disk Encryption Set > Key Vault Key
# So needs `Key Vault Crypto Service Encryption User` role

resource "time_sleep" "wait_for_des_rbac" {
  create_duration = "180s"
  depends_on = [
    azurerm_role_assignment.des_kv_crypto
  ]
}

# Creating VM by exporting variables ENVIRONMENT dev and SIZE_ALIAS small from pipeline yaml file.

resource "azurerm_linux_virtual_machine" "linux_vm" {
  name = "linux_vm_01"
  # use no underscores, special characters, spaces /or use `computer_name`

  computer_name       = "linuxvmdev01"
  location            = azurerm_resource_group.prodmyapp.location
  resource_group_name = azurerm_resource_group.prodmyapp.name
  #size                = "Standard_DS1_v2"
  size           = local.selected_vm_size
  admin_username = "adminuser"

  admin_ssh_key {
    username   = "adminuser"
    public_key = tls_private_key.vm_ssh.public_key_openssh
  }

  network_interface_ids = [azurerm_network_interface.prodmyapp_nic_linux.id]

  #encryption_at_host_enabled      = true
  #OS disk, Data disks, Temporary disk are encrypted at the physical host level before 
  #data is written to storage. It allows logins only via ssh -i private_key.pem adminuser@vm-ip .

  disable_password_authentication = true
  #enables login using ssh key but disables login with password using defined `admin_ssh_key` block.

  os_disk {
    caching                = "ReadWrite"
    storage_account_type   = "Standard_LRS"
    disk_encryption_set_id = azurerm_disk_encryption_set.prod_des.id
  }
  # works for test/dev

  #os_disk {
  #name                 = "linuxvm_osdisk"
  #caching              = "ReadWrite"
  #storage_account_type = "Premium_LRS"
  #disk_size_gb         = 128
  #}
  # works for prod

  #In production - 
  #Premium_LRS > High performance (most common)
  #Premium_ZRS > Zone redundant
  #StandardSSD_LRS > Balanced cost/performance

  source_image_reference {
    publisher = local.vm_images[var.environment].linux.publisher
    offer     = local.vm_images[var.environment].linux.offer
    sku       = local.vm_images[var.environment].linux.sku
    version   = local.vm_images[var.environment].linux.version
  }

  plan {
    name      = local.vm_images[var.environment].linux.sku
    product   = local.vm_images[var.environment].linux.offer
    publisher = local.vm_images[var.environment].linux.publisher
  }
  # `plan{},` block is for third party images other than canonical and microsoft.

  # Configure specific timeouts for the VM resource operations
  #timeouts {
  # Increase create timeout from default (often 30 mins) to 45 mins
  #  create = "45m"
  # Ensure delete operation gets enough time if VM cleanup is slow
  #  delete = "30m"
  # Read/Update timeouts remain default
  #}

  depends_on = [
    azurerm_role_assignment.des_kv_crypto,
    time_sleep.wait_for_des_rbac
  ]

  tags = merge(local.common_tags, {
    Name = "vm-linux"
  })

  lifecycle {
    create_before_destroy = true
    prevent_destroy       = false # `true` for prod, protection against `terraform destroy`

    ignore_changes = [
      tags["creation_run_id"],
      tags["creation_time"]
    ]
  }
}

# to SSH login do - `ssh -i ~/.ssh/prodmyapp_vm1.pem adminuser@20.5.121.162`

## Windows VM
/*
# Dedicated NSG for Windows
resource "azurerm_network_security_group" "prodmyapp_nsg_windows" {
  name                = "windows-secure-nsg"
  location            = azurerm_resource_group.prodmyapp.location
  resource_group_name = azurerm_resource_group.prodmyapp.name

  # Allow RDP ONLY from your IP
  security_rule {
    name                   = "Allow-RDP-MyIP"
    priority               = 100
    direction              = "Inbound"
    access                 = "Allow"
    protocol               = "Tcp"
    source_port_range      = "*"
    destination_port_range = "3389"

    source_address_prefix      = "*" # "<OUR_laptop_wifi_PUBLIC_IP>/32"
    destination_address_prefix = "*"
  }

  # Deny everything else inbound
  security_rule {
    name                       = "Deny-All-Inbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
  
  tags = merge(local.common_tags, {
    Name = "nsg-windows_prodmyapp"
  })

  lifecycle {
    ignore_changes = [
      tags["creation_run_id"],
      tags["creation_time"]
    ]
  }
}

#Separate Public IP
resource "azurerm_public_ip" "prodmyapp_pub_ip_windows" {
  name                = "win-public-ip"
  location            = azurerm_resource_group.prodmyapp.location
  resource_group_name = azurerm_resource_group.prodmyapp.name
  allocation_method   = "Static"
  
  tags = merge(local.common_tags, {
    Name = "pub-ip-win_prodmyapp"
  })

  lifecycle {
    ignore_changes = [
      tags["creation_run_id"],
      tags["creation_time"]
    ]
  }
}

# separate NIC for Windows VM
resource "azurerm_network_interface" "prodmyapp_nic_windows" {
  name                = "prodmyapp-win-nic"
  location            = azurerm_resource_group.prodmyapp.location
  resource_group_name = azurerm_resource_group.prodmyapp.name

  ip_configuration {
    name                          = "ip_config_windows"
    subnet_id                     = azurerm_subnet.pub_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.prodmyapp_pub_ip_windows.id
  }
  
  tags = merge(local.common_tags, {
    Name = "nic-windows_prodmyapp"
  })

  lifecycle {
    ignore_changes = [
      tags["creation_run_id"],
      tags["creation_time"]
    ]
  }
}

# NSG Association for Windows NIC
resource "azurerm_network_interface_security_group_association" "nic_nsg_assn_windows" {
  network_interface_id      = azurerm_network_interface.prodmyapp_nic_windows.id
  network_security_group_id = azurerm_network_security_group.prodmyapp_nsg_windows.id
}

# Pull admin password from key vault
data "azurerm_key_vault_secret" "win_password" {
  name         = "windowsvmpassword01"
  key_vault_id = azurerm_key_vault.prodmyapp.id

  depends_on = [
    azurerm_role_assignment.tf_kv_admin,
    time_sleep.wait_for_kv_rbac
  ]
  # Terraform reads secret during plan phase, so requires `depends_on`
}

resource "azurerm_windows_virtual_machine" "prodmyapp_windows_vm" {
  name                = "windows_vm_01"
  computer_name       = "windowsvmdev01"
  
  resource_group_name = azurerm_resource_group.prodmyapp.name
  location            = azurerm_resource_group.prodmyapp.location
  size                = local.selected_vm_size
  admin_username      = "adminuser"
  #admin_password      = "Adminuser@1234!"
  admin_password = data.azurerm_key_vault_secret.win_password.value
  
  network_interface_ids = [
    azurerm_network_interface.prodmyapp_nic_windows.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_encryption_set_id = azurerm_disk_encryption_set.prod_des.id
  }
  
  /*
  # for production 
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
    disk_encryption_set_id = azurerm_disk_encryption_set.prod_des.id
  }
  */
/*
  source_image_reference {
    publisher = local.vm_images[var.environment].windows.publisher
    offer     = local.vm_images[var.environment].windows.offer
    sku       = local.vm_images[var.environment].windows.sku
    version   = local.vm_images[var.environment].windows.version
  }
  
  # Enable Boot Diagnostics
  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.prodmyapp.primary_blob_endpoint
  }
  
  depends_on = [
    azurerm_role_assignment.des_kv_crypto,
    time_sleep.wait_for_des_rbac
  ]
  
  tags = merge(local.common_tags, {
    Name            = "vm-windows"
  })
  
  lifecycle {
    create_before_destroy = true
    prevent_destroy       = false  # `true` for prod, protection against `terraform destroy`
    
    ignore_changes        = [
      tags["creation_run_id"],
      tags["creation_time"]
    ]
  }
}
*/
# Deployment of resources in different regions using loop
