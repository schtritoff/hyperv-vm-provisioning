<#
.SYNOPSIS
  Provision Ubuntu Cloud images on Hyper-V
.EXAMPLE
  PS C:\> .\New-UbuntuCloudImageVM.ps1 -VMProcessorCount 2 -VMMemoryStartupBytes 2GB -VHDSizeBytes 60GB -VMName "ubuntu-1" -UbuntuVersion "20.04" -VirtualSwitchName "SW01" -VMGeneration 2
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

[CmdletBinding()]
param(
  [string] $VMName = "UbuntuVm",
  [int] $VMGeneration = 1, # create gen1 hyper-v machine because of portability to Azure (https://docs.microsoft.com/en-us/azure/virtual-machines/windows/prepare-for-upload-vhd-image)
  [int] $VMProcessorCount = 1,
  [uint64] $VMMemoryStartupBytes = 1024MB,
  [uint64] $VHDSizeBytes = 30GB,
  [string] $VirtualSwitchName = '',
  [string] $VMVersion = "8.0", # version 8.0 for hyper-v 2016 compatibility , check all possible values with Get-VMHostSupportedVersion
  [string] $VMHostname = $VMName,
  [string] $DomainName = "domain.local",
  [string] $CustomUserDataYamlFile,
  [string] $GuestAdminUsername = "user",
  [string] $GuestAdminPassword = "Passw0rd",
  [string] $UbuntuVersion = "20.04", # $UbuntuName ="focal" # 20.04 LTS , $UbuntuName="bionic" # 18.04 LTS
  [bool] $BaseImageCheckForUpdate = $true, # check for newer image at Ubuntu cloud-images site
  [bool] $BaseImageCleanup = $true, # delete old vhd image. Set to false if using (TODO) differencing VHD
  [switch] $ShowSerialConsoleWindow = $false,
  [switch] $ShowVmConnectWindow = $false,
  [switch] $Force = $false
)

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

$FQDN = $VMHostname + "." + $DomainName
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
$qemuImgPath = Join-Path $PSScriptRoot "tools\qemu-img\qemu-img.exe"

# Windows version of tar for extracting tar.gz files, src: https://github.com/libarchive/libarchive
$bsdtarPath = Join-Path $PSScriptRoot "tools\bsdtar.exe"

# Update this to the release of Ubuntu that you want
Switch ($UbuntuVersion) {
  "18.04" {
    $ubuntuUrlRoot = "http://cloud-images.ubuntu.com/releases/18.04/release/" # latest
    $ubuntuFileName = "ubuntu-18.04-server-cloudimg-amd64-azure"
    $ubuntuFileExtension = "vhd.tar.gz"
  }
  "20.04" {
    $ubuntuUrlRoot = "http://cloud-images.ubuntu.com/releases/20.04/release/"
    $ubuntuFileName = "ubuntu-20.04-server-cloudimg-amd64-azure" # should contain "vhd.*" version
    $ubuntuFileExtension = "vhd.zip" # or "vhd.tar.gz" on older releases
  }
  default {throw "Ubuntu version $UbuntuVersion not supported."}
}

# Manifest file is used for version check based on last modified HTTP header
$ubuntuManifestSuffix = "vhd.manifest"
$ubuntuPath = "$($ubuntuUrlRoot)$($ubuntuFileName)"
$ubuntuHash = "$($ubuntuUrlRoot)SHA256SUMS"

# Get default Virtual Hard Disk path (requires administrative privileges)
$vmms = Get-WmiObject -namespace root\virtualization\v2 Msvm_VirtualSystemManagementService
$vmmsSettings = Get-WmiObject -namespace root\virtualization\v2 Msvm_VirtualSystemManagementServiceSettingData
$VMStoragePath = $vmmsSettings.DefaultVirtualHardDiskPath
# fallback
if (-not $VMStoragePath) {
  $VMStoragePath = "C:\Hyper-V"
}
if (!(test-path $VMStoragePath)) {mkdir -Path $VMStoragePath | out-null}

# storage location for base images
$imageCachePath = Join-Path $PSScriptRoot $(".\cache\uci-" + $UbuntuVersion)
if (!(test-path $imageCachePath)) {mkdir -Path $imageCachePath | out-null}

# Get the timestamp of the latest build on the Ubuntu cloud-images site
$BaseImageStampFile = join-path $imageCachePath "baseimagetimestamp.txt"
[string]$stamp = ''
if (test-path $BaseImageStampFile) {
  $stamp = (Get-Content -Path $BaseImageStampFile | Out-String).Trim()
  Write-Verbose "Timestamp from cache: $stamp"
}
if ($BaseImageCheckForUpdate -or ($stamp -eq '')) {
  $stamp = (Invoke-WebRequest -UseBasicParsing "$($ubuntuPath).$($ubuntuManifestSuffix)").BaseResponse.LastModified.ToUniversalTime().ToString("yyyyMMddHHmmss")
  Set-Content -path $BaseImageStampFile -value $stamp -force
  Write-Verbose "Timestamp from web (new): $stamp"
}

# Delete the VM if it is around
$vm = Get-VM -VMName $VMName -ErrorAction 'SilentlyContinue'
if ($vm) {
  & .\Cleanup-VM.ps1 $VMName -Force:$Force
}

# metadata for cloud-init
$metadata = @"
instance-id: $($VmMachineId)
local-hostname: $($VMHostname)
"@
Write-Verbose $metadata

# userdata for cloud-init, https://cloudinit.readthedocs.io/en/latest/topics/examples.html
$userdata = @"
#cloud-config
hostname: $($VMHostname)
fqdn: $($FQDN)
password: $($GuestAdminPassword)
chpasswd: { expire: False }
ssh_pwauth: True
runcmd:
# - [ sh, -c, echo "127.0.0.1 localhost" >> /etc/hosts ]
# force password change on 1st boot
# - [ chage, -d, 0, $($GuestAdminUsername) ]
# remove metadata iso
 - [ sh, -c, eject ]
# dont start waagent service since it useful only for azure/scvmm
 - 'systemctl stop walinuxagent.service'
 - 'systemctl disable walinuxagent.service'
# disable cloud init on next boot (https://cloudinit.readthedocs.io/en/latest/topics/boot.html, https://askubuntu.com/a/1047618)
 - [ sh, -c, touch /etc/cloud/cloud-init.disabled ]
# set locale
 - 'locale-gen en_US.UTF-8'
 - 'update-locale LANG=en_US.UTF-8'
# change keyboard layout, src: https://askubuntu.com/a/784816
 - [ sh, -c, sed -i 's/XKBLAYOUT=\"\w*"/XKBLAYOUT=\"'us'\"/g' /etc/default/keyboard ]
# set timezone
 - 'timedatectl set-timezone Europe/London'

manage_resolv_conf: true

resolv_conf:
# cloudflare dns, src: https://1.1.1.1/dns/
  nameservers: ['1.1.1.1 ', '1.0.0.1']
  searchdomains:
    - $($DomainName)
  domain: $($DomainName)

power_state:
 mode: reboot
 message: Provisioning finished, rebooting ...
 timeout: 15
"@

# override default userdata with custom yaml file: $CustomUserDataYamlFile
# the will be parsed for any powershell variables, src: https://deadroot.info/scripts/2018/09/04/PowerShell-Templating
if (-not [string]::IsNullOrEmpty($CustomUserDataYamlFile) -and (Test-Path $CustomUserDataYamlFile)) {
  Write-Verbose "Using custom userdata yaml $CustomUserDataYamlFile"
  $userdata  = $ExecutionContext.InvokeCommand.ExpandString( $(Get-Content $CustomUserDataYamlFile -Raw) ) # parse variables
}

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
$ovfenvxml = [xml]@"
<?xml version="1.0" encoding="utf-8"?>
<Environment xmlns="http://schemas.dmtf.org/ovf/environment/1" xmlns:oe="http://schemas.dmtf.org/ovf/environment/1" xmlns:wa="http://schemas.microsoft.com/windowsazure" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <wa:ProvisioningSection>
   <wa:Version>1.0</wa:Version>
   <LinuxProvisioningConfigurationSet
      xmlns="http://schemas.microsoft.com/windowsazure"
      xmlns:i="http://www.w3.org/2001/XMLSchema-instance">
    <ConfigurationSetType>LinuxProvisioningConfiguration</ConfigurationSetType>
    <HostName>$($VMHostname)</HostName>
    <UserName>$($GuestAdminUsername)</UserName>
    <UserPassword>$($GuestAdminPassword)</UserPassword>
    <DisableSshPasswordAuthentication>false</DisableSshPasswordAuthentication>
    <CustomData>$([Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($userdata)))</CustomData>
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
    </LinuxProvisioningConfigurationSet>
  </wa:ProvisioningSection>
  <!--
  <wa:PlatformSettingsSection>
		<wa:Version>1.0</wa:Version>
		<wa:PlatformSettings>
			<wa:KmsServerHostname>kms.core.windows.net</wa:KmsServerHostname>
			<wa:ProvisionGuestAgent>false</wa:ProvisionGuestAgent>
			<wa:GuestAgentPackageName xsi:nil="true"/>
			<wa:RetainWindowsPEPassInUnattend>true</wa:RetainWindowsPEPassInUnattend>
			<wa:RetainOfflineServicingPassInUnattend>true</wa:RetainOfflineServicingPassInUnattend>
			<wa:PreprovisionedVm>false</wa:PreprovisionedVm>
		</wa:PlatformSettings>
	</wa:PlatformSettingsSection>
  -->
 </Environment>
"@

# Make temp location for iso image
mkdir -Path "$($tempPath)\Bits"  | out-null

# Output metadata and userdata to file on disk
Set-Content "$($tempPath)\Bits\meta-data" ([byte[]][char[]] "$metadata") -Encoding Byte
Set-Content "$($tempPath)\Bits\user-data" ([byte[]][char[]] "$userdata") -Encoding Byte
$ovfenvxml.Save("$($tempPath)\Bits\ovf-env.xml");

# Create meta data ISO image, src: https://cloudinit.readthedocs.io/en/latest/topics/datasources/nocloud.html
#,"-u1","-udfver200"
#& $oscdimgPath "$($tempPath)\Bits" "$($metaDataIso).2.iso" -u2 -udfver200
Write-Host "Creating metadata iso for VM provisioning..." -NoNewline
$metaDataIso = "$($VMStoragePath)\$($VMName)-metadata.iso"
Write-Verbose "Filename: $metaDataIso"
cleanupFile $metaDataIso
<# azure #>
Start-Process `
	-FilePath $oscdimgPath `
  -ArgumentList  "`"$($tempPath)\Bits`"","`"$metaDataIso`"","-u2","-udfver200" `
	-Wait -NoNewWindow `
	-RedirectStandardOutput "$($tempPath)\oscdimg.log" `
  -RedirectStandardError "$($tempPath)\oscdimg-error.log"

<# NoCloud
Start-Process `
	-FilePath $oscdimgPath `
  -ArgumentList  "`"$($tempPath)\Bits`"","`"$metaDataIso`"","-lCIDATA","-d","-n" `
	-Wait -NoNewWindow `
	-RedirectStandardOutput "$($tempPath)\oscdimg.log"
#>
if (!(test-path "$metaDataIso")) {throw "Error creating metadata iso"}
Write-Verbose "Metadata iso written"
Write-Host -ForegroundColor Green " Done."


# check if local cached cloud image is the most recent one
if (!(test-path "$($imageCachePath)\ubuntu-$($stamp).$($ubuntuFileExtension)")) {
  try {
    # If we do not have a matching image - delete the old ones and download the new one
    Write-Host 'Removing old images from cache...' -NoNewline
    Remove-Item "$($imageCachePath)\ubuntu-*.vhd*"
    Write-Host -ForegroundColor Green " Done."

    # get headers for content length
    Write-Host 'Check new image size ...' -NoNewline
    $response = Invoke-WebRequest "$($ubuntuPath).$($ubuntuFileExtension)" -UseBasicParsing -Method Head
    $downloadSize = [int]$response.Headers["Content-Length"]
    Write-Host -ForegroundColor Green " Done."

    Write-Host "Downloading new Ubuntu Azure Cloud image ($([int]($downloadSize / 1024 / 1024)) MB)..." -NoNewline
    Write-Verbose $(Get-Date)
    # download new image
    Invoke-WebRequest "$($ubuntuPath).$($ubuntuFileExtension)" -OutFile "$($imageCachePath)\ubuntu-$($stamp).$($ubuntuFileExtension).tmp" -UseBasicParsing
    # rename from .tmp to $($ubuntuFileExtension)
    Remove-Item "$($imageCachePath)\ubuntu-$($stamp).$($ubuntuFileExtension)" -Force -ErrorAction 'SilentlyContinue'
    Rename-Item -path "$($imageCachePath)\ubuntu-$($stamp).$($ubuntuFileExtension).tmp" `
      -newname "ubuntu-$($stamp).$($ubuntuFileExtension)"
    Write-Host -ForegroundColor Green " Done."

    # check file hash
    Write-Host "Checking file hash for downloaded image..." -NoNewline
    Write-Verbose $(Get-Date)
    $hashSums = [System.Text.Encoding]::UTF8.GetString((Invoke-WebRequest $ubuntuHash -UseBasicParsing).Content)
    $fileHash = Get-FileHash "$($imageCachePath)\ubuntu-$($stamp).$($ubuntuFileExtension)" -Algorithm SHA256
    if (($hashSums | Select-String -pattern $fileHash.Hash -SimpleMatch).Count -eq 0) {throw "File hash check failed"}
    Write-Verbose $(Get-Date)
    Write-Host -ForegroundColor Green " Done."

  }
  catch {
    cleanupFile "$($imageCachePath)\ubuntu-$($stamp).$($ubuntuFileExtension)"
    $ErrorMessage = $_.Exception.Message
    Write-Host "Error: $ErrorMessage"
    exit 1
  }
}

# check if image is extracted already
if (!(test-path "$($imageCachePath)\ubuntu-$($stamp).vhd")) {
  try {
    Write-Host 'Expanding archive...' -NoNewline
    if ($ubuntuFileExtension.Contains(".zip")) {
      Expand-Archive -Path "$($imageCachePath)\ubuntu-$($stamp).$($ubuntuFileExtension)" -DestinationPath "$imageCachePath" -Force
    } elseif ($ubuntuFileExtension.Contains(".tar.gz")) {
      # using bsdtar - src: https://github.com/libarchive/libarchive/
      # src: https://unix.stackexchange.com/a/23746/353700
      #& $bsdtarPath "-x -C `"$($imageCachePath)`" -f `"$($imageCachePath)\ubuntu-$($stamp).$($ubuntuFileExtension)`""
      Start-Process `
        -FilePath $bsdtarPath `
        -ArgumentList  "-x","-C `"$($imageCachePath)`"","-f `"$($imageCachePath)\ubuntu-$($stamp).$($ubuntuFileExtension)`"" `
        -Wait -NoNewWindow `
        -RedirectStandardOutput "$($tempPath)\bsdtar.log"
    } else {
      Write-Warning "Unsupported archive"
      exit 1
    }

    # rename bionic-server-cloudimg-amd64.vhd (or however they pack it) to $ubuntuFileName.vhd
    $fileExpanded = Get-ChildItem "$($imageCachePath)\*.vhd","$($imageCachePath)\*.vhdx" -File | Sort-Object LastWriteTime | Select-Object -last 1
    Write-Verbose "Expanded file name: $fileExpanded"
    Rename-Item -path $fileExpanded -newname "$ubuntuFileName.vhd"
    Write-Host -ForegroundColor Green " Done."

    Write-Host 'Convert VHD fixed to VDH dynamic...' -NoNewline
    try {
      Convert-VHD -Path "$($imageCachePath)\$ubuntuFileName.vhd" -DestinationPath "$($imageCachePath)\ubuntu-$($stamp).vhd" -VHDType Dynamic -DeleteSource
      Write-Host -ForegroundColor Green " Done."
    } catch {
      Write-Warning $_
      Write-Warning "Failed to convert the disk using 'Convert-VHD', falling back to qemu-img... "
      Write-Host "qemu-img info for source untouched cloud image: "
      & $qemuImgPath info "$($imageCachePath)\$ubuntuFileName.vhd"
      Write-Verbose "qemu-img convert to vhd"
      & $qemuImgPath convert "$($imageCachePath)\$ubuntuFileName.vhd" -O vpc -o subformat=dynamic "$($imageCachePath)\ubuntu-$($stamp).vhd"
      # remove source image after conversion
      Remove-Item "$($imageCachePath)\$ubuntuFileName.vhd" -force

      #Write-Warning "Failed to convert the disk, will use it as is..."
      #Rename-Item -path "$($imageCachePath)\$ubuntuFileName.vhd" -newname "$($imageCachePath)\ubuntu-$($stamp).vhd" # not VHDX
      Write-Host -ForegroundColor Green " Done."
    }
  }
  catch {
    cleanupFile "$($imageCachePath)\ubuntu-$($stamp).vhd"
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
  Convert-VHD -Path "$($imageCachePath)\ubuntu-$($stamp).vhd" -DestinationPath $VMDiskPath -VHDType Dynamic
  Write-Host -ForegroundColor Green " Done."
  if ($VHDSizeBytes -and ($VHDSizeBytes -gt 30GB)) {
    Write-Host "Resize VHD to $([int]($VHDSizeBytes / 1024 / 1024 / 1024)) GB..." -NoNewline
    Resize-VHD -Path $VMDiskPath -SizeBytes $VHDSizeBytes
    Write-Host -ForegroundColor Green " Done."
  }
} catch {
  Write-Warning "Failed to convert and resize, will just copy it ..."
  Copy-Item "$($imageCachePath)\ubuntu-$($stamp).vhd" -Destination $VMDiskPath
}

# Create new virtual machine and start it
Write-Host "Create VM..." -NoNewline
$vm = new-vm -Name $VMName -MemoryStartupBytes $VMMemoryStartupBytes `
               -VHDPath "$VMDiskPath" -Generation $VMGeneration `
               -BootDevice VHD -Version $VMVersion | out-null
Set-VMProcessor -VMName $VMName -Count $VMProcessorCount
# make sure VM has DVD drive needed for provisioning
if ($null -eq (Get-VMDvdDrive -VMName $VMName)) {
  Add-VMDvdDrive -VMName $VMName
}
Set-VMDvdDrive -VMName $VMName -Path "$metaDataIso"

If ($virtualSwitchName -ne '') {
  Write-Verbose "Connecting VMnet adapter to virtual switch..."
  Get-VMNetworkAdapter -VMName $VMName | Connect-VMNetworkAdapter -SwitchName "$virtualSwitchName"
} else {
  Write-Warning "Virtual network switch with available DHCP is required for provisioning"
}

# hyper-v gen2 specific features
if ($VMGeneration -eq 2) {
  Write-Verbose "Setting secureboot for Hyper-V Gen2..."
  # configure secure boot, src: https://www.altaro.com/hyper-v/hyper-v-2016-support-linux-secure-boot/
  Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplateId ([guid]'272e7447-90a4-4563-a4b9-8e4ab00526ce')

  # ubuntu 18.04+ supports enhanced session
  Set-VM -VMName $VMName -EnhancedSessionTransportType HvSocket
}

# disable automatic checkpoints, https://github.com/hashicorp/vagrant/issues/10251#issuecomment-425734374
if ($null -ne (Get-Command Hyper-V\Set-VM).Parameters["AutomaticCheckpointsEnabled"]){
  Hyper-V\Set-VM -VMName $VMName -AutomaticCheckpointsEnabled $false
}

Write-Host -ForegroundColor Green " Done."

# set chassistag to "Azure chassis tag" as documented in https://git.launchpad.net/cloud-init/tree/cloudinit/sources/DataSourceAzure.py#n51
Write-Host "Set Azure chasis tag ..." -NoNewline
& .\Set-VMAdvancedSettings.ps1 -VM $VMName -ChassisAssetTag '7783-7084-3265-9085-8269-3286-77' -Force -Verbose:$verbose
Write-Host -ForegroundColor Green " Done."
Write-Host "Set BIOS and chasis serial number to machine ID $VmMachineId ..." -NoNewline
& .\Set-VMAdvancedSettings.ps1 -VM $VMName -BIOSSerialNumber $VmMachineId -ChassisSerialNumber $vmMachineId -Force -Verbose:$verbose
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
  # start putty with serial connection to newly created VM
  # TODO alternative: https://stackoverflow.com/a/48661245/1155121
  $env:PATH = "D:\share\programi\putty;" + $env:PATH
  try {
    Get-Command "putty" | out-null
    start-sleep -seconds 2
    & "PuTTY" -serial "\\.\pipe\$VMName-com1" -sercfg "115200,8,n,1,N"
  }
  catch {
    Write-Verbose "putty not available"
  }
}

if ($ShowVmConnectWindow) {
  # Open up VMConnect
  Start-Process "vmconnect" "localhost","$VMName" -WindowStyle Normal
}

Write-Host "Done"
