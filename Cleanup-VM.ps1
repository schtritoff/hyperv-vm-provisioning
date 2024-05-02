<#
.SYNOPSIS
    Stop VM and remove all resources
.EXAMPLE
    PS C:\> .\Cleanup-VM "VM1","VM2" [-Force]
#>

[CmdletBinding()]
param(
    [string[]] $VMNames = @(),
    [switch] $Force = $false
)

if ($Force -or $PSCmdlet.ShouldContinue("Are you sure you want to delete VM?", "Data purge warning")) {
    if ($VMNames.Count -gt 0) {
        Write-Host "Stop and delete VM's and its data files..." -NoNewline

        $VMNames | ForEach-Object {

            $v = $_
            If ($v.GetType() -eq [Microsoft.HyperV.PowerShell.VirtualMachine]) {
                $v = $v.Name
            }

            Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "vmconnect.exe" -and $_.CommandLine -like "*$v*" } | ForEach-Object { Stop-Process -Id $_.ProcessId }

            Write-Verbose "Trying to stop $v ..."
            stop-vm $v -TurnOff -Confirm:$false -ErrorAction 'SilentlyContinue' | Out-Null

            # remove snapshots
            Remove-VMSnapshot -VMName $v -IncludeAllChildSnapshots -ErrorAction SilentlyContinue

            # disks can be on custom locations and there will also be leftover metadata ISO
            $vmDiskStoragePath = @()

            # remove disks
            Get-VM $v -ErrorAction SilentlyContinue | ForEach-Object {
                $_.id | get-vhd -ErrorAction SilentlyContinue | ForEach-Object {
                    $vmDiskStoragePath += (Get-Item $_.path).DirectoryName
                    remove-item -path $_.path -force -ErrorAction SilentlyContinue
                }
            }

            #remove cloud-init metadata iso
            $VHDPath = (Get-VMHost).VirtualHardDiskPath
            Remove-Item -Path "$VHDPath$v-metadata.iso" -ErrorAction SilentlyContinue
            $vmDiskStoragePath | ForEach-Object {
                Write-Verbose "Deleting... $_\$v-metadata.iso"
                Remove-Item -Path "$_\$v-metadata.iso" -ErrorAction SilentlyContinue
            }

            # remove vm
            Remove-VM -VMName $v -Force -ErrorAction SilentlyContinue | Out-Null

            # remove empty directories - src: https://stackoverflow.com/a/28631669/1155121
            $vmDiskStoragePath | ForEach-Object {
                # this should be your -VMMachine_StoragePath
                $topDir = (Get-Item $_).Parent.Parent.FullName
                Write-Verbose "Deleting empty folders from top path: $topDir"
                do {
                    $dirs = Get-ChildItem $topDir -directory -recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName.Contains($v) -and (Get-ChildItem $_.fullName -ErrorAction SilentlyContinue).count -eq 0 } | Select-Object -expandproperty FullName
                    $dirs | Foreach-Object {
                        Write-Verbose "Removing... $_"
                        Remove-Item $_ -Force:$false -Confirm:$false -ErrorAction SilentlyContinue
                    }
                } while ($dirs.count -gt 0)
            }

        }

        Write-Host -ForegroundColor Green " Done."

    }
}
