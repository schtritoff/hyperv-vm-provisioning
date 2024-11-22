<#
.SYNOPSIS
    Create an ISO file from a source folder.

.DESCRIPTION
    Create an ISO file from a source folder.
    Optionally speicify a boot image and media type.

    Based on original function by Chris Wu.
    https://gallery.technet.microsoft.com/scriptcenter/New-ISOFile-function-a8deeffd (link appears to be no longer valid.)

    Changes:
        - Updated to work with PowerShell 7
        - Added a bit more error handling and verbose output.
        - Features removed to simplify code:
            * Clipboard support.
            * Pipeline input.

.PARAMETER source
    The source folder to add to the ISO.

.PARAMETER destinationIso
    The ISO file to create.

.PARAMETER bootFile
    Optional. Boot file to add to the ISO.

.PARAMETER media
    Optional. The media type of the resulting ISO (BDR, CDR etc). Defaults to DVDPLUSRW_DUALLAYER.

.PARAMETER title
    Optional. Title of the ISO file. Defaults to "untitled".

.PARAMETER force
    Optional. Force overwrite of an existing ISO file.

.INPUTS
    None.

.OUTPUTS
    None.

.EXAMPLE
    New-ISOFile -source c:\forIso\ -destinationIso C:\ISOs\testiso.iso

    Simple example. Create testiso.iso with the contents from c:\forIso

.EXAMPLE
    New-ISOFile -source f:\ -destinationIso C:\ISOs\windowsServer2019Custom.iso -bootFile F:\efi\microsoft\boot\efisys.bin -title "Windows2019"

    Example building Windows media. Add the contents of f:\ to windowsServer2019Custom.iso. Use efisys.bin to make the disc bootable.

.LINK
    source: https://github.com/brianbaldock/New-ISOFile

.NOTES
    01           Alistair McNair          Initial version.
    02           Brian Baldock            Fixed some type errors and defined using class.

#>

[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact="Low")]
Param
(
    [parameter(Mandatory=$true,ValueFromPipeline=$false)]
    [string]$source,
    [parameter(Mandatory=$true,ValueFromPipeline=$false)]
    [string]$destinationIso,
    [parameter(Mandatory=$false,ValueFromPipeline=$false)]
    [string]$bootFile = $null,
    [Parameter(Mandatory=$false,ValueFromPipeline=$false)]
    [ValidateSet("CDR","CDRW","DVDRAM","DVDPLUSR","DVDPLUSRW","DVDPLUSR_DUALLAYER","DVDDASHR","DVDDASHRW","DVDDASHR_DUALLAYER","DISK","DVDPLUSRW_DUALLAYER","BDR","BDRE")]
    [string]$media = "DVDPLUSRW_DUALLAYER",
    [Parameter(Mandatory=$false,ValueFromPipeline=$false)]
    [string]$title = "untitled",
    [Parameter(Mandatory=$false,ValueFromPipeline=$false)]
    [int]$filesystem = [FsiFileSystems]::FsiFileSystemISO9660 + [FsiFileSystems]::FsiFileSystemJoliet,
    [Parameter(Mandatory=$false,ValueFromPipeline=$false)]
    [switch]$force
)

begin {

    Write-Verbose ("Function start.")

} # begin

process {

    Write-Verbose ("Processing nested system " + $vmName)

    ## Set type definition
    Write-Verbose ("Adding ISOFile type.")

    $typeDefinition = @'
    using System;
    using System.Runtime.InteropServices;
    using System.Runtime.InteropServices.ComTypes;
    
    public class ISOFile {
        public static void Create(string path, object comStream, int blockSize, int totalBlocks) {
            byte[] buffer = new byte[blockSize];
            using (var fileStream = System.IO.File.OpenWrite(path)) {
                var stream = comStream as System.Runtime.InteropServices.ComTypes.IStream;
                if (stream != null) {
                    IntPtr readBytesPointer = Marshal.AllocHGlobal(sizeof(int));
                    try {
                        for (int i = 0; i < totalBlocks; i++) {
                            stream.Read(buffer, blockSize, readBytesPointer);
                            int readBytes = Marshal.ReadInt32(readBytesPointer);
                            fileStream.Write(buffer, 0, readBytes);
                        }
                    } finally {
                        Marshal.FreeHGlobal(readBytesPointer);
                    }
                }
                fileStream.Flush();
            }
        }
    }
'@

    ## Create type ISOFile, if not already created. Different actions depending on PowerShell version
    if (!('ISOFile' -as [type])) {

        ## Add-Type works a little differently depending on PowerShell version.
        ## https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/add-type
        switch ($PSVersionTable.PSVersion.Major) {

            ## 7 and (hopefully) later versions
            {$_ -ge 7} {
                Write-Verbose ("Adding type for PowerShell 7 or later.")
                Add-Type -CompilerOptions "/unsafe" -TypeDefinition $typeDefinition
            } # PowerShell 7

            ## 5, and only 5. We aren't interested in previous versions.
            5 {
                Write-Verbose ("Adding type for PowerShell 5.")
                $compOpts = New-Object System.CodeDom.Compiler.CompilerParameters
                $compOpts.CompilerOptions = "/unsafe"

                Add-Type -CompilerParameters $compOpts -TypeDefinition $typeDefinition
            } # PowerShell 5

            default {
                ## If it's not 7 or later, and it's not 5, then we aren't doing it.
                throw ("Unsupported PowerShell version.")

            } # default

        } # switch

    } # if


    ## Add boot file to image
    if ($bootFile) {

        Write-Verbose ("Optional boot file " + $bootFile + " has been specified.")

        ## Display warning if Blu Ray media is used with a boot file.
        ## Not sure why this doesn't work.
        if(@('BDR','BDRE') -contains $media) {
                Write-Warning ("Selected boot image may not work with BDR/BDRE media types.")
        } # if

        if (!(Test-Path -Path $bootFile)) {
            throw ($bootFile + " is not valid.")
        } # if

        ## Set stream type to binary and load in boot file
        Write-Verbose ("Loading boot file.")

        try {
            $stream = New-Object -ComObject ADODB.Stream -Property @{Type=1} -ErrorAction Stop
            $stream.Open()
            $stream.LoadFromFile((Get-Item -LiteralPath $bootFile).Fullname)

            Write-Verbose ("Boot file loaded.")
        } # try
        catch {
            throw ("Failed to open boot file. " + $_.exception.message)
        } # catch


        ## Apply the boot image
        Write-Verbose ("Applying boot image.")

        try {
            $boot = New-Object -ComObject IMAPI2FS.BootOptions -ErrorAction Stop
            $boot.AssignBootImage($stream)

            Write-Verbose ("Boot image applied.")
        } # try
        catch {
            throw ("Failed to apply boot file. " + $_.exception.message)
        } # catch


        Write-Verbose ("Boot file applied.")

    }  # if

    ## Build array of media types
    $mediaType = @(
        "UNKNOWN",
        "CDROM",
        "CDR",
        "CDRW",
        "DVDROM",
        "DVDRAM",
        "DVDPLUSR",
        "DVDPLUSRW",
        "DVDPLUSR_DUALLAYER",
        "DVDDASHR",
        "DVDDASHRW",
        "DVDDASHR_DUALLAYER",
        "DISK",
        "DVDPLUSRW_DUALLAYER",
        "HDDVDROM",
        "HDDVDR",
        "HDDVDRAM",
        "BDROM",
        "BDR",
        "BDRE"
    )

    enum FsiFileSystems {
        FsiFileSystemNone = 0
        FsiFileSystemISO9660 = 1
        FsiFileSystemJoliet = 2
        FsiFileSystemUDF = 4
        FsiFileSystemUnknown = 0x40000000
    }

    Write-Verbose ("Selected media type is " + $media + " with value " + $mediaType.IndexOf($media))

    ## Initialise image
    Write-Verbose ("Initialising image object.")
    try {
        $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage -Property @{VolumeName=$title} -ErrorAction Stop
        $image.ChooseImageDefaultsForMediaType($mediaType.IndexOf($media))

        Write-Verbose ("initialised.")
    } # try
    catch {
        throw ("Failed to initialise image. " + $_.exception.Message)
    } # catch


    ## Create target ISO, throw if file exists and -force parameter is not used.
    if ($PSCmdlet.ShouldProcess($destinationIso)) {

        if (!($targetFile = New-Item -Path $destinationIso -ItemType File -Force:$Force -ErrorAction SilentlyContinue)) {
            throw ("Cannot create file " + $destinationIso + ". Use -Force parameter to overwrite if the target file already exists.")
        } # if

    } # if


    ## Get source content from specified path
    Write-Verbose ("Fetching items from source directory.")
    try {
        $sourceItems = Get-ChildItem -LiteralPath $source -ErrorAction Stop
        Write-Verbose ("Got source items.")
    } # try
    catch {
        throw ("Failed to get source items. " + $_.exception.message)
    } # catch


    ## Add these to our image
    Write-Verbose ("Adding items to image.")

    foreach($sourceItem in $sourceItems) {

        try {
            $image.Root.AddTree($sourceItem.FullName, $true)
        } # try
        catch {
            throw ("Failed to add " + $sourceItem.fullname + ". " + $_.exception.message)
        } # catch

    } # foreach

    ## Add boot file, if specified
    if ($boot) {
        Write-Verbose ("Adding boot image.")
        $Image.BootImageOptions = $boot
    }

    ## Write out ISO file
    Write-Verbose ("Writing out ISO file to " + $targetFile)

    try {

        # modifiers needed for cloud-init https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html#source-2-drive-with-labeled-filesystem
        $Image.FileSystemsToCreate = $filesystem # ISO9660 + Joliet file system https://learn.microsoft.com/en-us/windows/win32/api/imapi2fs/ne-imapi2fs-fsifilesystems
        $Image.ISO9660InterchangeLevel = 2 # ISO 9660 Level 2 permits longer file names https://learn.microsoft.com/en-us/windows/win32/imapi/disc-formats 
        $Image.GetDefaultFileSystemForImport($filesystem)
        
        $result = $Image.CreateResultImage()
        [ISOFile]::Create($targetFile.FullName,$result.ImageStream,$result.BlockSize,$result.TotalBlocks)
    } # try
    catch {
        throw ("Failed to write ISO file. " + $_.exception.Message)
    } # catch

    Write-Verbose ("File complete.")

    ## Return file details
    return $targetFile

} # process

end {
    Write-Verbose ("Function complete.")
} # end
