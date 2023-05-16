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

            Write-Verbose "Trying to stop $v ..."
            stop-vm $v -TurnOff -Confirm:$false -ErrorAction 'SilentlyContinue' | Out-Null

            # remove snapshots
            Remove-VMSnapshot -VMName $v -IncludeAllChildSnapshots -ErrorAction SilentlyContinue
            # remove disks
            Get-VM $v -ErrorAction SilentlyContinue | ForEach-Object {
                $_.id | get-vhd -ErrorAction SilentlyContinue | ForEach-Object {
                    remove-item -path $_.path -force -ErrorAction SilentlyContinue
                }
            }
            #remove cloud-init metadata iso
            $VHDPath = (Get-VMHost).VirtualHardDiskPath
            Remove-Item -Path "$VHDPath$v-metadata.iso" -ErrorAction SilentlyContinue
            # remove vm
            Remove-VM -VMName $v -Force -ErrorAction SilentlyContinue | Out-Null
        }

        Write-Host -ForegroundColor Green " Done."

    }
}
