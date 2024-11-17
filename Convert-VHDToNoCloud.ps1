# this script will try to mount VHD in WSL
# and then rewrite some files on ext4 filesystem
# to enable NoCloud datasource in cloud-init

# References:
# - Build 20211: https://learn.microsoft.com/en-us/windows/wsl/release-notes#build-20211
# - https://devblogs.microsoft.com/commandline/access-linux-filesystems-in-windows-and-wsl-2/
# - https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/diskpart-scripts-and-examples
# - https://nicj.net/mounting-vhds-in-windows-7-from-a-command-line-script/
# - https://github.com/microsoft/WSL/issues/10177
# - https://learn.microsoft.com/en-us/windows/wsl/wsl2-mount-disk
# - https://ss64.com/nt/for_cmd.html
# - https://learn.microsoft.com/en-us/windows/wsl/wsl2-mount-disk
# - https://craigloewen-msft.github.io/WSLTipsAndTricks/tip/use-pipe-in-one-line-command.html
# - https://github.com/microsoft/WSL/issues/10177 

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [String] $VHDPath
)

$VHDPath = (Get-Item $VHDPath | Resolve-Path).ProviderPath 


Write-Verbose "::: Prerequisites check ..."

if (!(Test-Path $VHDPath)) {
    throw "$VHDPath does not exist!"
}

# Note: There are extra NUL in the output stream https://github.com/microsoft/WSL/issues/10177
# to filter them we need $env:WSL_UTF8=1

$env:WSL_UTF8 = 1

Write-Verbose "wsl version: $(wsl --version)"

$wsl_has_mount_option = wsl.exe --help | select-string -SimpleMatch -Pattern "--mount"

if (! $wsl_has_mount_option) {
    Write-Error @"
see #https://learn.microsoft.com/en-us/windows/wsl/wsl2-mount-disk
You will need to be on Windows 11 Build 22000 or later, or be running the Microsoft Store version of WSL.
To check your WSL and Windows version, use the command: wsl.exe --version
"@    
}


Write-Verbose "::: Create Diskpart commands ..."
@"
select vdisk file="$($VHDPath)"
attach vdisk noerr
detail vdisk
"@ | Out-File "${PSScriptRoot}/diskpart-mount.txt" -Encoding ascii


@"
select vdisk file="$($VHDPath)"
detach vdisk noerr
"@ | Out-File "${PSScriptRoot}/diskpart-unmount.txt" -Encoding ascii


Write-Verbose "::: Mount VHD to Windows ..."

diskpart /s "${PSScriptRoot}/diskpart-mount.txt"
Start-Sleep -Seconds 10

Write-Verbose "::: Get PHYSICALDRIVE { ID } of mounted VHD..."

# TODO check we only find one device (in theory we can find more)
$DeviceID = (Get-PhysicalDisk | Where-Object { $_.PhysicalLocation -eq $VHDPath }).DeviceID
Write-Verbose "found device id ${DeviceID}"

Write-Verbose "::: Mount VHD to WSL ..."
# --partition X equals to /dev/sdaX
$partNum = 1
wsl --mount "\\.\PHYSICALDRIVE${DeviceID}" --partition "${partNum}" --type ext4

Write-Verbose "::: Writing file inside WSL ..."
# TODO check wsl -u root
# TODO we could maybe do this in Windows
wsl -u root -- printf 'datasource_list: [ NoCloud ]' `> /mnt/wsl/PHYSICALDRIVE${DeviceID}p${partNum}/etc/cloud/cloud.cfg.d/90_dpkg.cfg

Write-Verbose "::: Unmount VHD from WSL ..."
wsl --unmount "\\.\PHYSICALDRIVE${deviceID}"

Write-Verbose "::: Unmount VHD from Windows ..."
diskpart /s "${PSScriptRoot}/diskpart-unmount.txt"

#:CLEANUP
Remove-Item "${PSScriptRoot}/diskpart-*.txt"
