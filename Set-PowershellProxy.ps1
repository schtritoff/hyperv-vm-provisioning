<#
.SYNOPSIS
Set proxy settings for powershell session

.EXAMPLE
Corporate proxy using integrated authentication:
Set-PowershellProxy "proxy.domain.local" "9090" $true
#>
function Set-PowershellProxy {
    [CmdletBinding()]
    param (
        [string] $proxy_host,
        [int] $proxy_port,
        [bool] $useDefaultCredentials = $false,
        [switch] $Reset = $false
    )

    if ($Reset) {
        $global:PSDefaultParameterValues = @{}
        Write-Host "Proxy settings reset"
        return $true
    }

    # if proxy available, use it
    #if(Test-Connection $proxy_host -Count 1 -Quiet) # only ping
    $script:nc = Test-NetConnection -Computername $proxy_host -Port $proxy_port
    if ($script:nc.TcpTestSucceeded)
    {
        $global:PSDefaultParameterValues = @{
            'Invoke-RestMethod:Proxy'="http://$($proxy_host):$($proxy_port)"
            'Invoke-WebRequest:Proxy'="http://$($proxy_host):$($proxy_port)"
            '*:ProxyUseDefaultCredentials'=$useDefaultCredentials
        }
        Write-Host "Proxy configured $($proxy_host):$($proxy_port)"
        return $true
    } else {
        Write-Host "Proxy $($proxy_host):$($proxy_port) not available"
    }
    return $false
}
