terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.61.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-tXXXate"
    storage_account_name = "XXXXXX"    
    container_name       = "XXX"
    key                  = "vdixXXXXxe"
  }
}

provider "azurerm" {
  features {}
}

variable "user_list" {
  type        = string
  default     = "[]"
}

variable "vm_admin_password" {
  type      = string
  sensitive = true
}

variable "domain_password" {
  type      = string
  sensitive = true
}

locals {
  users = jsondecode(var.user_list)
}

data "azurerm_subnet" "vdi_subnet" {
  name                 = "snet-eastus2-1"
  virtual_network_name = "vnet-eastus2"
  resource_group_name  = "On-prem"
}

resource "azurerm_resource_group" "vdi_rg" {
  for_each = { for user in local.users : user.UPN => user }

  name     = "rg-vdi-${replace(replace(each.key, "@", "-"), ".", "-")}"
  location = "East US 2"

  tags = {
    Owner       = each.value["Full Name"]
    Department  = each.value["Job Title"]
    Environment = "VDI"
    ManagedBy   = "Terraform Automation"
  }
}

resource "azurerm_public_ip" "vdi_pip" {
  for_each            = { for user in local.users : user.UPN => user }
  name                = "pip-${replace(replace(each.key, "@", "-"), ".", "-")}"
  location            = azurerm_resource_group.vdi_rg[each.key].location
  resource_group_name = azurerm_resource_group.vdi_rg[each.key].name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_security_group" "vdi_nsg" {
  for_each            = { for user in local.users : user.UPN => user }
  name                = "nsg-${replace(replace(each.key, "@", "-"), ".", "-")}"
  location            = azurerm_resource_group.vdi_rg[each.key].location
  resource_group_name = azurerm_resource_group.vdi_rg[each.key].name

  security_rule {
    name                       = "AllowRDP"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface_security_group_association" "vdi_nic_nsg" {
  for_each                  = { for user in local.users : user.UPN => user }
  network_interface_id      = azurerm_network_interface.vdi_nic[each.key].id
  network_security_group_id = azurerm_network_security_group.vdi_nsg[each.key].id
}


resource "azurerm_network_interface" "vdi_nic" {
  for_each = { for user in local.users : user.UPN => user }

  name                = "nic-${replace(replace(each.key, "@", "-"), ".", "-")}"
  location            = azurerm_resource_group.vdi_rg[each.key].location
  resource_group_name = azurerm_resource_group.vdi_rg[each.key].name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.vdi_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vdi_pip[each.key].id
  }
}

resource "azurerm_windows_virtual_machine" "vdi_vm" {
  for_each = { for user in local.users : user.UPN => user }

  name                = "vm-${substr(split("@", each.key)[0], 0, 11)}"
  resource_group_name = azurerm_resource_group.vdi_rg[each.key].name
  location            = azurerm_resource_group.vdi_rg[each.key].location
  
  size                  = "Standard_B2s"
  admin_username        = "XXXXXXn"
  admin_password        = var.vm_admin_password
  network_interface_ids =[azurerm_network_interface.vdi_nic[each.key].id]

  secure_boot_enabled = true
  vtpm_enabled        = true

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsDesktop"
    offer     = "Windows-11"
    sku       = "win11-24h2-pro" 
    version   = "latest"
  }

  tags = {
    Owner = each.value["Full Name"]
  }
}

resource "azurerm_virtual_machine_extension" "domain_join" {
  for_each = { for user in local.users : user.UPN => user }

  name                 = "join-domain"
  virtual_machine_id   = azurerm_windows_virtual_machine.vdi_vm[each.key].id
  publisher            = "Microsoft.Compute"
  type                 = "JsonADDomainExtension"
  type_handler_version = "1.3"

  settings = <<SETTINGS
    {
        "Name": "lab.jaykit.local",
        "User": "LAB\XXXXXXX",
        "Restart": "true",
        "Options": "3",
        "OUPath": "OU=VDI-Computers,DC=lab,DC=jaykit,DC=local"
    }
SETTINGS

  protected_settings = <<PROTECTED_SETTINGS
    {
        "Password": "${var.domain_password}"
    }
PROTECTED_SETTINGS
}


resource "azurerm_virtual_machine_extension" "vdi_user_config" {
  for_each             = { for user in local.users : user.UPN => user }
  name                 = "vdi-user-config"
  virtual_machine_id   = azurerm_windows_virtual_machine.vdi_vm[each.key].id
  publisher            = "Microsoft.Compute"
  
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  depends_on = [azurerm_virtual_machine_extension.domain_join]

  settings = <<SETTINGS
    {
        "commandToExecute": "powershell -ExecutionPolicy Unrestricted -Command \"$username = '${each.key}'.Split('@')[0]; $domainUser = 'LAB\\' + $username; Set-ItemProperty -Path 'HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server\\WinStations\\RDP-Tcp' -Name 'UserAuthentication' -Value 0; Set-ItemProperty -Path 'HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server\\WinStations\\RDP-Tcp' -Name 'SecurityLayer' -Value 1; net localgroup 'Remote Desktop Users' /add $domainUser\""
    }
SETTINGS
}
