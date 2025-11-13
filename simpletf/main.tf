/*
Automate Resource Creation on Azure
*/

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
  location            = azurerm_resource_group.location
  resource_group_name = azurerm_resource_group.name
}

# Subnets w/ network security group
# public subnet (10.0.1.0/28) 
resource "azurerm_subnet" "pubnet1" {
  name                 = "pub1-subnet"
  resource_group_name  = azurerm_resource_group.name
  virtual_network_name = azurerm_virtual_network.name
  address_prefixes     = ["10.0.1.0/28"]
}
# private subnet (10.0.2.0/24) 
resource "azurerm_subnet" "pvtnet" {
  name                 = "pvt1-subnet"
  resource_group_name  = azurerm_resource_group.name
  virtual_network_name = azurerm_virtual_network.name
  address_prefixes     = ["10.0.2.0/24"]
}

# Key Vault

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