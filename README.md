# Powershell scripts for fast Linux VM provisioning
![](intro.gif)

## Features
- Provision Linux VM using cloud-init on Hyper-V in a single command
- Use custom userdata yaml, check [cloud-init documentation](https://cloudinit.readthedocs.io/en/stable/reference/examples.html)
- Using Ubuntu Cloud Images certified for Azure and proven to work reliably on Hyper-V with [tailored Microsoft kernel](https://www.neowin.net/news/canonical--microsoft-make-azure-tailored-linux-kernel/) included
- Generation 1 for Azure migration friendliness or Generation 2 Hyper-V virtual machine type supported
- Automatic update check for a newer image on provisioning
- Works on Windows 10, Hyper-V 2016 or later

## Example usage
```powershell
.\New-HyperVCloudImageVM.ps1 -VMProcessorCount 2 -VMMemoryStartupBytes 2GB -VHDSizeBytes 60GB -VMName "ubuntu-1" -ImageVersion "24.04" -VMGeneration 2 -ShowSerialConsoleWindow -KeyboardLayout en -ShowVmConnectWindow -VMMachine_StoragePath "$env:ProgramData\hyperv-vm-provisioning"
```

Parameter `ImageVersion` accepts the following values:
 - Ubuntu: `"18.04"`, `"20.04"`, `"22.04"`, `"22.04-azure"`, `"24.04"`, `"24.04-azure"`
 - Debian: `"10"`, `"11"`, `"12"`

Remark/Disclaimer: Azure image types by default supports `DataSourceAzure` cloud-init type which expects Azure environment. Since we are not emulating Azure cloud-init environment the only way to use those images is to converting those images to `NoCloud` datasource - this requires at least Windows 11 build 22000 because it uses wsl --mount (see [Convert-VHDToNoCloud.ps1](Convert-VHDToNoCloud.ps1)).

Default username is `admin` and password is `Passw0rd` (easily overriden with script parameters). Use standard parameters
as needed: unattended use `-Force`, get some additional details `-Verbose` or to make initial checkpoint for VM use `-Debug`.

You should provide your own custom `userdata.yaml` as script parameter and customize the final image.

## Prerequisites
If you have fresh Windows installation please configure Hyper-V first.

Make sure you have Hyper-V services enabled (run windows powershell as admin)
```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
```
Add Hyper-V management tools
```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Tools-All -All
```
Set up WSL if you plan to use Azure images ([source](https://learn.microsoft.com/en-us/windows/wsl/install#install-wsl-command))

```bat
wsl.exe --install
wsl.exe --install --no-distribution
```

## Download
One line powershell command
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; $r='hyperv-vm-provisioning'; iwr -Uri 'https://github.com/schtritoff/hyperv-vm-provisioning/archive/master.zip' -UseBasicParsing -OutFile "$r.zip" ; Expand-Archive "$r.zip" -Force ; Remove-Item "$r.zip" -Force
```

## Troubleshooting
If you get error `ERROR Daemon /proc/net/route contains no routes` on serial
console then you need to check if your VM has got and IP address - that is
requirement for provisioning to work properly. You need to reboot VM after adding IP
to finish with provisioning.

If you had download, extracting or image conversion interruptions/failures try to clear cache folder and try again. It could be that local cache files are in dirty state.

If in serial console you get messages 'Kernel panic - not syncing: VFS: Unable to mount root fs' you might have set too small VHD size. It is recommended to be at least 40 GB for recent Ubuntu Azure images.

## Similar projects and credits
https://blogs.msdn.microsoft.com/virtual_pc_guy/2015/06/23/building-a-daily-ubuntu-image-for-hyper-v/

https://github.com/MicrosoftDocs/Virtualization-Documentation/blob/master/hyperv-samples/benarm-powershell/Ubuntu-VM-Build/BaseUbuntuBuild.ps1

https://github.com/fdcastel/Hyper-V-Automation/blob/master/New-VMFromUbuntuImage.ps1

https://gist.github.com/PulseBright/3a6fe586821a2ff84cd494eb897d3813

https://gist.github.com/matrey/66d697ef540f0da8933a341524ea9fd7

https://matrey.github.io/articles/build-your-own-ubuntu-ami/

## License
public domain  or any other license for reused work from original authors
