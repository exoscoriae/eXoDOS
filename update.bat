@echo off
powershell -command "& { (New-Object Net.WebClient).DownloadFile('http://the-eye.eu/DO_NOT_DELETE_EXO/ver.exo', '.\ver.txt') }"

if exist ver.txt goto verc

if not exist ver.txt goto failed

:verc
fc ver.txt .\ver\ver.txt

if errorlevel = 1 goto diff
if errorlevel = 0 goto same

:diff
cls
echo.
type .\ver\ver.txt
echo  is your current version.
echo.
type ver.txt
echo  has been found and will be downloaded.
echo.
pause
echo Downloading, please wait...
powershell -command "& { (New-Object Net.WebClient).DownloadFile('http://the-eye.eu/DO_NOT_DELETE_EXO/update.zip', '.\update.zip') }"
powershell -command Start-Sleep -s 5

if exist update.zip goto updatenow

if not exist update.zip goto failed

:updatenow
del ver.txt
cd ..
cd ..
copy .\exo\update\update.zip .\
del .\exo\Update\update.zip
.\exo\util\unzip -o update.zip
del update.zip
cd eXo
cls
echo.
echo The updaters will now check to see if any of your installed games
echo need to be updated.
echo.
pause
copy .\Update\update_installed.bat .\
call update_installed.bat
del update_installed.bat

cls
echo.
echo Update was successful!
echo.
pause
:change
type .\Update\changelog.txt | more
echo.
pause
goto exit

:same
cls
echo.
echo You are already up to date.
echo.
pause
del ver.txt
goto exit

:failed
cls
echo.
echo The update version could not be found. 
echo This typically means the internet is not reachable at this time.
echo Please check your internet connection.
echo.
pause

:exit