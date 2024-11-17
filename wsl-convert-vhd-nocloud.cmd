@echo off
setlocal

::
:: this script will try to mount VHD in WSL
:: and then rewrite some files on ext4 filesystem
:: to enable NoCloud datasource in cloud-init
::

cd /d "%~dp0"
set vhdpath=%1

echo.
echo ::: Prerequisites check ...

if "%vhdpath%"=="" (
  echo script arg1 is empty! should be VHD file to modify
  echo usage: %0 [vhd file to modify]
  exit /B 1
)

:: make path absolute because diskpart vdisk file parameter accepts only absolute file path
FOR /F "tokens=*" %%H IN ('dir "%vhdpath%" /B /S') DO SET vhdpath=%%H

if not exist "%vhdpath%" (
  echo file not found: %vhdpath%
  exit /B 1
)

:: check if wsl has mount option
wsl.exe --help > wsl-help.txt
find /I "--mount" wsl-help.txt 1>NUL
IF %ERRORLEVEL% NEQ 0 (
  echo wsl.exe does not have --mount.
  echo see https://learn.microsoft.com/en-us/windows/wsl/wsl2-mount-disk
  echo You will need to be on Windows 11 Build 22000 or later, or be running the Microsoft Store version of WSL.
  echo To check your WSL and Windows version, use the command: wsl.exe --version
  del /Q wsl-help.txt
  exit /B 1
)
del /Q wsl-help.txt

:: check if wsl has default distro

:: Note: (Default) is different in other languages! Eg (Standard) in German.
:: We ignore the check for the standard distro when codepage is not 437
:: There is unfortunately no good check for the default distro.
chcp.com > cmd-chcp.txt
find /I "Active code page: 437" cmd-chcp.txt 1>NUL
IF %ERRORLEVEL% NEQ 0 (
    del /Q cmd-chcp.txt
    goto :mountvhd
)
del /Q cmd-chcp.txt

wsl.exe --list > wsl-list.txt
find /I "(Default)" wsl-list.txt 1>NUL
IF %ERRORLEVEL% NEQ 0 (
  echo wsl.exe does not have default distro. Error code: Wsl/WSL_E_DEFAULT_DISTRO_NOT_FOUND
  echo see https://github.com/microsoft/WSL/issues/9338

  del /Q wsl-list.txt
  exit /B 1
)
del /Q wsl-list.txt

:mountvhd
echo.
echo ::: Mount VHD to Windows ...
:: https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/diskpart-scripts-and-examples
:: https://nicj.net/mounting-vhds-in-windows-7-from-a-command-line-script/
(
  echo select vdisk file="%vhdpath%"
  echo attach vdisk noerr
  echo detail vdisk
)>"diskpart-mount.txt"
diskpart /s diskpart-mount.txt
timeout /t 10 /nobreak

echo.
echo ::: Get PHYSICALDRIVE{ID} of mounted VHD...
:: https://ss64.com/nt/for_cmd.html
FOR /F "tokens=*" %%G IN ('powershell "(Get-PhysicalDisk | Where-Object {$_.PhysicalLocation -eq '%vhdpath%'}).DeviceID"') DO SET deviceID=%%G
echo found device id %deviceID%

echo.
echo ::: Mount VHD to WSL ...
:: https://learn.microsoft.com/en-us/windows/wsl/wsl2-mount-disk
:: --partition X equals to /dev/sdaX
set partNum=1
wsl --mount \\.\PHYSICALDRIVE%deviceID% --partition %partNum% --type ext4

echo.
echo ::: Writing file inside WSL ...
:: https://craigloewen-msft.github.io/WSLTipsAndTricks/tip/use-pipe-in-one-line-command.html
wsl -u root -- printf 'datasource_list: [ NoCloud ]' ^> /mnt/wsl/PHYSICALDRIVE%deviceID%p%partNum%/etc/cloud/cloud.cfg.d/90_dpkg.cfg

echo.
echo ::: Unmount VHD from WSL ...
wsl --unmount \\.\PHYSICALDRIVE%deviceID%

echo.
echo ::: Unmount VHD from Windows ...
(
  echo select vdisk file="%vhdpath%"
  echo detach vdisk noerr
)>"diskpart-unmount.txt"
diskpart /s diskpart-unmount.txt


:CLEANUP
del /Q diskpart-*.txt

:EOF
exit /B 0
