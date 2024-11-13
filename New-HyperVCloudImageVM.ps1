<#
.SYNOPSIS
  Provision Cloud images on Hyper-V
.EXAMPLE
  PS C:\> .\New-HyperVCloudImageVM.ps1 -VMProcessorCount 2 -VMMemoryStartupBytes 2GB -VHDSizeBytes 60GB -VMName "azure-1" -ImageVersion "jammy-azure" -VMGeneration 2
  PS C:\> .\New-HyperVCloudImageVM.ps1 -VMProcessorCount 2 -VMMemoryStartupBytes 2GB -VHDSizeBytes 8GB -VMName "azure-2" -ImageVersion "testing-azure" -VirtualSwitchName "SWBRIDGE" -VMGeneration 2 -VMMachine_StoragePath "D:\HyperV" -NetAddress 192.168.2.22/24 -NetGateway 192.168.2.1 -NameServers "192.168.2.1" -ShowSerialConsoleWindow -ShowVmConnectWindow
  It should download cloud image and create VM, please be patient for first boot - it could take 10 minutes
  and requires network connection on VM
.NOTES
  Original script: https://blogs.msdn.microsoft.com/virtual_pc_guy/2015/06/23/building-a-daily-ubuntu-image-for-hyper-v/

  References:
  - https://git.launchpad.net/cloud-init/tree/cloudinit/sources/DataSourceAzure.py
  - https://github.com/Azure/azure-linux-extensions/blob/master/script/ovf-env.xml
  - https://cloudinit.readthedocs.io/en/latest/topics/datasources/azure.html
  - https://github.com/fdcastel/Hyper-V-Automation
  - https://bugs.launchpad.net/ubuntu/+source/walinuxagent/+bug/1700769
  - https://gist.github.com/Informatic/0b6b24374b54d09c77b9d25595cdbd47
  - https://www.neowin.net/news/canonical--microsoft-make-azure-tailored-linux-kernel/
  - https://www.altaro.com/hyper-v/powershell-script-change-advanced-settings-hyper-v-virtual-machines/

  Recommended: choco install putty -y
#>

#requires -Modules Hyper-V
#requires -RunAsAdministrator
#requires -PSEdition Desktop

[CmdletBinding()]
param(
  [string] $VMName = "CloudVm",
  [int] $VMGeneration = 1, # create gen1 hyper-v machine because of portability to Azure (https://docs.microsoft.com/en-us/azure/virtual-machines/windows/prepare-for-upload-vhd-image)
  [int] $VMProcessorCount = 1,
  [bool] $VMDynamicMemoryEnabled = $false,
  [uint64] $VMMemoryStartupBytes = 1024MB,
  [uint64] $VMMinimumBytes = $VMMemoryStartupBytes,
  [uint64] $VMMaximumBytes = $VMMemoryStartupBytes,
  [uint64] $VHDSizeBytes = 16GB,
  [string] $VirtualSwitchName = $null,
  [string] $VMVlanID = $null,
  [string] $VMNativeVlanID = $null,
  [string] $VMAllowedVlanIDList = $null,
  [switch] $VMVMQ = $false,
  [switch] $VMDhcpGuard = $false,
  [switch] $VMRouterGuard = $false,
  [switch] $VMPassthru = $false,
  #[switch] $VMMinimumBandwidthAbsolute = $null,
  #[switch] $VMMinimumBandwidthWeight = $null,
  #[switch] $VMMaximumBandwidth = $null,
  [switch] $VMMacAddressSpoofing = $false,
  [switch] $VMExposeVirtualizationExtensions = $false,
  [string] $VMVersion = "8.0", # version 8.0 for hyper-v 2016 compatibility , check all possible values with Get-VMHostSupportedVersion
  [string] $VMHostname = $VMName,
  [string] $VMMachine_StoragePath = $null, # if defined setup machine path with storage path as subfolder
  [string] $VMMachinePath = $null, # if not defined here default Virtal Machine path is used
  [string] $VMStoragePath = $null, # if not defined here Hyper-V settings path / fallback path is set below
  [bool] $ConvertImageToNoCloud = $false, # could be used for other image types that do not support NoCloud, not just Azure
  [bool] $ImageTypeAzure = $false,
  [string] $DomainName = "domain.local",
  [string] $VMStaticMacAddress = $null,
  [string] $NetInterface = "eth0",
  [string] $NetAddress = $null,
  [string] $NetNetmask = $null,
  [string] $NetNetwork = $null,
  [string] $NetGateway = $null,
  [string] $NameServers = "1.1.1.1,1.0.0.1",
  [string] $NetConfigType = $null, # ENI, v1, v2, ENI-file, dhclient
  [string] $KeyboardLayout = "us", # 2-letter country code, for more info https://wiki.archlinux.org/title/Xorg/Keyboard_configuration
  [string] $KeyboardModel, # default: "pc105"
  [string] $KeyboardOptions, # example: "compose:rwin"
  [string] $Locale = "en_US", # "en_US.UTF-8",
  [string] $TimeZone = "UTC", # UTC or continental zones of IANA DB like: Europe/Berlin
  [string] $CloudInitPowerState = "reboot", # poweroff, halt, or reboot , https://cloudinit.readthedocs.io/en/latest/reference/modules.html#power-state-change
  [string] $CustomUserDataYamlFile,
  [string] $GuestAdminUsername = "admin",
  [string] $GuestAdminPassword = "Passw0rd",
  [string] $GuestAdminSshPubKey,
  [string] $GuestAdminSshPubKeyFile,
  [string] $ImageVersion = "20.04", # $ImageName ="focal" # 20.04 LTS , $ImageName="bionic" # 18.04 LTS
  [string] $ImageRelease = "release", # default option is get latest but could be fixed to some specific version for example "release-20210413"
  [string] $ImageBaseUrl = "http://cloud-images.ubuntu.com/releases", # alternative https://mirror.scaleuptech.com/ubuntu-cloud-images/releases
  [bool] $BaseImageCheckForUpdate = $true, # check for newer image at Distro cloud-images site
  [bool] $BaseImageCleanup = $true, # delete old vhd image. Set to false if using (TODO) differencing VHD
  [switch] $ShowSerialConsoleWindow = $false,
  [switch] $ShowVmConnectWindow = $false,
  [switch] $Force = $false
)

[System.Threading.Thread]::CurrentThread.CurrentUICulture = "en-US"
[System.Threading.Thread]::CurrentThread.CurrentCulture = "en-US"

$NetAutoconfig = (($null -eq $NetAddress) -or ($NetAddress -eq "")) -and
                 (($null -eq $NetNetmask) -or ($NetNetmask -eq "")) -and
                 (($null -eq $NetNetwork) -or ($NetNetwork -eq "")) -and
                 (($null -eq $NetGateway) -or ($NetGateway -eq "")) -and
                 (($null -eq $VMStaticMacAddress) -or ($VMStaticMacAddress -eq ""))

if ($NetAutoconfig -eq $false) {
  Write-Verbose "Given Network configuration - no checks done in script:"
  Write-Verbose "VMStaticMacAddress: '$VMStaticMacAddress'"
  Write-Verbose "NetInterface:     '$NetInterface'"
  Write-Verbose "NetAddress:       '$NetAddress'"
  Write-Verbose "NetNetmask:       '$NetNetmask'"
  Write-Verbose "NetNetwork:       '$NetNetwork'"
  Write-Verbose "NetGateway:       '$NetGateway'"
  Write-Verbose ""
}

# default error action
$ErrorActionPreference = 'Stop'

# pwsh (powershell core): try to load module hyper-v
if ($psversiontable.psversion.Major -ge 6) {
  Import-Module hyper-v -SkipEditionCheck
}

# check if verbose is present, src: https://stackoverflow.com/a/25491281/1155121
$verbose = $VerbosePreference -ne 'SilentlyContinue'

# check if running hyper-v host version 8.0 or later
# Get-VMHostSupportedVersion https://docs.microsoft.com/en-us/powershell/module/hyper-v/get-vmhostsupportedversion?view=win10-ps
# or use vmms version: $vmms = Get-Command vmms.exe , $vmms.version. src: https://social.technet.microsoft.com/Forums/en-US/dce2a4ec-10de-4eba-a19d-ae5213a2382d/how-to-tell-version-of-hyperv-installed?forum=winserverhyperv
$vmms = Get-Command vmms.exe
if (([System.Version]$vmms.fileversioninfo.productversion).Major -lt 10) {
  throw "Unsupported Hyper-V version. Minimum supported version for is Hyper-V 2016."
}

# Helper function for no error file cleanup
function cleanupFile ([string]$file) {
  if (test-path $file) {
    Remove-Item $file -force
  }
}

$FQDN = $VMHostname.ToLower() + "." + $DomainName.ToLower()
# Instead of GUID, use 26 digit machine id suitable for BIOS serial number
# src: https://stackoverflow.com/a/67077483/1155121
# $vmMachineId = [Guid]::NewGuid().ToString()
$VmMachineId = "{0:####-####-####-####}-{1:####-####-##}" -f (Get-Random -Minimum 1000000000000000 -Maximum 9999999999999999),(Get-Random -Minimum 1000000000 -Maximum 9999999999)
$tempPath = [System.IO.Path]::GetTempPath() + $vmMachineId
mkdir -Path $tempPath | out-null
Write-Verbose "Using temp path: $tempPath"

# ADK Download - https://www.microsoft.com/en-us/download/confirmation.aspx?id=39982
# You only need to install the deployment tools, src2: https://github.com/Studisys/Bootable-Windows-ISO-Creator
#$oscdimgPath = "C:\Program Files (x86)\Windows Kits\8.1\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
$oscdimgPath = Join-Path $PSScriptRoot "tools\oscdimg\x64\oscdimg.exe"

# Download qemu-img from here: http://www.cloudbase.it/qemu-img-windows/
$qemuImgPath = Join-Path $PSScriptRoot "tools\qemu-img-4.1.0\qemu-img.exe"

# Windows version of tar for extracting tar.gz files, src: https://github.com/libarchive/libarchive
$bsdtarPath = Join-Path $PSScriptRoot "tools\bsdtar-3.7.6\bsdtar.exe"

# Update this to the release of Image that you want
# But Azure images can't be used because the waagent is trying to find ephemeral disk
# and it's searching causing 20 / 40 minutes minutes delay for 1st boot
# https://docs.microsoft.com/en-us/troubleshoot/azure/virtual-machines/cloud-init-deployment-delay
# and also somehow causing at sshd restart in password setting task to stuck for 30 minutes.
Switch ($ImageVersion) {
  "18.04" {
    $_ = "bionic"
    $ImageVersion = "18.04"
  }
  "bionic" {
    $ImageOS = "ubuntu"
    $ImageVersionName = "bionic"
    $ImageVersion = "18.04"
    $ImageRelease = "release" # default option is get latest but could be fixed to some specific version for example "release-20210413"
    $ImageBaseUrl = "http://cloud-images.ubuntu.com/releases" # alternative https://mirror.scaleuptech.com/ubuntu-cloud-images/releases
    $ImageUrlRoot = "$ImageBaseUrl/$ImageVersionName/$ImageRelease/" # latest
    $ImageFileName = "$ImageOS-$ImageVersion-server-cloudimg-amd64"
    $ImageFileExtension = "img"
    # Manifest file is used for version check based on last modified HTTP header
    $ImageHashFileName = "SHA256SUMS"
    $ImageManifestSuffix = "manifest"
  }
  "20.04" {
    $_ = "focal"
    $ImageVersion = "20.04"
  }
  "focal" {
    $ImageOS = "ubuntu"
    $ImageVersionName = "focal"
    $ImageVersion = "20.04"
    $ImageRelease = "release" # default option is get latest but could be fixed to some specific version for example "release-20210413"
    $ImageBaseUrl = "http://cloud-images.ubuntu.com/releases" # alternative https://mirror.scaleuptech.com/ubuntu-cloud-images/releases
    $ImageUrlRoot = "$ImageBaseUrl/$ImageVersionName/$ImageRelease/" # latest
    $ImageFileName = "$ImageOS-$ImageVersion-server-cloudimg-amd64"
    $ImageFileExtension = "img"
    # Manifest file is used for version check based on last modified HTTP header
    $ImageHashFileName = "SHA256SUMS"
    $ImageManifestSuffix = "manifest"
  }
  "22.04" {
    $_ = "jammy"
    $ImageVersion = "22.04"
  }
  "jammy" {
    $ImageOS = "ubuntu"
    $ImageVersionName = "jammy"
    $ImageVersion = "22.04"
    $ImageRelease = "release" # default option is get latest but could be fixed to some specific version for example "release-20210413"
    $ImageBaseUrl = "http://cloud-images.ubuntu.com/releases" # alternative https://mirror.scaleuptech.com/ubuntu-cloud-images/releases
    $ImageUrlRoot = "$ImageBaseUrl/$ImageVersionName/$ImageRelease/" # latest
    $ImageFileName = "$ImageOS-$ImageVersion-server-cloudimg-amd64"
    $ImageFileExtension = "img"
    # Manifest file is used for version check based on last modified HTTP header
    $ImageHashFileName = "SHA256SUMS"
    $ImageManifestSuffix = "manifest"
  }
  "22.04-azure" {
    $_ = "jammy-azure"
    $ImageVersion = "22.04-azure"
  }
  "jammy-azure" {
    $ImageTypeAzure = $true
    $ConvertImageToNoCloud = $true
    $ImageOS = "ubuntu"
    #$ImageVersion = "22.04"
    #$ImageVersionName = "jammy"
    $ImageRelease = "release" # default option is get latest but could be fixed to some specific version for example "release-20210413"
    # https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64-azure.vhd.tar.gz
    $ImageBaseUrl = "http://cloud-images.ubuntu.com/releases" # alternative https://mirror.scaleuptech.com/ubuntu-cloud-images/releases
    $ImageUrlRoot = "$ImageBaseUrl/jammy/$ImageRelease/" # latest
    $ImageFileName = "$ImageOS-22.04-server-cloudimg-amd64-azure" # should contain "vhd.*" version
    $ImageFileExtension = "vhd.tar.gz" # or "vhd.zip" on older releases
    # Manifest file is used for version check based on last modified HTTP header
    $ImageHashFileName = "SHA256SUMS"
    $ImageManifestSuffix = "vhd.manifest"
  }
  "24.04" {
    $_ = "noble"
    $ImageVersion = "24.04"
  }
  "noble" {
    $ImageOS = "ubuntu"
    $ImageVersionName = "noble"
    $ImageVersion = "24.04"
    $ImageRelease = "release" # default option is get latest but could be fixed to some specific version for example "release-20210413"
    $ImageBaseUrl = "http://cloud-images.ubuntu.com/releases" # alternative https://mirror.scaleuptech.com/ubuntu-cloud-images/releases
    $ImageUrlRoot = "$ImageBaseUrl/$ImageVersionName/$ImageRelease/" # latest
    $ImageFileName = "$ImageOS-$ImageVersion-server-cloudimg-amd64"
    $ImageFileExtension = "img"
    # Manifest file is used for version check based on last modified HTTP header
    $ImageHashFileName = "SHA256SUMS"
    $ImageManifestSuffix = "manifest"
  }
  "24.04-azure" {
    $_ = "noble-azure"
    $ImageVersion = "24.04-azure"
  }
  "noble-azure" {
    $ImageTypeAzure = $true
    $ConvertImageToNoCloud = $true
    $ImageOS = "ubuntu"
    #$ImageVersion = "24.04"
    #$ImageVersionName = "noble"
    $ImageRelease = "release" # default option is get latest but could be fixed to some specific version for example "release-20210413"
    # https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64-azure.vhd.tar.gz
    $ImageBaseUrl = "http://cloud-images.ubuntu.com/releases" # alternative https://mirror.scaleuptech.com/ubuntu-cloud-images/releases
    $ImageUrlRoot = "$ImageBaseUrl/noble/$ImageRelease/" # latest
    $ImageFileName = "$ImageOS-24.04-server-cloudimg-amd64-azure" # should contain "vhd.*" version
    $ImageFileExtension = "vhd.tar.gz" # or "vhd.zip" on older releases
    # Manifest file is used for version check based on last modified HTTP header
    $ImageHashFileName = "SHA256SUMS"
    $ImageManifestSuffix = "vhd.manifest"
  }
  "10" {
    $_ = "buster"
    $ImageVersion = "10"
  }
  "buster" {
    $ImageOS = "debian"
    $ImageVersionName = "buster"
    $ImageRelease = "latest" # default option is get latest but could be fixed to some specific version for example "release-20210413"
    # http://cloud.debian.org/images/cloud/buster/latest/debian-10-azure-amd64.tar.xz
    $ImageBaseUrl = "http://cloud.debian.org/images/cloud"
    $ImageUrlRoot = "$ImageBaseUrl/$ImageVersionName/$ImageRelease/"
    $ImageFileName = "$ImageOS-$ImageVersion-genericcloud-amd64" # should contain "vhd.*" version
    $ImageFileExtension = "tar.xz" # or "vhd.tar.gz" on older releases
    # Manifest file is used for version check based on last modified HTTP header
    $ImageHashFileName = "SHA512SUMS"
    $ImageManifestSuffix = "json"
  }
  "11" {
    $_ = "bullseye"
    $ImageVersion = "11"
  }
  "bullseye" {
    $ImageOS = "debian"
    $ImageVersionName = "bullseye"
    $ImageRelease = "latest" # default option is get latest but could be fixed to some specific version for example "release-20210413"
    # http://cloud.debian.org/images/cloud/bullseye/latest/debian-11-azure-amd64.tar.xz
    $ImageBaseUrl = "http://cloud.debian.org/images/cloud"
    $ImageUrlRoot = "$ImageBaseUrl/$ImageVersionName/$ImageRelease/"
    $ImageFileName = "$ImageOS-$ImageVersion-genericcloud-amd64" # should contain "raw" version
    $ImageFileExtension = "tar.xz" # or "vhd.tar.gz" on older releases
    # Manifest file is used for version check based on last modified HTTP header
    $ImageHashFileName = "SHA512SUMS"
    $ImageManifestSuffix = "json"
  }
  "12" {
    $_ = "bookworm"
    $ImageVersion = "12"
  }
  "bookworm" {
    $ImageOS = "debian"
    $ImageVersionName = "bookworm"
    $ImageRelease = "latest" # default option is get latest but could be fixed to some specific version for example "release-20210413"
    # http://cloud.debian.org/images/cloud/bookworm/latest/debian-12-azure-amd64.tar.xz
    $ImageBaseUrl = "http://cloud.debian.org/images/cloud"
    $ImageUrlRoot = "$ImageBaseUrl/$ImageVersionName/$ImageRelease/"
    $ImageFileName = "$ImageOS-$ImageVersion-genericcloud-amd64" # should contain "raw" version
    $ImageFileExtension = "tar.xz" # or "vhd.tar.gz" on older releases
    # Manifest file is used for version check based on last modified HTTP header
    $ImageHashFileName = "SHA512SUMS"
    $ImageManifestSuffix = "json"
  }
  "testing-azure" {
    $_ = "trixie-azure"
    $ImageVersion = "trixie"
  }
  "trixie-azure" {
    $ImageTypeAzure = $true
    $ConvertImageToNoCloud = $true
    $ImageOS = "debian"
    $ImageVersionName = "trixie"
    $ImageRelease = "daily/latest" # default option is get latest but could be fixed to some specific version for example "release-20210413"
    # http://cloud.debian.org/images/cloud/trixie/daily/latest/debian-trixie-azure-amd64-daily.tar.xz
    $ImageBaseUrl = "http://cloud.debian.org/images/cloud"
    $ImageUrlRoot = "$ImageBaseUrl/$ImageVersionName/$ImageRelease/"
    #$ImageFileName = "$ImageOS-$ImageVersion-nocloud-amd64" # should contain "raw" version
    $ImageFileName = "$ImageOS-13-azure-amd64-daily" # should contain "raw" version
    $ImageFileExtension = "tar.xz" # or "vhd.tar.gz" on older releases
    # Manifest file is used for version check based on last modified HTTP header
    $ImageHashFileName = "SHA512SUMS"
    $ImageManifestSuffix = "json"
  }
  default {throw "Image version $ImageVersion not supported."}
}

$ImagePath = "$($ImageUrlRoot)$($ImageFileName)"
$ImageHashPath = "$($ImageUrlRoot)$($ImageHashFileName)"

# use Azure specifics only if such cloud image is chosen
if ($ImageTypeAzure) {
  Write-Verbose "Using Azure data source for cloud init in: $ImageFileName"
}

# Set path for storing all VM files
if (-not [string]::IsNullOrEmpty($VMMachine_StoragePath)) {
  $VMMachinePath = $VMMachine_StoragePath.TrimEnd('\')
  $VMStoragePath = "$VMMachine_StoragePath\$VMName\Virtual Hard Disks"
  Write-Verbose "VMStoragePath set: $VMStoragePath"
}

# Get default Virtual Machine path (requires administrative privileges)
if ([string]::IsNullOrEmpty($VMMachinePath)) {
  $VMMachinePath = (Get-VMHost).VirtualMachinePath
  # fallback
  if (-not $VMMachinePath) {
    Write-Warning "Couldn't obtain VMMachinePath from Hyper-V settings via WMI"
    $VMMachinePath = "C:\Users\Public\Documents\Hyper-V"
  }
  Write-Verbose "VMMachinePath set: $VMMachinePath"
}
if (!(test-path $VMMachinePath)) {New-Item -ItemType Directory -Path $VMMachinePath | out-null}

# Get default Virtual Hard Disk path (requires administrative privileges)
if ([string]::IsNullOrEmpty($VMStoragePath)) {
  $VMStoragePath = (Get-VMHost).VirtualHardDiskPath
  # fallback
  if (-not $VMStoragePath) {
    Write-Warning "Couldn't obtain VMStoragePath from Hyper-V settings via WMI"
    $VMStoragePath = "C:\Users\Public\Documents\Hyper-V\Virtual Hard Disks"
  }
  Write-Verbose "VMStoragePath set: $VMStoragePath"
}
if (!(test-path $VMStoragePath)) {New-Item -ItemType Directory -Path $VMStoragePath | out-null}

# Delete the VM if it is around
$vm = Get-VM -VMName $VMName -ErrorAction 'SilentlyContinue'
if ($vm) {
  & .\Cleanup-VM.ps1 $VMName -Force:$Force
}

# There is a documentation failure not mention needed dsmode setting:
# https://gist.github.com/Informatic/0b6b24374b54d09c77b9d25595cdbd47
# Only in special cloud environments its documented already:
# https://cloudinit.readthedocs.io/en/latest/topics/datasources/cloudsigma.html
# metadata for cloud-init
$metadata = @"
dsmode: local
instance-id: $($VmMachineId)
local-hostname: $($VMHostname)
"@

Write-Verbose "Metadata:"
Write-Verbose $metadata
Write-Verbose ""

# Azure:   https://cloudinit.readthedocs.io/en/latest/topics/datasources/azure.html
# NoCloud: https://cloudinit.readthedocs.io/en/latest/topics/datasources/nocloud.html
# with static network examples included

if ($NetAutoconfig -eq $false) {
  Write-Verbose "Network Autoconfiguration disabled."
  #$NetConfigType = "v1"
  #$NetConfigType = "v2"
  #$NetConfigType = "ENI"
  #$NetConfigType = "ENI-file" ## needed for Debian
  #$NetConfigType = "dhclient"
  if ([string]::IsNullOrEmpty($NetConfigType)) {
    $NetConfigType = "v2"
    Write-Verbose "Using default manual network configuration '$NetConfigType'."
  } else {
    Write-Verbose "NetworkConfigType: '$NetConfigType' assigned."
  }
}
$networkconfig = $null
$network_write_files = $null
if ($NetAutoconfig -eq $false) {
  Write-Verbose "Network autoconfig disabled; preparing networkconfig."
  if ($NetConfigType -ieq "v1") {
    Write-Verbose "v1 requested ..."
    $networkconfig = @"
## /network-config on NoCloud cidata disk
## version 1 format
## version 2 is completely different, see the docs
## version 2 is not supported by Fedora
---
version: 1
config:
  - enabled
  - type: physical
    name: $NetInterface
    $(if (($null -eq $VMStaticMacAddress) -or ($VMStaticMacAddress -eq "")) { "#" })mac_address: $VMStaticMacAddress
    $(if (($null -eq $NetAddress) -or ($NetAddress -eq "")) { "#" })subnets:
    $(if (($null -eq $NetAddress) -or ($NetAddress -eq "")) { "#" })  - type: static
    $(if (($null -eq $NetAddress) -or ($NetAddress -eq "")) { "#" })    address: $NetAddress
    $(if (($null -eq $NetNetmask) -or ($NetNetmask -eq "")) { "#" })    netmask: $NetNetmask
    $(if (($null -eq $NetNetwork) -or ($NetNetwork -eq "")) { "#" })    network: $NetNetwork
    $(if (($null -eq $NetGateway) -or ($NetGateway -eq "")) { "#" })    routes:
    $(if (($null -eq $NetGateway) -or ($NetGateway -eq "")) { "#" })      - network: 0.0.0.0
    $(if (($null -eq $NetGateway) -or ($NetGateway -eq "")) { "#" })        netmask: 0.0.0.0
    $(if (($null -eq $NetGateway) -or ($NetGateway -eq "")) { "#" })        gateway: $NetGateway
  - type: nameserver
    address: ['$($NameServers.Split(",") -join "', '" )']
    search:  ['$($DomainName)']
"@
} elseif ($NetConfigType -ieq "v2") {
    Write-Verbose "v2 requested ..."
    $networkconfig = @"
version: 2
ethernets:
  $($NetInterface):
    dhcp4: $NetAutoconfig
    dhcp6: $NetAutoconfig
    #$(if (($null -eq $VMStaticMacAddress) -or ($VMStaticMacAddress -eq "")) { "#" })mac_address: $VMStaticMacAddress
    $(if (($null -eq $NetAddress) -or ($NetAddress -eq "")) { "#" })addresses:
    $(if (($null -eq $NetAddress) -or ($NetAddress -eq "")) { "#" })  - $NetAddress
    $(if (($null -eq $NetGateway) -or ($NetGateway -eq "")) { "#" })routes:
    $(if (($null -eq $NetGateway) -or ($NetGateway -eq "")) { "#" })  - to: default
    $(if (($null -eq $NetGateway) -or ($NetGateway -eq "")) { "#" })    via: $NetGateway
    nameservers:
      addresses: ['$($NameServers.Split(",") -join "', '" )']
      search: ['$($DomainName)']
"@
  } elseif ($NetConfigType -ieq "ENI") {
    Write-Verbose "ENI requested ..."
    $networkconfig = @"
# inline-ENI network configuration
network-interfaces: |
  iface $NetInterface inet static
$(if (($null -ne $VMStaticMacAddress) -and ($VMStaticMacAddress -ne "")) { "  hwaddress ether $VMStaticMacAddress`n"
})$(if (($null -ne $NetAddress) -and ($NetAddress -ne "")) { "  address $NetAddress`n"
})$(if (($null -ne $NetNetwork) -and ($NetNetwork -ne "")) { "  network $NetNetwork`n"
})$(if (($null -ne $NetNetmask) -and ($NetNetmask -ne "")) { "  netmask $NetNetmask`n"
})$(if (($null -ne $NetBroadcast) -and ($NetBroadcast -ne "")) { "  broadcast $Broadcast`n"
})$(if (($null -ne $NetGateway) -and ($NetGateway -ne "")) { "  gateway $NetGateway`n"
})
  dns-nameservers $($NameServers.Split(",") -join " ")
  dns-search $DomainName
"@
  } elseif ($NetConfigType -ieq "ENI-file") {
    Write-Verbose "ENI-file requested ..."
    # direct network configuration setup
    $network_write_files = @"
  # Static IP address
  - content: |
      # Configuration file for ENI networkmanager
      # This file describes the network interfaces available on your system
      # and how to activate them. For more information, see interfaces(5).

      source /etc/network/interfaces.d/*

      # The loopback network interface
      auto lo
      iface lo inet loopback

      # The primary network interface
      allow-hotplug eth0
      iface $NetInterface inet static
$(if (($null -ne $NetAddress) -and ($NetAddress -ne "")) { "          address $NetAddress`n"
})$(if (($null -ne $NetNetwork) -and ($NetNetwork -ne "")) { "          network $NetNetwork`n"
})$(if (($null -ne $NetNetmask) -and ($NetNetmask -ne "")) { "          netmask $NetNetmask`n"
})$(if (($null -ne $NetBroadcast) -and ($NetBroadcast -ne "")) { "          broadcast $Broadcast`n"
})$(if (($null -ne $NetGateway) -and ($NetGateway -ne "")) { "          gateway $NetGateway`n"
})$(if (($null -ne $VMStaticMacAddress) -and ($VMStaticMacAddress -ne "")) { "      hwaddress ether $VMStaticMacAddress`n"
})
          dns-nameservers $($NameServers.Split(",") -join " ")
          dns-search $DomainName
    path: /etc/network/interfaces.d/$($NetInterface)
"@
  } elseif ($NetConfigType -ieq "dhclient") {
    Write-Verbose "dhclient requested ..."
    $network_write_files = @"
  # Static IP address
  - content: |
      # Configuration file for /sbin/dhclient.
      send host-name = gethostname();
      lease {
        interface `"$NetInterface`";
        fixed-address $NetAddress;
        option host-name `"$($FQDN)`";
        option subnet-mask $NetAddress
        #option broadcast-address 192.33.137.255;
        option routers $NetGateway;
        option domain-name-servers $($NameServers.Split(",") -join " ");
        renew 2 2022/1/1 00:00:01;
        rebind 2 2022/1/1 00:00:01;
        expire 2 2022/1/1 00:00:01;
      }

      # Generate Stable Private IPv6 Addresses instead of hardware based ones
      slaac private

    path: /etc/dhcp/dhclient.conf
"@
  } else {
    Write-Warning "No network configuration version type defined for static IP address setup."
  }
}

if ($null -ne $networkconfig) {
  Write-Verbose ""
  Write-Verbose "Network-Config:"
  Write-Verbose $networkconfig
  Write-Verbose ""
}

if ($null -ne $network_write_files) {
  Write-Verbose ""
  Write-Verbose "Network-Config for write_files:"
  Write-Verbose $network_write_files
  Write-Verbose ""
}

# userdata for cloud-init, https://cloudinit.readthedocs.io/en/latest/topics/examples.html
$userdata = @"
#cloud-config
# vim: syntax=yaml
# created: $(Get-Date -UFormat "%b/%d/%Y %T %Z")

hostname: $($VMHostname)
fqdn: $($FQDN)
# cloud-init Bug 21.4.1: locale update prepends "LANG=" like in
# /etc/defaults/locale set and results into error
#locale: $Locale
timezone: $TimeZone

growpart:
  mode: auto
  devices: [/]
  ignore_growroot_disabled: false

apt:
#  http_proxy: http://host:port
#  https_proxy: http://host:port
  preserve_sources_list: true

package_update: true
package_upgrade: true
package_reboot_if_required: true
packages:
$(
# hyperv linux integration services https://poweradm.com/install-linux-integration-services-hyper-v/
if ($ImageOS -eq "debian") {

"  - hyperv-daemons"}
elseif (($ImageOS -eq "ubuntu")) {
# azure kernel https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/Supported-Ubuntu-virtual-machines-on-Hyper-V#notes
"  - linux-tools-virtual
  - linux-cloud-tools-virtual
  - linux-azure"
})
  - eject
  - console-setup
  - keyboard-configuration

# documented keyboard option, but not implemented ?
# https://cloudinit.readthedocs.io/en/latest/topics/modules.html#keyboard
# https://github.com/sulmone/X11/blob/59029dc09211926a5c95ff1dd2b828574fefcde6/share/X11/xkb/rules/xorg.lst#L181
keyboard:
  layout: $KeyboardLayout
$(if (-not [string]::IsNullOrEmpty($KeyboardModel)) {"  model: $KeyboardModel"})
$(if (-not [string]::IsNullOrEmpty($KeyboardOptions)) {"  options: $KeyboardOptions"})

# https://learn.microsoft.com/en-us/azure/virtual-machines/linux/cloudinit-add-user#add-a-user-to-a-vm-with-cloud-init

users:
  - default
  - name: $($GuestAdminUsername)
    no_user_group: true
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    plain_text_passwd: $($GuestAdminPassword)
    lock_passwd: false
$(if (-not [string]::IsNullOrEmpty($GuestAdminSshPubKey)) {
"    ssh_authorized_keys:
    - $GuestAdminSshPubKey
"})
$(if (-not [string]::IsNullOrEmpty($GuestAdminSshPubKeyFile)) {
"    ssh_authorized_keys:
    - $(Get-Content -Path $GuestAdminSshPubKeyFile -Raw)
"})

disable_root: true    # true: notify default user account / false: allow root ssh login
ssh_pwauth: true      # true: allow login with password; else only with setup pubkey(s)

#ssh_authorized_keys:
#  - ssh-rsa AAAAB... comment

# bootcmd can be setup like runcmd but would run at very early stage
# on every cloud-init assisted boot if not prepended by command "cloud-init-per once|instance|always":
$(if ($NetAutoconfig -eq $true) { "#" })bootcmd:
$(if ($NetAutoconfig -eq $true) { "#" })  - [ cloud-init-per, once, fix-dhcp, sh, -c, sed -e 's/#timeout 60;/timeout 1;/g' -i /etc/dhcp/dhclient.conf ]
runcmd:
$(if (($NetAutoconfig -eq $false) -and ($NetConfigType -ieq "ENI-file")) {
"  # maybe condition OS based for Debian only and not ENI-file based?
  # Comment out cloud-init based dhcp configuration for $NetInterface
  - [ rm, /etc/network/interfaces.d/50-cloud-init ]
"})  # - [ sh, -c, echo "127.0.0.1 localhost" >> /etc/hosts ]
  # force password change on 1st boot
  # - [ chage, -d, 0, $($GuestAdminUsername) ]
  # remove metadata iso
  - [ sh, -c, "if test -b /dev/cdrom; then eject; fi" ]
  - [ sh, -c, "if test -b /dev/sr0; then eject /dev/sr0; fi" ]
$(if ($ImageTypeAzure) { "
    # dont start waagent service since it useful only for azure/scvmm
  - [ systemctl, stop, walinuxagent.service]
  - [ systemctl, disable, walinuxagent.service]
"})  # disable cloud init on next boot (https://cloudinit.readthedocs.io/en/latest/topics/boot.html, https://askubuntu.com/a/1047618)
  - [ sh, -c, touch /etc/cloud/cloud-init.disabled ]
  # set locale
  # cloud-init Bug 21.4.1: locale update prepends "LANG=" like in
  # /etc/defaults/locale set and results into error
  - [ locale-gen, "$($Locale).UTF-8" ]
  - [ update-locale, "$($Locale).UTF-8" ]
  # documented keyboard option, but not implemented ?
  # change keyboard layout, src: https://askubuntu.com/a/784816
  - [ sh, -c, sed -i 's/XKBLAYOUT=\"\w*"/XKBLAYOUT=\"'$($KeyboardLayout)'\"/g' /etc/default/keyboard ]

write_files:
  # hyperv-daemons package in mosts distros is missing this file and spamming syslog:
  # https://github.com/torvalds/linux/blob/master/tools/hv/hv_get_dns_info.sh
  - content: |
      #!/bin/bash

      # This example script parses /etc/resolv.conf to retrive DNS information.
      # In the interest of keeping the KVP daemon code free of distro specific
      # information; the kvp daemon code invokes this external script to gather
      # DNS information.
      # This script is expected to print the nameserver values to stdout.
      # Each Distro is expected to implement this script in a distro specific
      # fashion. For instance on Distros that ship with Network Manager enabled,
      # this script can be based on the Network Manager APIs for retrieving DNS
      # entries.

      cat /etc/resolv.conf 2>/dev/null | awk '/^nameserver/ { print $2 }'
    path: /usr/libexec/hypervkvpd/hv_get_dns_info
  # hyperv-daemons package in mosts distros is missing this file and spamming syslog:
  # https://github.com/torvalds/linux/blob/master/tools/hv/hv_get_dhcp_info.sh
  - content: |
      #!/bin/bash
      # SPDX-License-Identifier: GPL-2.0

      # This example script retrieves the DHCP state of a given interface.
      # In the interest of keeping the KVP daemon code free of distro specific
      # information; the kvp daemon code invokes this external script to gather
      # DHCP setting for the specific interface.
      #
      # Input: Name of the interface
      #
      # Output: The script prints the string "Enabled" to stdout to indicate
      #	that DHCP is enabled on the interface. If DHCP is not enabled,
      #	the script prints the string "Disabled" to stdout.
      #
      # Each Distro is expected to implement this script in a distro specific
      # fashion. For instance, on Distros that ship with Network Manager enabled,
      # this script can be based on the Network Manager APIs for retrieving DHCP
      # information.

      # RedHat based systems
      #if_file="/etc/sysconfig/network-scripts/ifcfg-"$1
      # Debian based systems
      if_file=`"/etc/network/interfaces.d/*`"

      dhcp=`$(grep `"dhcp`" `$if_file 2>/dev/null)

      if [ "$dhcp" != "" ];
      then
      echo "Enabled"
      else
      echo "Disabled"
      fi
    path: /usr/libexec/hypervkvpd/hv_get_dhcp_info
$(if ($null -ne $network_write_files) { $network_write_files
})

manage_etc_hosts: true
manage_resolv_conf: true

resolv_conf:
$(if ($NameServers.Contains("1.1.1.1")) { "  # cloudflare dns, src: https://1.1.1.1/dns/" }
)  nameservers: ['$( $NameServers.Split(",") -join "', '" )']
  searchdomains:
    - $($DomainName)
  domain: $($DomainName)

power_state:
  mode: $($CloudInitPowerState)
  message: Provisioning finished, will $($CloudInitPowerState) ...
  timeout: 15
"@

Write-Verbose "Userdata:"
Write-Verbose $userdata
Write-Verbose ""

# override default userdata with custom yaml file: $CustomUserDataYamlFile
# the will be parsed for any powershell variables, src: https://deadroot.info/scripts/2018/09/04/PowerShell-Templating
if (-not [string]::IsNullOrEmpty($CustomUserDataYamlFile) -and (Test-Path $CustomUserDataYamlFile)) {
  Write-Verbose "Using custom userdata yaml $CustomUserDataYamlFile"
  $userdata = $ExecutionContext.InvokeCommand.ExpandString( $(Get-Content $CustomUserDataYamlFile -Raw) ) # parse variables
}

if ($ImageTypeAzure) {
  # cloud-init configuration that will be merged, see https://cloudinit.readthedocs.io/en/latest/topics/datasources/azure.html
  $dscfg = @"
datasource:
 Azure:
  agent_command: ["/bin/systemctl", "disable walinuxagent.service"]
# agent_command: __builtin__
  apply_network_config: false
#  data_dir: /var/lib/waagent
#  dhclient_lease_file: /var/lib/dhcp/dhclient.eth0.leases
#  disk_aliases:
#      ephemeral0: /dev/disk/cloud/azure_resource
#  hostname_bounce:
#      interface: eth0
#      command: builtin
#      policy: true
#      hostname_command: hostname
  set_hostname: false
"@

  # src https://github.com/Azure/WALinuxAgent/blob/develop/tests/data/ovf-env.xml
  # src2: https://github.com/canonical/cloud-init/blob/5e6ecc615318b48e2b14c2fd1f78571522848b4e/tests/unittests/sources/test_azure.py#L328
  $ovfenvxml = [xml]@"
<?xml version="1.0" encoding="utf-8"?>
<ns0:Environment xmlns="http://schemas.dmtf.org/ovf/environment/1"
    xmlns:ns0="http://schemas.dmtf.org/ovf/environment/1"
    xmlns:ns1="http://schemas.microsoft.com/windowsazure"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <ns1:ProvisioningSection>
    <ns1:Version>1.0</ns1:Version>
    <ns1:LinuxProvisioningConfigurationSet>
      <ns1:ConfigurationSetType>LinuxProvisioningConfiguration</ns1:ConfigurationSetType>
        <ns1:HostName>$($VMHostname)</ns1:HostName>
        <ns1:UserName>$($GuestAdminUsername)</ns1:UserName>
        <ns1:UserPassword>$($GuestAdminPassword)</ns1:UserPassword>
        <ns1:DisableSshPasswordAuthentication>false</ns1:DisableSshPasswordAuthentication>
        <ns1:CustomData>$([Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($userdata)))</ns1:CustomData>
        <dscfg>$([Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($dscfg)))</dscfg>
        <!-- TODO add ssh key provisioning support -->
        <!--
            <SSH>
              <PublicKeys>
                <PublicKey>
                  <Fingerprint>EB0C0AB4B2D5FC35F2F0658D19F44C8283E2DD62</Fingerprint>
                  <Path>$HOME/UserName/.ssh/authorized_keys</Path>
                  <Value>ssh-rsa AAAANOTAREALKEY== foo@bar.local</Value>
                </PublicKey>
              </PublicKeys>
              <KeyPairs>
                <KeyPair>
                  <Fingerprint>EB0C0AB4B2D5FC35F2F0658D19F44C8283E2DD62</Fingerprint>
                  <Path>$HOME/UserName/.ssh/id_rsa</Path>
                </KeyPair>
              </KeyPairs>
            </SSH>
        -->
    </ns1:LinuxProvisioningConfigurationSet>
  </ns1:ProvisioningSection>

  <ns1:PlatformSettingsSection>
    <ns1:Version>1.0</ns1:Version>
    <ns1:PlatformSettings>
      <ns1:KmsServerHostname>kms.core.windows.net</ns1:KmsServerHostname>
      <ns1:ProvisionGuestAgent>false</ns1:ProvisionGuestAgent>
      <ns1:GuestAgentPackageName xsi:nil="true" />
			<ns1:PreprovisionedVm>true</ns1:PreprovisionedVm>
      <ns1:PreprovisionedVMType>Unknown</ns1:PreprovisionedVMType> <!-- https://github.com/canonical/cloud-init/blob/5e6ecc615318b48e2b14c2fd1f78571522848b4e/cloudinit/sources/DataSourceAzure.py#L94 -->
    </ns1:PlatformSettings>
  </ns1:PlatformSettingsSection>
</ns0:Environment>
"@
}

# Make temp location for iso image
mkdir -Path "$($tempPath)\Bits"  | out-null

# Output metadata, networkconfig and userdata to file on disk
Set-Content "$($tempPath)\Bits\meta-data" ([byte[]][char[]] "$metadata") -Encoding Byte
if (($NetAutoconfig -eq $false) -and
   (($NetConfigType -ieq "v1") -or ($NetConfigType -ieq "v2"))) {
  Set-Content "$($tempPath)\Bits\network-config" ([byte[]][char[]] "$networkconfig") -Encoding Byte
}
Set-Content "$($tempPath)\Bits\user-data" ([byte[]][char[]] "$userdata") -Encoding Byte
if ($ImageTypeAzure) {
  $ovfenvxml.Save("$($tempPath)\Bits\ovf-env.xml");
}

# Create meta data ISO image, src: https://cloudinit.readthedocs.io/en/latest/topics/datasources/nocloud.html
# both azure and nocloud support same cdrom filesystem https://github.com/canonical/cloud-init/blob/606a0a7c278d8c93170f0b5fb1ce149be3349435/cloudinit/sources/DataSourceAzure.py#L1972
Write-Host "Creating metadata iso for VM provisioning... " -NoNewline
$metaDataIso = "$($VMStoragePath)\$($VMName)-metadata.iso"
Write-Verbose "Filename: $metaDataIso"
cleanupFile $metaDataIso

Start-Process `
  -FilePath $oscdimgPath `
  -ArgumentList  "`"$($tempPath)\Bits`"","`"$metaDataIso`"","-lCIDATA","-d","-n" `
  -Wait -NoNewWindow `
  -RedirectStandardOutput "$($tempPath)\oscdimg.log" `
  -RedirectStandardError  "$($tempPath)\oscdimg-err.log"

if (!(test-path "$metaDataIso")) {throw "Error creating metadata iso"}
Write-Verbose "Metadata iso written"
Write-Host -ForegroundColor Green " Done."

# storage location for base images
$ImageCachePath = Join-Path $PSScriptRoot $("cache\CloudImage-$ImageOS-$ImageVersion")
if (!(test-path $ImageCachePath)) {mkdir -Path $ImageCachePath | out-null}

# Get the timestamp of the target build on the cloud-images site
$BaseImageStampFile = join-path $ImageCachePath "baseimagetimestamp.txt"
[string]$stamp = ''
if (test-path $BaseImageStampFile) {
  $stamp = (Get-Content -Path $BaseImageStampFile | Out-String).Trim()
  Write-Verbose "Timestamp from cache: $stamp"
}
if ($BaseImageCheckForUpdate -or ($stamp -eq '')) {
  $stamp = (Invoke-WebRequest -UseBasicParsing "$($ImagePath).$($ImageManifestSuffix)").BaseResponse.LastModified.ToUniversalTime().ToString("yyyyMMddHHmmss")
  Set-Content -path $BaseImageStampFile -value $stamp -force
  Write-Verbose "Timestamp from web (new): $stamp"
}

# check if local cached cloud image is the target one per $stamp
if (!(test-path "$($ImageCachePath)\$($ImageOS)-$($stamp).$($ImageFileExtension)") `
  -and !(test-path "$($ImageCachePath)\$($ImageOS)-$($stamp).vhd") # download only if VHD of requested $stamp version is not present in cache 
) {
  try {
    # If we do not have a matching image - delete the old ones and download the new one
    Write-Verbose "Did not find: $($ImageCachePath)\$($ImageOS)-$($stamp).$($ImageFileExtension)"
    Write-Host 'Removing old images from cache...' -NoNewline
    Remove-Item "$($ImageCachePath)" -Exclude 'baseimagetimestamp.txt',"$($ImageOS)-$($stamp).*" -Recurse -Force
    Write-Host -ForegroundColor Green " Done."

    # get headers for content length
    Write-Host 'Check new image size ...' -NoNewline
    $response = Invoke-WebRequest "$($ImagePath).$($ImageFileExtension)" -UseBasicParsing -Method Head
    $downloadSize = [int]$response.Headers["Content-Length"]
    Write-Host -ForegroundColor Green " Done."

    Write-Host "Downloading new Cloud image ($([int]($downloadSize / 1024 / 1024)) MB)..." -NoNewline
    Write-Verbose $(Get-Date)
    $ProgressPreference = "SilentlyContinue" #Disable progress indicator because it is causing Invoke-WebRequest to be very slow
    # download new image
    Invoke-WebRequest "$($ImagePath).$($ImageFileExtension)" -OutFile "$($ImageCachePath)\$($ImageOS)-$($stamp).$($ImageFileExtension).tmp" -UseBasicParsing
    $ProgressPreference = "Continue" #Restore progress indicator.
    # rename from .tmp to $($ImageFileExtension)
    Remove-Item "$($ImageCachePath)\$($ImageOS)-$($stamp).$($ImageFileExtension)" -Force -ErrorAction 'SilentlyContinue'
    Rename-Item -path "$($ImageCachePath)\$($ImageOS)-$($stamp).$($ImageFileExtension).tmp" `
      -newname "$($ImageOS)-$($stamp).$($ImageFileExtension)"
    Write-Host -ForegroundColor Green " Done."

    # check file hash
    Write-Host "Checking file hash for downloaded image..." -NoNewline
    Write-Verbose $(Get-Date)
    $hashSums = [System.Text.Encoding]::UTF8.GetString((Invoke-WebRequest $ImageHashPath -UseBasicParsing).Content)
    Switch -Wildcard ($ImageHashPath) {
      '*SHA256*' {
        $fileHash = Get-FileHash "$($ImageCachePath)\$($ImageOS)-$($stamp).$($ImageFileExtension)" -Algorithm SHA256
      }
      '*SHA512*' {
        $fileHash = Get-FileHash "$($ImageCachePath)\$($ImageOS)-$($stamp).$($ImageFileExtension)" -Algorithm SHA512
      }
      default {throw "$ImageHashPath not supported."}
    }
    if (($hashSums | Select-String -pattern $fileHash.Hash -SimpleMatch).Count -eq 0) {throw "File hash check failed"}
    Write-Verbose $(Get-Date)
    Write-Host -ForegroundColor Green " Done."

  }
  catch {
    cleanupFile "$($ImageCachePath)\$($ImageOS)-$($stamp).$($ImageFileExtension)"
    $ErrorMessage = $_.Exception.Message
    Write-Host "Error: $ErrorMessage"
    exit 1
  }
}

# check if image is extracted already
if (!(test-path "$($ImageCachePath)\$($ImageOS)-$($stamp).vhd")) {
  try {
    if ($ImageFileExtension.EndsWith("zip")) {
      Write-Host 'Expanding archive...' -NoNewline
      Expand-Archive -Path "$($ImageCachePath)\$($ImageOS)-$($stamp).$($ImageFileExtension)" -DestinationPath "$ImageCachePath" -Force
    } elseif (($ImageFileExtension.EndsWith("tar.gz")) -or ($ImageFileExtension.EndsWith("tar.xz"))) {
      Write-Host 'Expanding archive using bsdtar...' -NoNewline
      # using bsdtar - src: https://github.com/libarchive/libarchive/
      # src: https://unix.stackexchange.com/a/23746/353700
      #& $bsdtarPath "-x -C `"$($ImageCachePath)`" -f `"$($ImageCachePath)\$($ImageOS)-$($stamp).$($ImageFileExtension)`""
      Start-Process `
        -FilePath $bsdtarPath `
        -ArgumentList  "-x","-C `"$($ImageCachePath)`"","-f `"$($ImageCachePath)\$($ImageOS)-$($stamp).$($ImageFileExtension)`"" `
        -Wait -NoNewWindow `
        -RedirectStandardOutput "$($tempPath)\bsdtar.log"
    } elseif ($ImageFileExtension.EndsWith("img")) {
      Write-Verbose 'No need for archive extracting'
    } else {
      Write-Warning "Unsupported image in archive"
      exit 1
    }

    # rename bionic-server-cloudimg-amd64.vhd (or however they pack it) to $ImageFileName.vhd
    $fileExpanded = Get-ChildItem "$($ImageCachePath)\*.vhd","$($ImageCachePath)\*.vhdx","$($ImageCachePath)\*.raw","$($ImageCachePath)\*.img" -File | Sort-Object LastWriteTime | Select-Object -last 1
    Write-Verbose "Expanded file name: $fileExpanded"
    if ($fileExpanded -like "*.vhd") {
      Rename-Item -path $fileExpanded -newname "$ImageFileName.vhd"
    } elseif ($fileExpanded -like "*.raw") {
      Write-Host "qemu-img info for source untouched cloud image: "
      & $qemuImgPath info "$fileExpanded"
      Write-Verbose "qemu-img convert to vhd"
      Write-Verbose "$qemuImgPath convert -f raw $fileExpanded -O vpc $($ImageCachePath)\$ImageFileName.vhd"
      & $qemuImgPath convert -f raw "$fileExpanded" -O vpc "$($ImageCachePath)\$($ImageFileName).vhd"
      # remove source image after conversion
      Remove-Item "$fileExpanded" -force
    } elseif ($fileExpanded -like "*.img") {
      Write-Host "qemu-img info for source untouched cloud image: "
      & $qemuImgPath info "$fileExpanded"
      Write-Verbose "qemu-img convert to vhd"
      Write-Verbose "$qemuImgPath convert -f qcow2 $fileExpanded -O vpc $($ImageCachePath)\$ImageFileName.vhd"
      & $qemuImgPath convert -f qcow2 "$fileExpanded" -O vpc "$($ImageCachePath)\$($ImageFileName).vhd"
      # remove source image after conversion
      Remove-Item "$fileExpanded" -force
    } else {
      Write-Warning "Unsupported disk image extracted."
      exit 1
    }
    Write-Host -ForegroundColor Green " Done."

    Write-Host 'Convert VHD fixed to VHD dynamic...' -NoNewline
    try {
      Convert-VHD -Path "$($ImageCachePath)\$ImageFileName.vhd" -DestinationPath "$($ImageCachePath)\$($ImageOS)-$($stamp).vhd" -VHDType Dynamic -DeleteSource
      Write-Host -ForegroundColor Green " Done."
    } catch {
      Write-Warning $_
      Write-Warning "Failed to convert the disk using 'Convert-VHD', falling back to qemu-img... "
      Write-Host "qemu-img info for source untouched cloud image: "
      & $qemuImgPath info "$($ImageCachePath)\$ImageFileName.vhd"
      Write-Verbose "qemu-img convert to vhd"
      & $qemuImgPath convert "$($ImageCachePath)\$ImageFileName.vhd" -O vpc -o subformat=dynamic "$($ImageCachePath)\$($ImageOS)-$($stamp).vhd"
      # remove source image after conversion
      Remove-Item "$($ImageCachePath)\$ImageFileName.vhd" -force

      #Write-Warning "Failed to convert the disk, will use it as is..."
      #Rename-Item -path "$($ImageCachePath)\$ImageFileName.vhd" -newname "$($ImageCachePath)\$($ImageOS)-$($stamp).vhd" # not VHDX
      Write-Host -ForegroundColor Green " Done."
    }

    # if not debugging then delete downloaded cloud image to save space. Once the image is extracted and converted to VHD it is not needed anymore
    if (-not [bool]($PSCmdlet.MyInvocation.BoundParameters["Debug"]).IsPresent) {
      Write-Verbose "cache folder: about to delete all but txt and vhd files"
      Get-ChildItem "$($ImageCachePath)" -Exclude @("*.txt","*.vhd") | Remove-Item -Force
    }

    # since VHD's are sitting in the cache lets make them as small as posible
    & .\Compact-VHD.ps1 -Path "$($ImageCachePath)\$($ImageOS)-$($stamp).vhd"

    if ($ConvertImageToNoCloud) {
      Write-Host 'Modify VHD and convert cloud-init to NoCloud ...' -NoNewline
      $process = Start-Process `
      -FilePath cmd.exe `
      -Wait -PassThru -NoNewWindow `
      -ArgumentList "/c `"`"$(Join-Path $PSScriptRoot "wsl-convert-vhd-nocloud.cmd")`" `"$($ImageCachePath)\$($ImageOS)-$($stamp).vhd`"`""
      # https://stackoverflow.com/a/16018287/1155121
      if ($process.ExitCode -ne 0) {
        throw "Failed to modify/convert VHD to NoCloud DataSource!"
      }
      Write-Host -ForegroundColor Green " Done."
    }

  }
  catch {
    cleanupFile "$($ImageCachePath)\$($ImageOS)-$($stamp).vhd"
    $ErrorMessage = $_.Exception.Message
    Write-Host "Error: $ErrorMessage"
    exit 1
  }
}

# File path for to-be provisioned VHD
$VMDiskPath = "$($VMStoragePath)\$($VMName).vhd"
if ($VMGeneration -eq 2) {
  $VMDiskPath = "$($VMStoragePath)\$($VMName).vhdx"
}
cleanupFile $VMDiskPath

# Prepare VHD... (could also use copy)
Write-Host "Prepare virtual disk..." -NoNewline
try {
  # block size bytes per recommendation https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/best-practices-for-running-linux-on-hyper-v
  Convert-VHD -Path "$($ImageCachePath)\$($ImageOS)-$($stamp).vhd" -DestinationPath $VMDiskPath -VHDType Dynamic -BlockSizeBytes 1MB
  Write-Host -ForegroundColor Green " Done."
  if ($VHDSizeBytes) {
    Write-Host "Resize VHD to $([int]($VHDSizeBytes / 1024 / 1024 / 1024)) GB..." -NoNewline
    Resize-VHD -Path $VMDiskPath -SizeBytes $VHDSizeBytes
    Write-Host -ForegroundColor Green " Done."
  }
} catch {
  Write-Warning "Failed to convert and resize, will just copy it ..."
  Copy-Item "$($ImageCachePath)\$($ImageOS)-$($stamp).vhd" -Destination $VMDiskPath
}

# Create new virtual machine and start it
Write-Host "Create VM..." -NoNewline
$vm = new-vm -Name $VMName -MemoryStartupBytes $VMMemoryStartupBytes `
               -Path "$VMMachinePath" `
               -VHDPath "$VMDiskPath" -Generation $VMGeneration `
               -BootDevice VHD -Version $VMVersion | out-null
Set-VMProcessor -VMName $VMName -Count $VMProcessorCount
If ($VMDynamicMemoryEnabled) {
  Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $VMDynamicMemoryEnabled -MaximumBytes $VMMaximumBytes -MinimumBytes $VMMinimumBytes
} else {
  Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $VMDynamicMemoryEnabled
}
# make sure VM has DVD drive needed for provisioning
if ($null -eq (Get-VMDvdDrive -VMName $VMName)) {
  Add-VMDvdDrive -VMName $VMName
}
Set-VMDvdDrive -VMName $VMName -Path "$metaDataIso"

If (($null -ne $virtualSwitchName) -and ($virtualSwitchName -ne "")) {
  Write-Verbose "Connecting VMnet adapter to virtual switch '$virtualSwitchName'..."
} else {
  Write-Verbose "No Virtual network switch given."
  $SwitchList = Get-VMSwitch | Select-Object Name
  If ($SwitchList.Count -eq 1 ) {
    Write-Verbose "Using single Virtual switch found: '$($SwitchList.Name)'"
    $virtualSwitchName = $SwitchList.Name
  } elseif (Get-VMSwitch | Select-Object Name | Select-String "Default Switch") {
    Write-Verbose "Multiple Switches found; using found 'Default Switch'"
    $virtualSwitchName = "Default Switch"
  }
}
If (($null -ne $virtualSwitchName) -and ($virtualSwitchName -ne "")) {
  Get-VMNetworkAdapter -VMName $VMName | Connect-VMNetworkAdapter -SwitchName "$virtualSwitchName"
} else {
  Write-Warning "No Virtual network switch given and could not automatically selected."
  Write-Warning "Please use parameter -virtualSwitchName 'Switch Name'."
  exit 1
}

if (($null -ne $VMStaticMacAddress) -and ($VMStaticMacAddress -ne "")) {
  Write-Verbose "Setting static MAC address '$VMStaticMacAddress' on VMnet adapter..."
  Set-VMNetworkAdapter -VMName $VMName -StaticMacAddress $VMStaticMacAddress
} else {
  Write-Verbose "Using default dynamic MAC address asignment."
}

$VMNetworkAdapter = Get-VMNetworkAdapter -VMName $VMName
$VMNetworkAdapterName = $VMNetworkAdapter.Name
If ((($null -ne $VMVlanID) -and ([int]($VMVlanID) -ne 0)) -or
   ((($null -ne $VMNativeVlanID) -and ([int]($VMNativeVlanID) -ne 0)) -and
    (($null -ne $VMAllowedVlanIDList) -and ($VMAllowedVlanIDList -ne "")))) {
  If (($null -ne $VMNativeVlanID) -and ([int]($VMNativeVlanID) -ne 0) -and
      ($null -ne $VMAllowedVlanIDList) -and ($VMAllowedVlanIDList -ne "")) {
    Write-Host "Setting native Vlan ID $VMNativeVlanID with trunk Vlan IDs '$VMAllowedVlanIDList'"
    Write-Host "on virtual network adapter '$VMNetworkAdapterName'..."
    Set-VMNetworkAdapterVlan -VMName $VMName -VMNetworkAdapterName "$VMNetworkAdapterName" `
                -Trunk  -NativeVlanID $VMNativeVlanID -AllowedVlanIDList $VMAllowedVlanIDList
  } else {
    Write-Host "Setting Vlan ID $VMVlanID on virtual network adapter '$VMNetworkAdapterName'..."
    Set-VMNetworkAdapterVlan -VMName $VMName -VMNetworkAdapterName "$VMNetworkAdapterName" `
                -Access -VlanId $VMVlanID
  }
} else {
  Write-Verbose "Let virtual network adapter '$VMNetworkAdapterName' untagged."
}

if ($VMVMQ) {
    Write-Host "Enable Virtual Machine Queue (100)... " -NoNewline
    Set-VMNetworkAdapter -VMName $VMName -VmqWeight 100
    Write-Host -ForegroundColor Green " Done."
}

if ($VMDhcpGuard) {
    Write-Host "Enable DHCP Guard... " -NoNewline
    Set-VMNetworkAdapter -VMName $VMName -DhcpGuard On
    Write-Host -ForegroundColor Green " Done."
}

if ($VMRouterGuard) {
    Write-Host "Enable Router Guard... " -NoNewline
    Set-VMNetworkAdapter -VMName $VMName -RouterGuard On
    Write-Host -ForegroundColor Green " Done."
}

if ($VMAllowTeaming) {
    Write-Host "Enable Allow Teaming... " -NoNewline
    Set-VMNetworkAdapter -VMName $VMName -AllowTeaming On
    Write-Host -ForegroundColor Green " Done."
}

if ($VMPassthru) {
    Write-Host "Enable Passthru... " -NoNewline
    Set-VMNetworkAdapter -VMName $VMName -Passthru
    Write-Host -ForegroundColor Green " Done."
}

#if (($null -ne $VMMaximumBandwidth) -and ($([int]($VMMaximumBandwidth)) -gt 0)) {
#  if (($null -ne $VMMinimumBandwidthWeight) -and ($([int]($VMMinimumBandwidthWeight)) -gt 0)) {
#    Write-Host "Set maximum bandwith to $([int]($VMMaximumBandwidth)) with minimum bandwidth weigth $([int]($VMMinimumBandwidthWeight))" -NoNewline
#    Set-VMNetworkAdapter -VMName $VMName -MaximumBandwidth $([int]($VMMaximumBandwidth)) `n
#                                         -MinimumBandwidthWeight $([int]($VMMinimumBandwidthWeight))
#  } elseif (($null -ne $VMMinimumBandwidthAbsolute) -and ($([int]($VMMinimumBandwidthAbsolute)) -gt 0) `
#           -and ($([int]($VMMaximumBandwidth)) -gt ($([int]($VMMinimumBandwidthAbsolute))))) {
#    Write-Host "Set maximum bandwith to $([int]($VMMaximumBandwidth)) with absolute minimum bandwidth $([int]($VMMinimumBandwidthAbsolute)) " -NoNewline
#    Set-VMNetworkAdapter -VMName $VMName -MaximumBandwidth $([int]($VMMaximumBandwidth)) `n
#                                         -MinimumBandwidthAbsolute $([int]($VMMinimumBandwidthAbsolute))
#  } else {
#    Write-Warning "Wrong or missing bandwith parameterrs; given values are:"
#    Write-Warning "    MaximumBandwidth:         $([int]($VMMaximumBandwidth))"
#    Write-Warning "    MinimumBandwidthAbsolute: $([int]($VMMinimumBandwidthAbsolute))"
#    Write-Warning "    MinimumBandwidthWeight:   $([int]($VMMinimumBandwidthWeight))"
#  }
#}

if ($VMMacAddressSpoofing) {
  Write-Verbose "Enable MAC address Spoofing on VMnet adapter..."
  Set-VMNetworkAdapter -VMName $VMName -MacAddressSpoofing On
} else {
  Write-Verbose "Using default dynamic MAC address asignment."
}

if ($VMExposeVirtualizationExtensions) {
  Write-Host "Expose Virtualization Extensions to Guest ..."
  Set-VMProcessor -VMName $VMName -ExposeVirtualizationExtensions $true
  Write-Host -ForegroundColor Green " Done."
}

# hyper-v gen2 specific features
if ($VMGeneration -eq 2) {
  Write-Verbose "Setting secureboot for Hyper-V Gen2..."
  # configure secure boot, src: https://www.altaro.com/hyper-v/hyper-v-2016-support-linux-secure-boot/
  Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplateId ([guid]'272e7447-90a4-4563-a4b9-8e4ab00526ce')

  if ($(Get-VMHost).EnableEnhancedSessionMode -eq $true) {
    # Ubuntu 18.04+ supports enhanced session and so Debian 10/11
    Write-Verbose "Enable enhanced session mode..."
    Set-VM -VMName $VMName -EnhancedSessionTransportType HvSocket
  } else {
    Write-Verbose "Enhanced session mode not enabled because host has not activated support for it."
  }

  # For copy&paste service (hv_fcopy_daemon) between host and guest we need also this
  # guest service interface activation which has sadly language dependent setup:
  # PS> Enable-VMIntegrationService -VMName $VMName -Name "Guest Service Interface"
  # PS> Enable-VMIntegrationService -VMName $VMName -Name "Gastdienstschnittstelle"
  # https://administrator.de/forum/hyper-v-cmdlet-powershell-sprachproblem-318175.html
  Get-VMIntegrationService -VMName $VMName `
            | Where-Object {$_.Name -match 'Gastdienstschnittstelle|Guest Service Interface'} `
            | Enable-VMIntegrationService
}

# disable automatic checkpoints, https://github.com/hashicorp/vagrant/issues/10251#issuecomment-425734374
if ($null -ne (Get-Command Hyper-V\Set-VM).Parameters["AutomaticCheckpointsEnabled"]){
  Hyper-V\Set-VM -VMName $VMName -AutomaticCheckpointsEnabled $false
}

Write-Host -ForegroundColor Green " Done."

# https://social.technet.microsoft.com/Forums/en-US/d285d517-6430-49ba-b953-70ae8f3dce98/guest-asset-tag?forum=winserverhyperv
Write-Host "Set SMBIOS serial number ..."
$vmserial_smbios = $VmMachineId
if ($ImageTypeAzure) {
  # set chassis asset tag to Azure constant as documented in https://github.com/canonical/cloud-init/blob/5e6ecc615318b48e2b14c2fd1f78571522848b4e/cloudinit/sources/helpers/azure.py#L1082
  Write-Host "Set Azure chasis asset tag ..." -NoNewline
  # https://social.technet.microsoft.com/Forums/en-US/d285d517-6430-49ba-b953-70ae8f3dce98/guest-asset-tag?forum=winserverhyperv
  & .\Set-VMAdvancedSettings.ps1 -VM $VMName -ChassisAssetTag '7783-7084-3265-9085-8269-3286-77' -Force -Verbose:$verbose
  Write-Host -ForegroundColor Green " Done."

  # also try to enable NoCloud via SMBIOS  https://cloudinit.readthedocs.io/en/22.4.2/topics/datasources/nocloud.html
  $vmserial_smbios = 'ds=nocloud'
}
Write-Host "SMBIOS SN: $vmserial_smbios"
& .\Set-VMAdvancedSettings.ps1 -VM $VMName -BIOSSerialNumber $vmserial_smbios -ChassisSerialNumber $vmserial_smbios -Force -Verbose:$verbose
Write-Host -ForegroundColor Green " Done."

# redirect com port to pipe for VM serial output, src: https://superuser.com/a/1276263/145585
Set-VMComPort -VMName $VMName -Path \\.\pipe\$VMName-com1 -Number 1
Write-Verbose "Serial connection: \\.\pipe\$VMName-com1"

# enable guest integration services (could be used for Copy-VMFile)
Get-VMIntegrationService -VMName $VMName | Where-Object Name -match 'guest' | Enable-VMIntegrationService

# Clean up temp directory
Remove-Item -Path $tempPath -Recurse -Force

# Make checkpoint when debugging https://stackoverflow.com/a/16297557/1155121
if ($PSBoundParameters.Debug -eq $true) {
  # make VM snapshot before 1st run
  Write-Host "Creating checkpoint..." -NoNewline
  Checkpoint-VM -Name $VMName -SnapshotName Initial
  Write-Host -ForegroundColor Green " Done."
}

Write-Host "Starting VM..." -NoNewline
Start-VM $VMName
Write-Host -ForegroundColor Green " Done."

# TODO check if VM has got an IP ADDR, if address is missing then write error because provisioning won't work without IP, src: https://stackoverflow.com/a/27999072/1155121


if ($ShowSerialConsoleWindow) {
  # start putty or hvc.exe with serial connection to newly created VM
  try {
    Get-Command "putty" | out-null
    start-sleep -seconds 2
    & "PuTTY" -serial "\\.\pipe\$VMName-com1" -sercfg "115200,8,n,1,N"
  }
  catch {
    Write-Verbose "putty not available, will try Windows Terminal + hvc.exe"
    Start-Process "wt.exe" "new-tab cmd /k hvc.exe serial $VMName" -WindowStyle Normal
  }

}

if ($ShowVmConnectWindow) {
  # Open up VMConnect
  Start-Process "vmconnect" "localhost","$VMName" -WindowStyle Normal
}

Write-Host "Done"
