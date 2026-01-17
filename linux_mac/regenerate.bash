#!/usr/bin/env bash

# Linux & macOS Compatibility Patch for eXoDOS 6 / eXoDemoScene / eXoDREAMM / eXoScummVM / eXoWin3x
# Revised: 2026-01-17
#
# This script was written and tested with the following:
#  - 86Box 4.2.1 (Sep 01 2024)
#  - aria2 version 1.37.0 (Nov 15 2023)
#  - curl 7.81.0 (Release-Date: 2022-01-05)
#  - dos2unix 7.4.2 (2020-10-12)
#  - DOSBox version 0.74-3, copyright 2002-2019 DOSBox Team.
#  - DOSBox ECE r4301 (Dec 11 2019)
#  - DOSBox ECE r4358 (Sep 02 2020)
#  - DOSBox ECE r4482 (Mar 17 2023)
#  - DOSBox GRIDC 4.3.1 (Mar 04 2019)
#  - DOSBox Staging 0.81.2 (Jul 21 2024)
#  - DOSBox Staging 0.82.0 (Oct 26 2024)
#  - DOSBox-X 0.82.20 SDL1 (Jul 31 2019)
#  - DOSBox-X 20240701 (Jul 01 2024)
#  - DOSBox-X 20241001 (Oct 02 2024)
#  - ffmpeg version 4.4.2-0ubuntu0.22.04.1
#  - Flatpak 1.12.7
#  - fold (GNU coreutils) 8.32
#  - GNU bash, version 5.1.16(1)-release (x86_64-pc-linux-gnu)
#  - GNU Wget 1.21.2
#  - GZDoom 4.11.3 (Oct 26 2023)
#  - ncurses 6.2.20200212
#  - node v23.3.0 (npm v10.9.0)
#  - perl 5, version 34, subversion 0 (v5.34.0)
#  - Python 3.10.12
#  - ScummVM 2.2.0 (Oct 30 2020 19:42:51)
#  - ScummVM 2.3.0 Alpha git15811-gf97bfb7ce1 (Apr 28 2021)
#  - ScummVM 2.8.0 (Dec 16 2023)
#  - sed (GNU sed) 4.8
#  - UnZip 6.00 of 20 April 2009, by Debian. Original by Info-ZIP.
#  - Wine 9.0 (Jan 16 2024)
#
# Purpose: The purpose of this script is to assist in the development of future
#          Linux patches by automating the conversion of Windows batch files to
#          Linux compatible bash files. Before running this script, ensure that
#          all files being converted are unzipped and in their correct location
#          script. This script is not intended for end users.
#
# Notes: The contents of the util_linux.zip file is different from those of the
#        util.zip file in multiple ways. This script does not focus on creating
#        any zip archives. Instead, it focuses on the modification, conversion,
#        and creation of bat, conf, txt, and Linux shell files. It is important
#        to thorougly test any files altered or created by this script.
#
#        If the regenerate.bash or converter.bash file has been updated, ensure
#        you have also updated the util_linux.zip file with the newest version.
#
# IMPORTANT: When running this script, alterations will get made to all bat and
#            conf files, including the main "Setup eXoDOS.bat" file. It is very
#            important to have a backup that you can use to reset everything to
#            its original state. This is preferably done through rsync. e.g.:
#            rsync -avh <backup directory> <working directory> --delete
#
#            It should be also noted that this script takes a LONG time to run.
#            The base release of eXoDOS 6 may take over 17 hours alone.

#  eXoScummVM Note: The eXoScummVM collection currently has a backend directory
#  with a different case than the other eXo collections (eXo/Emulators). Due to
#  this problem, release will need to wait until a new eXoScummVM torrent fixes
#  the directory name to match the other collections (eXo/emulators). Otherwise
#  converting the eXoScummVM collection should be straightforward. It will need
#  flatpaks created and named properly. The placeholder package names are based
#  on the directories in the collection. The git hash and final flatpak package
#  names still need to be determined. Then case consistency analysis also needs
#  to be ran against the eXoScummVM collection to ensure everything is correct.
#  Note that the next version of eXoScummVM is changing a lot of backend stuff,
#  which may require new conversion fixes.

#  eXoWin3x Note: The next version of eXoWin3x will require additional flatpaks
#  and numerous case corrections. The backend will hopefully convert correctly.

#  Language Packs Note: The setup for the GLP 1.0 has some parts that cannot be
#  systematically converted due to how the Linux patch implements goto commands
#  through the use of stack frames. Then, there are some issues have been found
#  with the backend of language packs that affect Windows as well. These issues
#  will hopefully be resolved with the release of eXoDOS 6.04. However, changes
#  to the frontend may also be necessary to add proper language pack support.

#  macOS Note: At this time, only the eXoDREAMM backend has had full conversion
#  to macOS. Further work is on hold until the frontend adds support for macOS.

clear
echo "IMPORTANT THINGS TO NOTE BEFORE PROCEEDING:"
echo ""
echo "This script is used in conjunction with converter.bash to convert the Windows"
echo "batch and conf files from the eXo collections to Linux and macOS equivalents."
echo "As the Windows batch code changes, this script must be periodically updated to"
echo "ensure nothing in the conversion process breaks. The GNU version of tools such"
echo "as sed are used by the script to complete the conversion process. Refer to the"
echo "notes at the top of the script for system requirements. These scripts must be"
echo "placed in the util directory of an eXo collection before execution. The files"
echo "that are being converter must also be already unzipped."
echo ""
echo "This script was created for flexibility, not efficiency. That means it will"
echo "run through and convert every bat file whether or not the code is duplicate."
echo "Running this against a preinstalled copy of the base eXoDOS collection will"
echo "possibly take over 17 hours to complete."
while true
do
    read -p "Would you like to proceed (y/n)? " choice
    case $choice in
        [Yy]* ) errorlevel=1
                break;;
        [Nn]* ) errorlevel=2
                break;;
        *     ) printf "Invalid input.\\n";;
    esac
done
[ $errorlevel == '2' ] && exit 0
unset errorlevel

#Prechecks
cd "$( dirname "$0")"
cd ../../
rootDir="$PWD"
if [[ "$(ls -1 Setup*.bat 2>/dev/null | wc -l)" -eq 0 ]]
then
    printf "\e[1;31;47mCannot find Setup eXo[collection].bat file.\e[0m\n\n"
    read -s -n 1 -p "Press any key to abort."
    printf "\n\n"
    exit 0
fi

if [ ! -e "eXo/util/converter.bash" ]
then
    printf "\n\e[1;31;47mCannot find ./eXo/util/converter.bash.\e[0m\n\n"
    read -s -n 1 -p "Press any key to abort."
    printf "\n\n"
    exit 0
fi

if [ ! -d Content ]
then
    printf "\n\e[1;31;47mCannot find ./Content subdirectory.\e[0m\n\n"
    read -s -n 1 -p "Press any key to abort."
    printf "\n\n"
    exit 0
fi

#hideMessage setting for converter.bash warning
hideMessage='true'

#load convertScript function into the environment
. eXo/util/converter.bash

echo ""
cd "$rootDir"
cd eXo
#echo "Copying scummvm svn application data to Wine."
#[ -e "emulators/scummvm/scummvm.ini" ] && wine cmd /c "md %USERPROFILE%\AppData\Roaming\ScummVM" 2>/dev/null
#[ -e "emulators/scummvm/scummvm.ini" ] && wine cmd /c "copy .\util\scummvm.ini %USERPROFILE%\AppData\Roaming\ScummVM\scummvm.ini" 2>/dev/null

echo "Fixing zip archive references."

echo "Fixing batch file reference inconsistencies. (ETA over 20 minutes)"
[ `ls -1 Update/*.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s/^goto :eof/goto :end/" Update/*.bat 2>/dev/null
for file in eXo*/\!*/*/*.bat eXo*/\!*/*/*/*.bat eXo*/\!*/*/*/*/*.bat Update/*.bat Magazines/*.bat Magazines/*/*.bat Magazines/*/*/*.bat Videos/*.bat Videos/*/*.bat Videos/*/*/*.bat emulators/dosbox/*.bat emulators/dosbox/*/*.bat util/*.bat util/*/*.bat ../xml/*.bat ../*.bat
do
    [ -e "$file" ] && sed -i -e "s/\.\\\download\\\/.\\\DOWNLOAD\\\/Ig" "$file"
    [ -e "$file" ] && sed -i -e "s/exodos\\\/eXoDOS\\\/Ig" "$file"
    [ -e "$file" ] && sed -i -e "s/exodreamm\\\/eXoDREAMM\\\/Ig" "$file"
    [ -e "$file" ] && sed -i -e "s/exoscummvm\\\/eXoScummVM\\\/Ig" "$file"
    [ -e "$file" ] && sed -i -e "s/exowin3x\\\/eXoWin3x\\\/Ig" "$file"
    [ -e "$file" ] && sed -i -e "s/exo\\\/eXo\\\/Ig" "$file"
    [ -e "$file" ] && sed -i -e 's/^cd exo/cd eXo/I' "$file"
    [ -e "$file" ] && sed -i -e 's/^cd eXodos/cd eXoDOS/I' "$file"
    [ -e "$file" ] && sed -i -e 's/^cd eXodreamm/cd eXoDREAMM/I' "$file"
    [ -e "$file" ] && sed -i -e 's/^cd eXoscummvm/cd eXoScummVM/I' "$file"
    [ -e "$file" ] && sed -i -e 's/^cd eXowin3x/cd eXoWin3x/I' "$file"
    [ -e "$file" ] && sed -i -e "s/\.\\\content/.\\\Content/Ig" "$file"
    [ -e "$file" ] && sed -i -e "s/\.\\\data/.\\\Data/Ig" "$file"
    [ -e "$file" ] && sed -i -e "s/\.\\\Emulators/.\\\emulators/Ig" "$file"
    [ -e "$file" ] && sed -i -e 's/launchbox\.exe/LaunchBox.exe/I' "$file"
    [ -e "$file" ] && sed -i -e "s/\.\\\magazines/.\\\Magazines/Ig" "$file"
    [ -e "$file" ] && sed -i -e "s/magazines\\\bbd/Magazines\\\BBD/Ig" "$file"
    [ -e "$file" ] && sed -i -e "s|sumatraPDF\.exe|SumatraPDF.exe|Ig" "$file"
    [ -e "$file" ] && sed -i -e "s|util\\\sumatra|util\\\Sumatra|Ig" "$file"
    [ -e "$file" ] && sed -i -e "s/exo\\\update/eXo\\\Update/Ig" "$file"
    [ -e "$file" ] && sed -i -e "s/\\\update\\\/\\\Update\\\/Ig" "$file"
    [ -e "$file" ] && sed -i -e "s/cd update/cd Update/Ig" "$file"
    [ -e "$file" ] && sed -i -e "s/PPMode/PPmode/I" "$file"
    [ -e "$file" ] && sed -i -e "s/c\*\.rom/C*.ROM/I" "$file"
    [ -e "$file" ] && sed -i -e "s/\.rom/.ROM/I" "$file"
    [ -e "$file" ] && sed -i -e "s|mt32\\\soundcanvas\.sf2|mt32\\\SoundCanvas.sf2|I" "$file"
    [ -e "$file" ] && sed -i -e "s/update\.zip/update_linux.zip/Ig" "$file"
    [ -e "$file" ] && sed -i -e "s/magazines\.zip/Magazines.zip/Ig" "$file"
    [ -e "$file" ] && sed -i -e "s/books\.zip/Books.zip/Ig" "$file"
    [ -e "$file" ] && sed -i -e "s/catalogs\.zip/Catalogs.zip/Ig" "$file"
    [ -e "$file" ] && sed -i -e "s/soundtracks\.zip/Soundtracks.zip/Ig" "$file"
    [ -e "$file" ] && sed -i -e "s/videos\.zip/Videos.zip/Ig" "$file"
    [ -e "$file" ] && sed -i -e "s/launch\.bat/launch.bat/Ig" "$file"
    [ -e "$file" ] && sed -i -e "s/install\.bat/install.bat/Ig" "$file"
    [ -e "$file" ] && sed -i -e "s/choice\.exe/CHOICE.EXE/Ig" "$file"
    # For now, we are skipping any precision search string substitutions related to language packs
    # as language packs may follow different text file formatting conventions than the base pack or other language.
#    [ -e "$file" ] && [[ "$file" != *"lang"* ]] && sed -i -e "/multilanguage\.txt/I s|findstr \(/C:\"%GameName\)|findstr /b \1|I" "$file"
#    [ -e "$file" ] && [[ "$file" != *"lang"* ]] && sed -i -e "/dosbox\.txt/I s|findstr \(/C:\"%GameName\)|findstr /b \1|I" "$file"
#    [ -e "$file" ] && [[ "$file" != *"lang"* ]] && sed -i -e "/multiplayer\.txt/I { /findstr \/i \/C:/I s/\(\/C:\"\)\(%GameName\)/\1:\2/I }" "$file"
#    [ -e "$file" ] && [[ "$file" != *"lang"* ]] && sed -i -e "/multiplayer\.txt/I { /findstr \/C:/I s|findstr \(/C:\"%GameName\)|findstr /b \1|I }" "$file"
#    [ -e "$file" ] && [[ "$file" != *"lang"* ]] && sed -i -e "/index\.txt/I { /findstr \/C:/I s/\(\/C:\"\)\(%GameName\)/\1:\2/I }" "$file"
#    [ -e "$file" ] && [[ "$file" != *"lang"* ]] && sed -i -e "/lang/I! { /index\.txt/I { /findstr \/C:/I s/\(\/C:\"\)\(%FileName\)/\1:\2/I } }" "$file"
#    [ -e "$file" ] && [[ "$file" != *"lang"* ]] && sed -i -e "/index\.txt/I { /findstr \/C:/I s/\(\/C:\"\)\(GameData\)/\1:\2/I }" "$file"
    [ -e "$file" ] && sed -i -e "s/xml\\\ALL/xml\\\all/Ig" "$file"
    
    #Linux patch related changes
    #sed -i -e "s/ver\.exo/ver_linux.exo/Ig" "$file"
    #sed -i -e "s/ver\.txt/ver_linux.txt/Ig" "$file"
    #[ -e "$file" ] && sed -i -e "/ver/I s/\.txt/_linux.txt/Ig" "$file"
    #[ -e "$file" ] && sed -i -e 's/MediaPack\.txt/MediaPack_linux.txt/Ig' "$file"
    #sed -i -e "s/util\.zip/util_linux.zip/Ig" "$file"
    #[ -e "$file" ] && sed -i -e '/DownloadFile/I s/\.exo/_linux.exo/Ig' "$file"
done

[ `ls -1 eXoDOS/\!dos/BudokanT/exception.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|tandy\.SEL|TANDY.SEL|Ig" eXoDOS/\!dos/BudokanT/exception.bat 2>/dev/null
[ `ls -1 eXoDOS/\!dos/ckrynn/exception.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|ckrynn\\\mt32|ckrynn\\\MT32|Ig" eXoDOS/\!dos/ckrynn/exception.bat 2>/dev/null
[ `ls -1 eXoDOS/\!dos/ckrynn/exception.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|ckrynn\\\sb16|ckrynn\\\SB16|Ig" eXoDOS/\!dos/ckrynn/exception.bat 2>/dev/null
[ `ls -1 eXoDOS/\!dos/dom_door/exception.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|chain\.txt|CHAIN.TXT|gI" eXoDOS/\!dos/dom_door/exception.bat 2>/dev/null
[ `ls -1 eXoDOS/\!dos/drkqueen/exception.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|disk1|DISK1|gI" eXoDOS/\!dos/drkqueen/exception.bat 2>/dev/null
[ `ls -1 eXoDOS/\!dos/gfterri/exception.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|gfupdate|GFUpdate|gI" eXoDOS/\!dos/gfterri/exception.bat 2>/dev/null
[ `ls -1 eXoDOS/\!dos/gftracy/exception.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|gf\\gfupdate|GF\\GFUpdate|gI" eXoDOS/\!dos/gftracy/exception.bat 2>/dev/null
[ `ls -1 eXoDOS/\!dos/gnomer/exception.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|taskill|taskkill|gI" eXoDOS/\!dos/gnomer/exception.bat 2>/dev/null
[ `ls -1 eXoDOS/\!dos/jrrtf1/exception.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|dosbox_tandy|dosbox_Tandy|Ig" eXoDOS/\!dos/jrrtf1/exception.bat 2>/dev/null
[ `ls -1 eXoDOS/\!dos/Priv2SE/exception.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|privateer2\.cfg|Privateer2.cfg|Ig" eXoDOS/\!dos/Priv2SE/exception.bat 2>/dev/null
[ `ls -1 eXoDOS/\!dos/TNM7SE/exception.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|dosbox\.rst|DOSBOX.RST|Ig" eXoDOS/\!dos/TNM7SE/exception.bat 2>/dev/null
[ `ls -1 eXoDOS/\!dos/TNM7SE/exception.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|program|PROGRAM|Ig" eXoDOS/\!dos/TNM7SE/exception.bat 2>/dev/null
[ `ls -1 eXoDOS/\!dos/TNM7SE/exception.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|temp|TEMP|Ig" eXoDOS/\!dos/TNM7SE/exception.bat 2>/dev/null
[ `ls -1 eXoDOS/\!dos/TNM7SE/exception.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|tnm7se|TNM7SE|Ig" eXoDOS/\!dos/TNM7SE/exception.bat 2>/dev/null
[ `ls -1 eXoDOS/\!dos/TNM7SE/exception.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|tnmgs|TNMGS|Ig" eXoDOS/\!dos/TNM7SE/exception.bat 2>/dev/null
[ `ls -1 eXoDOS/\!dos/TNM7SE/exception.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|TNMGS\.exe|TNMGS.EXE|Ig" eXoDOS/\!dos/TNM7SE/exception.bat 2>/dev/null
[ `ls -1 eXoDOS/\!dos/TNM7SE/exception.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|TNMGS\.no|TNMGS.NO|Ig" eXoDOS/\!dos/TNM7SE/exception.bat 2>/dev/null
[ `ls -1 eXoDOS/\!dos/wastland/exception.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|setup\.sel|setup.SEL|Ig" eXoDOS/\!dos/wastland/exception.bat 2>/dev/null

#[ `ls -1 Update/update.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e '/^:mpskip/{n;n;n;s/)//}' Update/update.bat 2>/dev/null
#[ `ls -1 Update/update.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e 's/^:mpskip/)\n:mpskip/' Update/update.bat 2>/dev/null

echo "Fixing typos."
[ `ls -1 ../eXoMerge.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e 's/To few parameters/Too few parameters/Ig' ../eXoMerge.bat 2>/dev/null
[ `ls -1 ../eXoMerge.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e 's/To much parameters/Too many parameters/Ig' ../eXoMerge.bat 2>/dev/null

echo "Creating game shell files."
echo "Preparing files for conversion..."
for file in eXo*/\!*/*/*.bat eXo*/\!*/*/*/*.bat eXo*/\!*/*/*/*/*.bat Update/*.bat Magazines/*.bat Magazines/*/*.bat Magazines/*/*/*.bat Videos/*.bat Videos/*/*.bat Videos/*/*/*.bat emulators/dosbox/*.bat emulators/dosbox/*/*.bat util/*.bat util/*/*.bat ../xml/*.bat ../*.bat
do
    [ -e "$file" ] && cp "$file" "${file%.bat}.bsh"
done

#echo "Creating Linux configuration references. Please wait."
#for file in eXo*/\!*/*/install.bsh
#do
#    [ -e "$file" ] && sed -i -e "/ssr/I s/^\(.*\)\.bat\(.*\)/&\n\1.bsh\2/" "$file"
#done
#
#echo "Adding Linux configuration references to Windows install files."
#for file in eXo*/\!*/*/install.bat
#do
#    if [ `grep ".bsh" "$file" 2>/dev/null | wc -l` -eq 0 ]
#    then
#        [ -e "$file" ] && sed -i -e "/ssr/I s/^\(.*\)\.bat\(.*\)/&\n\1.bsh\2/" "$file"
#        [ -e "$file" ] && sed -i -e "/ssr/I s/^\(.*\)\"\.\\\eXoDOS\(.*\)\.bsh\"\(.*\)/&\n.\\\util\\\dos2unix \".\\\eXoDOS\2.bsh\"/" "$file"
#    fi
#done
#echo "Adding Windows configuration references to Linux install files."
#for file in eXo*/\!*/*/install.bsh
#do
#    [ -e "$file" ] && sed -i -e "/ssr.*\.bat/I d" "$file"
#    [ -e "$file" ] && sed -i -e "/ssr/I s/^\(.*\)\.bsh\(.*\)/&\n\1.bat\2/" "$file"
#done
echo "Converting file syntax from Windows batch to bash. (ETA 8 hours)"
echo ""

for currentScript in eXo*/\!*/*/*.bsh eXo*/\!*/*/*/*.bsh eXo*/\!*/*/*/*/*.bsh Magazines/*.bsh Magazines/*/*.bsh Magazines/*/*/*.bsh Videos/*.bsh Videos/*/*.bsh Videos/*/*/*.bsh Update/*.bsh emulators/dosbox/*.bsh emulators/dosbox/*/*.bsh util/*.bsh util/*/*.bsh ../xml/*.bsh ../*.bsh
do
    [ -e "$currentScript" ] && convertScript
    [ -e "$currentScript" ] && sed -i -e '/^if \[ "\${BASH_VERSINFO:-0}" -lt 5 \]/i\
if [[ "$OSTYPE" == "darwin"* ]]\
then\
    source "$scriptDir/$(basename -- "${BASH_SOURCE%.bsh}.msh")"\
    exit 0\
fi\
' "$currentScript"
    [ -e "$currentScript" ] && echo "$currentScript created."
done

echo ""
echo "Removing unnecessary dependency checks."
for currentScript in ../xml/*.bsh emulators/*/*.bsh emulators/*/*/*.bsh Videos/*/*.bsh ../eXoMerge.bsh
do
    [ -e "$currentScript" ] && sed -i -e "/flatpak list.*retro_exo\\\./d" "$currentScript"
done
for currentScript in Videos/*/*.bsh
do
    [ -e "$currentScript" ] && sed -i -e '/which flatpak/ s^$^\n    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\.vlc"` ]] \&\& missingDependencies=yes^' "$currentScript"
done
for currentScript in eXoDemoScn/\!*/*/*.bsh eXoDemoScn/\!*/*/*/*.bsh eXoDemoScn/\!*/*/*/*/*.bsh util/ds_*.bsh ../Setup\ eXoDemoScene.bsh
do
    [ -e "$currentScript" ] && sed -i -e "/flatpak list.*retro_exo\\\.aria2c/d" "$currentScript"
    [ -e "$currentScript" ] && sed -i -e "/flatpak list.*retro_exo\\\.dosbox/d" "$currentScript"
    [ -e "$currentScript" ] && sed -i -e "/flatpak list.*retro_exo\\\.gzdoom/d" "$currentScript"
    [ -e "$currentScript" ] && sed -i -e "/flatpak list.*retro_exo\\\.scummvm/d" "$currentScript"
    [ -e "$currentScript" ] && sed -i -e '/which flatpak/ s^$^\n    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\.dosbox-074r3-1"` ]] \&\& missingDependencies=yes\n    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\.dosbox-ece-r4482"` ]] \&\& missingDependencies=yes\n    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\.dosbox-staging-081-2"` ]] \&\& missingDependencies=yes\n    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\.dosbox-staging-082-0"` ]] \&\& missingDependencies=yes\n    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\.dosbox-x-08220"` ]] \&\& missingDependencies=yes\n    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\.dosbox-x-20240701"` ]] \&\& missingDependencies=yes\n    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\.dosbox-x-20241001"` ]] \&\& missingDependencies=yes^' "$currentScript"

done
for currentScript in eXoDREAMM/\!*/*/*.bsh eXoDREAMM/\!*/*/*/*.bsh util/*_drm.bsh ../Setup\ eXoDREAMM.bsh
do
    [ -e "$currentScript" ] && sed -i -e "/flatpak list.*retro_exo\\\.aria2c/d" "$currentScript"
    [ -e "$currentScript" ] && sed -i -e "/flatpak list.*retro_exo\\\.dosbox/d" "$currentScript"
    [ -e "$currentScript" ] && sed -i -e "/flatpak list.*retro_exo\\\.gzdoom/d" "$currentScript"
    [ -e "$currentScript" ] && sed -i -e "/flatpak list.*retro_exo\\\.scummvm/d" "$currentScript"
done
for currentScript in eXoScummVM/\!*/*/*.bsh eXoScummVM/\!*/*/*/*.bsh util/*_svm.bsh ../Setup\ eXoScummVM.bsh
do
    [ -e "$currentScript" ] && sed -i -e "/flatpak list.*retro_exo\\\.dosbox/d" "$currentScript"
    [ -e "$currentScript" ] && sed -i -e "/flatpak list.*retro_exo\\\.gzdoom/d" "$currentScript"
    [ -e "$currentScript" ] && sed -i -e '/which flatpak/ s^$^\n    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\.scummvm-2-8-0"` ]] \&\& missingDependencies=yes^' "$currentScript"
    #add additional eXoScummVM flatpaks to dependency check
done
for currentScript in */\!*/*/Magazines/*.bsh
do
    [ -e "$currentScript" ] && sed -i -e "/flatpak list.*retro_exo\\\./d" "$currentScript"
    [ -e "$currentScript" ] && sed -i -e '/which flatpak/ s^$^\n    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\.wine"` ]] \&\& missingDependencies=yes^' "$currentScript"
done

echo ""
echo "Creating universal launch files."
for currentScript in eXo*/\!*/*/*.bsh eXo*/\!*/*/*/*.bsh eXo*/\!*/*/*/*/*.bsh Magazines/*.bsh Magazines/*/*.bsh Magazines/*/*/*.bsh Videos/*.bsh Videos/*/*.bsh Videos/*/*/*.bsh Update/*.bsh emulators/dosbox/*.bsh emulators/dosbox/*/*.bsh util/*.bsh util/*/*.bsh ../xml/*.bsh
do
    [ -e "$currentScript" ] && cat << 'EOF' > "${currentScript%.bsh}.command"
#!/usr/bin/env bash
if [[ "$LD_PRELOAD" =~ "gameoverlayrenderer" ]]
then
    LD_PRELOAD=""
fi
cd "$( dirname "$BASH_SOURCE")"

if [[ "$OSTYPE" == "linux"* ]]
then
    current_term="$(ps -o sid= -p "$$" | xargs ps -o ppid= -p | xargs ps -o comm= -p)"
    case "$current_term" in
        "cool-retro-term"|"konsole"|"gnome-terminal-"|"xfce4-terminal"|"ptyxis-agent"|"kgx"|"xterm"|"Eterm"|"x-terminal-emul"|"mate-terminal"|"terminator"|"urxvt"|"rxvt"|"termit"|"terminology"|"tilix"|"kitty"|"aterm"|"alacritty"|"qterminal"|"foot"|"mlterm"|"stterm")
            source "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")"
            exit 0
            break;;
    esac
    unset current_term
    if [ `which cool-retro-term` ]
    then
        cool-retro-term -e /usr/bin/env bash "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &
        exit 0
    elif [ `which konsole` ]
    then
        konsole -e /usr/bin/env bash "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &
        exit 0
    elif [ `which gnome-terminal` ]
    then
        gnome-terminal -- /usr/bin/env bash "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &
        exit 0
    elif [ `which xfce4-terminal` ]
    then
        xfce4-terminal -x /usr/bin/env bash "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &
        exit 0
    elif [ `which ptyxis` ]
    then
        ptyxis --new-window -- /usr/bin/env bash "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &
        exit 0
    elif [ `which kgx` ]
    then
        kgx -e "/usr/bin/env bash \"$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")\" $@" &
        exit 0
    elif [ `which xterm` ]
    then
        xterm -e /usr/bin/env bash "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &
        exit 0
    elif [ `which uxterm` ]
    then
        uxterm -e /usr/bin/env bash "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &
        exit 0
    elif [ `which eterm` ]
    then
        Eterm -e /usr/bin/env bash "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &
        exit 0
    elif [ `which x-terminal-emulator` ]
    then
        x-terminal-emulator -e /usr/bin/env bash "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &
        exit 0
    elif [ `which mate-terminal` ]
    then
        eval mate-terminal -e \"/usr/bin/env bash \\\"$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")\\\" $@\" "$@" &
        exit 0
    elif [ `which terminator` ]
    then
        terminator -x /usr/bin/env bash "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &
        exit 0
    elif [ `which urxvt` ]
    then
        urxvt -e /usr/bin/env bash "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &
        exit 0
    elif [ `which rxvt` ]
    then
        rxvt -e /usr/bin/env bash "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &
        exit 0
    elif [ `which termit` ]
    then
        termit -e /usr/bin/env bash "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &
        exit 0
    elif [ `which lxterm` ]
    then
        lxterm -e /usr/bin/env bash "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &
        exit 0
    elif [ `which terminology` ]
    then
        terminology -e "/usr/bin/env bash \"$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")\" $@" &
        exit 0
    elif [ `which tilix` ]
    then
        tilix -e /usr/bin/env bash "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &
        exit 0
    elif [ `which kitty` ]
    then
        kitty -e /usr/bin/env bash "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &
        exit 0
    elif [ `which aterm` ]
    then
        aterm -e /usr/bin/env bash "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &
        exit 0
    elif [ `which alacritty` ]
    then
        alacritty -e /usr/bin/env bash "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &
        exit 0
    elif [ `which qterminal` ]
    then
        qterminal -e "/usr/bin/env bash \"$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")\" $@" &
        exit 0
    elif [ `which foot` ]
    then
        foot -- /usr/bin/env bash "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &
        exit 0
    elif [ `which mlterm` ]
    then
        mlterm -e /usr/bin/env bash "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &
        exit 0
    elif [ `which stterm` ]
    then
        stterm -e /usr/bin/env bash "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &
        exit 0
    elif [[ "$-" == *i* ]]
    then
        source "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")"
        exit 0
    elif [[ `flatpak list 2>/dev/null | grep "retro_exo\.konsole"` ]]
    then
        flatpak run com.retro_exo.konsole -e /usr/bin/env bash "$PWD/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &
        exit 0
    else
        logger -s "eXo: weird system achievement unlocked - None of the 25 supported terminal emulators are installed."
        exit 1
    fi
elif [[ "$OSTYPE" == "darwin"* ]]
then
    source "$PWD/$(basename -- "${BASH_SOURCE%.command}.msh")"
    exit 0
else
    logger -s "eXo: Unsupported OS"
    exit 1
fi
EOF
    [ -e "$currentScript" ] && chmod +x "${currentScript%.bsh}.command" && chmod -x "$currentScript"
done

rm eXo*/\!*/*/exception.command eXo*/\!*/*/*/exception.command 2>/dev/null
rm util/install.command util/ip.command util/launch.command util/\!languagepacks/*.command util/GBC/FRUA_Module_Manager.command util/GBC/FRUA_Module_Manager.bsh util/AltLauncher.command 2>/dev/null

echo ""
echo "Fixing dosbox.conf typos with known solutions."
#[ -e eXoDOS/\!dos/m1tank/dosbox_tandy.conf ] && sed -i -e "s/autotype -w \.2 5 5 2 N/autotype -w .2 3 5 2 N/I" eXoDOS/\!dos/m1tank/dosbox.conf
#other issues with tandy for the above, ticketed in GitHub

echo "Fixing dosbox.conf file and directory references. This may take a while."

for file in eXo*/\!*/*/*.conf eXo*/\!*/*/*/*.conf dosbox/*.conf dosbox/*/*.conf emulators/dosbox/*.conf emulators/dosbox/*/*.conf Magazines/*/*.conf Magazines/*/*/*.conf dosbox/*.bak dosbox/*/*.bak emulators/dosbox/*.bak emulators/dosbox/*/*.bak emulators/dosbox/*.txt
do
    [ -e "$file" ] && sed -i -e "s/PPMode/PPmode/I" "$file"
done 2>/dev/null

[ -e eXoDOS/\!dos/11thHour/dosbox.conf ] && sed -i -e "s/\\\eXoDOS\\\11thhour/\\\eXoDOS\\\11thHour/Ig" eXoDOS/\!dos/11thHour/dosbox.conf
[ -e eXoDOS/\!dos/1942PAW/dosbox.conf ] && sed -i -e "s/1942PAW\\\CD\\\/1942PAW\\\cd\\\/" eXoDOS/\!dos/1942PAW/dosbox.conf
[ -e eXoDOS/\!dos/442/dosbox.conf ] && sed -i -e "s/442\\\cd\\\/442\\\CD\\\/" eXoDOS/\!dos/442/dosbox.conf
[ -e eXoDOS/\!dos/ACF95/dosbox.conf ] && sed -i -e "s/ACF95\\\cd\\\/ACF95\\\CD\\\/" eXoDOS/\!dos/ACF95/dosbox.conf
[ -e eXoDOS/\!dos/Airstrik/dosbox.conf ] && sed -i -e "s/cd\\\ATF2\.iso/cd\\\ATF2.ISO/" eXoDOS/\!dos/Airstrik/dosbox.conf
[ -e eXoDOS/\!dos/amaeden/dosbox.conf ] && sed -i -e "s/\\\cd\\\/\\\CD\\\/Ig" eXoDOS/\!dos/amaeden/dosbox.conf
[ -e eXoDOS/\!dos/amaeden/dosbox.conf ] && sed -i -e "s/\\\floppy\\\d\([[:digit:]]\)\.ima/\\\floppy\\\d\1.IMA/Ig" eXoDOS/\!dos/amaeden/dosbox.conf
[ -e eXoDOS/\!dos/amonra/dosbox.conf ] && sed -i -e "s/\\\amonra\\\cd\\\/\\\amonra\\\CD\\\/Ig" eXoDOS/\!dos/amonra/dosbox.conf
[ -e eXoDOS/\!dos/amonra/dosbox.conf ] && sed -i -e "s/amonra\\\floppy\\\audio\.ima/amonra\\\floppy\\\Audio.ima/Ig" eXoDOS/\!dos/amonra/dosbox.conf
[ -e eXoDOS/\!dos/Apodrasi/dosbox.conf ] && sed -i -e "s/Apodrasi\\\cd\\\/Apodrasi\\\CD\\\/" eXoDOS/\!dos/Apodrasi/dosbox.conf
[ -e eXoDOS/\!dos/Astrorck/dosbox.conf ] && sed -i -e "s/Astrorck\\\CD\\\Astrorck\.cue/Astrorck\\\CD\\\Astrorck.CUE/" eXoDOS/\!dos/Astrorck/dosbox.conf
[ -e eXoDOS/\!dos/AtW/dosbox.conf ] && sed -i -e "s/eXoDOS\\\ATW/eXoDOS\\\AtW/" eXoDOS/\!dos/AtW/dosbox.conf
[ -e eXoDOS/\!dos/AtWXmas/dosbox.conf ] && sed -i -e "s/eXoDOS\\\ATWXmas/eXoDOS\\\AtWXmas/" eXoDOS/\!dos/AtWXmas/dosbox.conf
[ -e eXoDOS/\!dos/BallHell/dosbox.conf ] && sed -i -e "s/BallHell\\\cd\\\/BallHell\\\CD\\\/" eXoDOS/\!dos/BallHell/dosbox.conf
[ -e eXoDOS/\!dos/bangalor/dosbox.conf ] && sed -i -e "s/eXoDOS\\\Bangalor/eXoDOS\\\bangalor/" eXoDOS/\!dos/bangalor/dosbox.conf
[ -e eXoDOS/\!dos/BatChop/dosbox.conf ] && sed -i -e "s/eXoDOS\\\BatCHop/eXoDOS\\\BatChop/" eXoDOS/\!dos/BatChop/dosbox.conf
[ -e eXoDOS/\!dos/bchessCD/dosbox.conf ] && sed -i -e "s/eXoDOS\\\bchesscd/eXoDOS\\\bchessCD/" eXoDOS/\!dos/bchessCD/dosbox.conf
[ -e eXoDOS/\!dos/beamish/dosbox.conf ] && sed -i -e "s/beamish\\\CD\\\/beamish\\\cd\\\/" eXoDOS/\!dos/beamish/dosbox.conf
[ -e eXoDOS/\!dos/BrutalPa/dosbox.conf ] && sed -i -e "s/BrutalPa\\\cd\\\/BrutalPa\\\CD\\\/" eXoDOS/\!dos/BrutalPa/dosbox.conf
[ -e eXoDOS/\!dos/castleb/dosbox.conf ] && sed -i -e "s/castleb\\\cd\\\/castleb\\\CD\\\/" eXoDOS/\!dos/castleb/dosbox.conf
[ -e eXoDOS/\!dos/chewy/dosbox.conf ] && sed -i -e "s/chewy\\\cd\\\/chewy\\\CD\\\/" eXoDOS/\!dos/chewy/dosbox.conf
[ -e eXoDOS/\!dos/colorama/dosbox.conf ] && sed -i -e "s/colorama\\\cd\\\/colorama\\\CD\\\/" eXoDOS/\!dos/colorama/dosbox.conf
[ -e eXoDOS/\!dos/coversp/dosbox.conf ] && sed -i -e "s/coversp\\\cd\\\poker\.cue/coversp\\\CD\\\Poker.cue/" eXoDOS/\!dos/coversp/dosbox.conf
[ -e eXoDOS/\!dos/Darkseed/dosbox.conf ] && sed -i -e "s/eXoDOS\\\darkseed/eXoDOS\\\Darkseed/" eXoDOS/\!dos/Darkseed/dosbox.conf
[ -e eXoDOS/\!dos/defcrown/dosbox_tandy.conf ] && sed -i -e "s/DOTCEGA\.IMG/DOTCEGA.img/" eXoDOS/\!dos/defcrown/dosbox_tandy.conf
[ -e eXoDOS/\!dos/DejaVu/dosbox.conf ] && sed -i -e "s/eXoDOS\\\dejavu/eXoDOS\\\DejaVu/" eXoDOS/\!dos/DejaVu/dosbox.conf
[ -e eXoDOS/\!dos/dinoadv/dosbox.conf ] && sed -i -e "s/dinoadv\\\cd\\\/dinoadv\\\CD\\\/" eXoDOS/\!dos/dinoadv/dosbox.conf
[ -e eXoDOS/\!dos/DinoAdvn/dosbox.conf ] && sed -i -e "s/DinoAdvn\\\cd\\\/DinoAdvn\\\CD\\\/" eXoDOS/\!dos/DinoAdvn/dosbox.conf
[ -e eXoDOS/\!dos/drakkhen/dosbox.conf ] && sed -i -e "s/eXoDOS\\\DRAKKHEN/eXoDOS\\\drakkhen/" eXoDOS/\!dos/drakkhen/dosbox.conf
[ -e eXoDOS/\!dos/Duke\!Z/dosbox.conf ] && sed -i -e "s/imgmount d  /imgmount d /" eXoDOS/\!dos/Duke\!Z/dosbox.conf
[ -e eXoDOS/\!dos/Ebola/dosbox.conf ] && sed -i -e "s/Ebola\\\cd\\\/Ebola\\\CD\\\/" eXoDOS/\!dos/Ebola/dosbox.conf
[ -e eXoDOS/\!dos/EnemFSp/dosbox.conf ] && sed -i -e "s/EnemFSp\\\cd\\\/EnemFSp\\\CD\\\/" eXoDOS/\!dos/EnemFSp/dosbox.conf
[ -e eXoDOS/\!dos/Enrak/dosbox.conf ] && sed -i -e "s/eXoDOS\\\enrak/eXoDOS\\\Enrak/" eXoDOS/\!dos/Enrak/dosbox.conf
[ -e eXoDOS/\!dos/erudit/dosbox.conf ] && sed -i -e "s/eXoDOS\\\Erudit/eXoDOS\\\erudit/" eXoDOS/\!dos/erudit/dosbox.conf
[ -e eXoDOS/\!dos/EscSt7/dosbox.conf ] && sed -i -e "s/EscSt7\\\Floppy/EscSt7\\\floppy/" eXoDOS/\!dos/EscSt7/dosbox.conf
[ -e eXoDOS/\!dos/fieldglo/dosbox.conf ] && sed -i -e "s/fieldglo\\\cd\\\/fieldglo\\\CD\\\/" eXoDOS/\!dos/fieldglo/dosbox.conf
[ -e eXoDOS/\!dos/FightDSE/dosbox.conf ] && sed -i -e "s/cd\\\FDUEL\.cue/cd\\\FDUEL.CUE/" eXoDOS/\!dos/FightDSE/dosbox.conf
[ -e eXoDOS/\!dos/FootM98/dosbox.conf ] && sed -i -e "s/CD\\\FM98\.cue/CD\\\FM98.CUE/" eXoDOS/\!dos/FootM98/dosbox.conf
[ -e eXoDOS/\!dos/FunNGame/dosbox.conf ] && sed -i -e "s/FunNGame\\\cd\\\/FunNGame\\\CD\\\/" eXoDOS/\!dos/FunNGame/dosbox.conf
[ -e eXoDOS/\!dos/GalPani/dosbox.conf ] && sed -i -e "s/GalPani\\\cd\\\/GalPani\\\CD\\\/" eXoDOS/\!dos/GalPani/dosbox.conf
[ -e eXoDOS/\!dos/GalPani2/dosbox.conf ] && sed -i -e "s/GalPani2\\\cd\\\/GalPani2\\\CD\\\/" eXoDOS/\!dos/GalPani2/dosbox.conf
[ -e eXoDOS/\!dos/gftracy/dosbox.conf ] && sed -i -e "s/gftracy\\\cd\\\/gftracy\\\CD\\\/" eXoDOS/\!dos/gftracy/dosbox.conf
[ -e eXoDOS/\!dos/gk1/dosbox.conf ] && sed -i -e "s/eXoDOS\\\GK1/eXoDOS\\\gk1/" eXoDOS/\!dos/gk1/dosbox.conf
[ -e eXoDOS/\!dos/GK2/dosbox.conf ] && sed -i -e "s/GK2\\\cd\\\/GK2\\\CD\\\/g" eXoDOS/\!dos/GK2/dosbox.conf
[ -e eXoDOS/\!dos/gob2/dosbox.conf ] && sed -i -e "s/gob2\\\floppy\\\1\.ima/gob2\\\floppy\\\1.IMA/" eXoDOS/\!dos/gob2/dosbox.conf
[ -e eXoDOS/\!dos/gob2/dosbox.conf ] && sed -i -e "s/gob2\\\floppy\\\2\.ima/gob2\\\floppy\\\2.IMA/" eXoDOS/\!dos/gob2/dosbox.conf
[ -e eXoDOS/\!dos/GuySpyan/dosbox.conf ] && sed -i -e "s/GuySpyan\\\cd\\\/GuySpyan\\\CD\\\/" eXoDOS/\!dos/GuySpyan/dosbox.conf
[ -e eXoDOS/\!dos/HACK/dosbox.conf ] && sed -i -e "s/eXoDOS\\\hack/eXoDOS\\\HACK/" eXoDOS/\!dos/HACK/dosbox.conf
[ -e eXoDOS/\!dos/HARVEST/dosbox.conf ] && sed -i -e "s/eXoDOS\\\harvest/eXoDOS\\\HARVEST/" eXoDOS/\!dos/HARVEST/dosbox.conf
[ -e eXoDOS/\!dos/HARVEST/dosbox.conf ] && sed -i -e "s/\.iso/.ISO/g" eXoDOS/\!dos/HARVEST/dosbox.conf
[ -e eXoDOS/\!dos/HaunCas/dosbox.conf ] && sed -i -e "s/HaunCas\\\cd\\\/HaunCas\\\CD\\\/" eXoDOS/\!dos/HaunCas/dosbox.conf
[ -e eXoDOS/\!dos/HickTown/dosbox.conf ] && sed -i -e "s/eXoDOS\\\hicktown/eXoDOS\\\HickTown/" eXoDOS/\!dos/HickTown/dosbox.conf
[ -e eXoDOS/\!dos/HugoMaze/dosbox.conf ] && sed -i -e "s/eXoDOS\\\hugomaze/eXoDOS\\\HugoMaze/" eXoDOS/\!dos/HugoMaze/dosbox.conf
[ -e eXoDOS/\!dos/Iceman/dosbox.conf ] && sed -i -e "s/eXoDOS\\\iceman/eXoDOS\\\Iceman/" eXoDOS/\!dos/Iceman/dosbox.conf
[ -e eXoDOS/\!dos/InExtrem/dosbox.conf ] && sed -i -e "s/InExtrem\\\floppy/InExtrem\\\Floppy/g" eXoDOS/\!dos/InExtrem/dosbox.conf
[ -e eXoDOS/\!dos/KSoul/dosbox.conf ] && sed -i -e "s/eXoDOS\\\Ksoul/eXoDOS\\\KSoul/" eXoDOS/\!dos/KSoul/dosbox.conf
[ -e eXoDOS/\!dos/lafferu/dosbox.conf ] && sed -i -e "s/eXoDOS\\\LafferU/eXoDOS\\\lafferu\\\CD\\\/" eXoDOS/\!dos/lafferu/dosbox.conf
[ -e eXoDOS/\!dos/LSL7DOS/dosbox.conf ] && sed -i -e "s/eXoDOS\\\lsl7dos\\\cd\\\/eXoDOS\\\LSL7DOS\\\CD\\\/" eXoDOS/\!dos/LSL7DOS/dosbox.conf
[ -e eXoDOS/\!dos/LSL7DOS/dosbox.conf ] && sed -i -e "s/eXoDOS\\\lsl7dos/eXoDOS\\\LSL7DOS/" eXoDOS/\!dos/LSL7DOS/dosbox.conf
[ -e eXoDOS/\!dos/mastori2/dosbox.conf ] && sed -i -e "s/mps\\\orion2\\\/MPS\\\ORION2\\\/" eXoDOS/\!dos/mastori2/dosbox.conf
[ -e eXoDOS/\!dos/MegaMa94/dosbox.conf ] && sed -i -e "s/MegaMa94\\\CD\\\/MegaMa94\\\cd\\\/" eXoDOS/\!dos/MegaMa94/dosbox.conf
[ -e eXoDOS/\!dos/MegaMaze/dosbox.conf ] && sed -i -e "s/MegaMaze\\\cd\\\/MegaMaze\\\CD\\\/" eXoDOS/\!dos/MegaMaze/dosbox.conf
[ -e eXoDOS/\!dos/Midway/dosbox.conf ] && sed -i -e "s/Midway\\\cd\\\/Midway\\\CD\\\/" eXoDOS/\!dos/Midway/dosbox.conf
[ -e eXoDOS/\!dos/MiniPrin/dosbox.conf ] && sed -i -e "s/eXoDOS\\\miniprin/eXoDOS\\\MiniPrin/" eXoDOS/\!dos/MiniPrin/dosbox.conf
[ -e eXoDOS/\!dos/MMansion/dosbox.conf ] && sed -i -e "s/eXoDOS\\\mmansion/eXoDOS\\\MMansion/" eXoDOS/\!dos/MMansion/dosbox.conf
[ -e eXoDOS/\!dos/MonmallA/dosbox.conf ] && sed -i -e "s/MonmallA\\\CD\\\/MonmallA\\\cd\\\/" eXoDOS/\!dos/MonmallA/dosbox.conf
[ -e eXoDOS/\!dos/MRPlus/dosbox.conf ] && sed -i -e "s/eXoDOS\\\MRPLus/eXoDOS\\\MRPlus/" eXoDOS/\!dos/MRPlus/dosbox.conf
[ -e eXoDOS/\!dos/mutanoiW/dosbox.conf ] && sed -i -e "s/\\\floppy\\\disk0\([[:digit:]]\)\.ima/\\\floppy\\\DISK0\1.IMA/Ig" eXoDOS/\!dos/mutanoiW/dosbox.conf
[ -e eXoDOS/\!dos/NewsRmPr/dosbox.conf ] && sed -i -e "s/\\\floppy\\\disk0\([[:digit:]]\)\.img/\\\floppy\\\Disk0\1.img/Ig" eXoDOS/\!dos/NewsRmPr/dosbox.conf
[ -e eXoDOS/\!dos/OpJuBec/dosbox.conf ] && sed -i -e "s/OpJuBec\\\cd\\\/OpJuBec\\\CD\\\/" eXoDOS/\!dos/OpJuBec/dosbox.conf
[ -e eXoDOS/\!dos/PBase/dosbox.conf ] && sed -i -e "s/PBase\\\cd\\\/PBase\\\CD\\\/" eXoDOS/\!dos/PBase/dosbox.conf
[ -e eXoDOS/\!dos/PQ1_VGA/dosbox.conf ] && sed -i -e "s/eXoDOS\\\pq1_vga/eXoDOS\\\PQ1_VGA/" eXoDOS/\!dos/PQ1_VGA/dosbox.conf
[ -e eXoDOS/\!dos/prnmania/dosbox.conf ] && sed -i -e "s/prnmania\\\cd\\\/prnmania\\\CD\\\/g" eXoDOS/\!dos/prnmania/dosbox.conf
[ -e eXoDOS/\!dos/puttmoon/dosbox.conf ] && sed -i -e "s/puttmoon\\\cd\\\/puttmoon\\\CD\\\/g" eXoDOS/\!dos/puttmoon/dosbox.conf
[ -e eXoDOS/\!dos/puttpara/dosbox.conf ] && sed -i -e "s/puttpara\\\cd\\\/puttpara\\\CD\\\/g" eXoDOS/\!dos/puttpara/dosbox.conf
[ -e eXoDOS/\!dos/Quarant/dosbox.conf ] && sed -i -e "s/CD\\\Quarantine\.cue/CD\\\QUARANTINE.cue/" eXoDOS/\!dos/Quarant/dosbox.conf
[ -e eXoDOS/\!dos/QuizKids/dosbox.conf ] && sed -i -e "s/QuizKids\\\floppy\\\QuizKids\.ima/QuizKids\\\floppy\\\QuizKids.IMA/" eXoDOS/\!dos/QuizKids/dosbox.conf
[ -e eXoDOS/\!dos/RadixBey/dosbox.conf ] && sed -i -e "s/RadixBey\\\cd\\\/RadixBey\\\CD\\\/" eXoDOS/\!dos/RadixBey/dosbox.conf
[ -e eXoDOS/\!dos/RaymanFr/dosbox.conf ] && sed -i -e "s/RaymanFr\\\cd\\\/RaymanFr\\\CD\\\/" eXoDOS/\!dos/RaymanFr/dosbox.conf
[ -e eXoDOS/\!dos/ReadRab2/dosbox.conf ] && sed -i -e "s/ReadRab2\\\floppy\\\image\.ima/ReadRab2\\\floppy\\\image.IMA/" eXoDOS/\!dos/ReadRab2/dosbox.conf
[ -e eXoDOS/\!dos/RECALL/dosbox.conf ] && sed -i -e "s/eXoDOS\\\recall/eXoDOS\\\RECALL/" eXoDOS/\!dos/RECALL/dosbox.conf
[ -e eXoDOS/\!dos/RM_CP/dosbox.conf ] && sed -i -e "s/RM_CP\\\cd\\\/RM_CP\\\CD\\\/g" eXoDOS/\!dos/RM_CP/dosbox.conf
[ -e eXoDOS/\!dos/RM_DW/dosbox.conf ] && sed -i -e "s/RM_DW\\\cd\\\/RM_DW\\\CD\\\/g" eXoDOS/\!dos/RM_DW/dosbox.conf
[ -e eXoDOS/\!dos/RM_Entity/dosbox.conf ] && sed -i -e "s/RM_Entity\\\cd\\\/RM_Entity\\\CD\\\/g" eXoDOS/\!dos/RM_Entity/dosbox.conf
[ -e eXoDOS/\!dos/RM_FT/dosbox.conf ] && sed -i -e "s/RM_FT\\\cd\\\FL2CD\.iso/RM_FT\\\CD\\\FL2CD.ISO/g" eXoDOS/\!dos/RM_FT/dosbox.conf
[ -e eXoDOS/\!dos/RM_FT/dosbox.conf ] && sed -i -e "s/RM_FT\\\cd\\\FL3CD\.iso/RM_FT\\\CD\\\FL3CD.ISO/g" eXoDOS/\!dos/RM_FT/dosbox.conf
[ -e eXoDOS/\!dos/RM_FT/dosbox.conf ] && sed -i -e "s/RM_FT\\\cd\\\Flash1\.iso/RM_FT\\\CD\\\FLASH1.ISO/g" eXoDOS/\!dos/RM_FT/dosbox.conf
[ -e eXoDOS/\!dos/RM_LOTR/dosbox.conf ] && sed -i -e "s/RM_LOTR\\\cd\\\/RM_LOTR\\\CD\\\/g" eXoDOS/\!dos/RM_LOTR/dosbox.conf
[ -e eXoDOS/\!dos/RM_TH/dosbox.conf ] && sed -i -e "s/RM_TH\\\cd\\\/RM_TH\\\CD\\\/g" eXoDOS/\!dos/RM_TH/dosbox.conf
[ -e eXoDOS/\!dos/ROMANTIC/dosbox.conf ] && sed -i -e "s/ROMANTIC\\\CD\\\/ROMANTIC\\\cd\\\/" eXoDOS/\!dos/ROMANTIC/dosbox.conf
[ -e eXoDOS/\!dos/rzork/dosbox.conf ] && sed -i -e "s/rzork\\\cd\\\/rzork\\\CD\\\/" eXoDOS/\!dos/rzork/dosbox.conf
[ -e eXoDOS/\!dos/SGate/dosbox.conf ] && sed -i -e "s/eXoDOS\\\sgate/eXoDOS\\\SGate/" eXoDOS/\!dos/SGate/dosbox.conf
#[ -e eXoDOS/\!dos/shadcast/dosbox.conf ] && sed -i -e 's/"  "/" "/' eXoDOS/\!dos/shadcast/dosbox.conf
#[ -e eXoDOS/\!dos/shadcast/dosbox.conf ] && sed -i -e 's/"-t floppy/" -t floppy/' eXoDOS/\!dos/shadcast/dosbox.conf
[ -e eXoDOS/\!dos/SilkDust/dosbox.conf ] && sed -i -e "s/eXoDOS\\\silkdust/eXoDOS\\\SilkDust/" eXoDOS/\!dos/SilkDust/dosbox.conf
[ -e eXoDOS/\!dos/SSAPBAPF/dosbox.conf ] && sed -i -e "s/SSAPBAPF\\\cd\\\/SSAPBAPF\\\CD\\\/" eXoDOS/\!dos/SSAPBAPF/dosbox.conf
[ -e eXoDOS/\!dos/Syndicat/dosbox.conf ] && sed -i -e "s/Syndicat\\\cd\\\/Syndicat\\\CD\\\/" eXoDOS/\!dos/Syndicat/dosbox.conf
[ -e eXoDOS/\!dos/TaleMyst/dosbox.conf ] && sed -i -e "s/\\\floppy\\\SIDE\([[:digit:]]\)\.IMG/\\\floppy\\\Side\1.img/Ig" eXoDOS/\!dos/TaleMyst/dosbox.conf
[ -e eXoDOS/\!dos/TankTheM/dosbox.conf ] && sed -i -e "s/TankTheM\\\cd\\\/TankTheM\\\CD\\\/" eXoDOS/\!dos/TankTheM/dosbox.conf
[ -e eXoDOS/\!dos/TGameWnC/dosbox.conf ] && sed -i -e "s/TGameWnC\\\cd\\\/TGameWnC\\\CD\\\/" eXoDOS/\!dos/TGameWnC/dosbox.conf
[ -e eXoDOS/\!dos/TheScott/dosbox.conf ] && sed -i -e "s/TheScott\\\cd\\\/TheScott\\\CD\\\/" eXoDOS/\!dos/TheScott/dosbox.conf
[ -e eXoDOS/\!dos/TheSocc2/dosbox.conf ] && sed -i -e "s/eXoDOS\\\theSocc2/eXoDOS\\\TheSocc2/" eXoDOS/\!dos/TheSocc2/dosbox.conf
[ -e eXoDOS/\!dos/ToonJam/dosbox.conf ] && sed -i -e "s/ToonJam\\\cd\\\/ToonJam\\\CD\\\/" eXoDOS/\!dos/ToonJam/dosbox.conf
[ -e eXoDOS/\!dos/torin/dosbox.conf ] && sed -i -e "s/torin\\\cd\\\/torin\\\CD\\\/" eXoDOS/\!dos/torin/dosbox.conf
[ -e eXoDOS/\!dos/TORNADO/dosbox.conf ] && sed -i -e "s/cd\\\TORNAD\.CUE/cd\\\TORNAD.cue/" eXoDOS/\!dos/TORNADO/dosbox.conf
[ -e eXoDOS/\!dos/ToyotaCe/dosbox.conf ] && sed -i -e "s/ToyotaCe\\\CD\\\/ToyotaCe\\\cd\\\/" eXoDOS/\!dos/ToyotaCe/dosbox.conf
[ -e eXoDOS/\!dos/TreaHunt/dosbox.conf ] && sed -i -e "s/TreaHunt\\\cd\\\/TreaHunt\\\CD\\\/g" eXoDOS/\!dos/TreaHunt/dosbox.conf
[ -e eXoDOS/\!dos/TTC1DOS/dosbox.conf ] && sed -i -e "s/TTC1DOS\\\cd\\\/TTC1DOS\\\CD\\\/g" eXoDOS/\!dos/TTC1DOS/dosbox.conf
[ -e eXoDOS/\!dos/Ultima1/dosbox.conf ] && sed -i -e "s/eXoDOS\\\ultima1/eXoDOS\\\Ultima1/" eXoDOS/\!dos/Ultima1/dosbox.conf
[ -e eXoDOS/\!dos/Ultima1/dosbox_cga.conf ] && sed -i -e "s/eXoDOS\\\ultima1/eXoDOS\\\Ultima1/" eXoDOS/\!dos/Ultima1/dosbox_cga.conf
[ -e eXoDOS/\!dos/Uninvite/dosbox.conf ] && sed -i -e "s/eXoDOS\\\uninvite/eXoDOS\\\Uninvite/" eXoDOS/\!dos/Uninvite/dosbox.conf
[ -e eXoDOS/\!dos/unlimadv/dosbox_mods.conf ] && sed -i -e "s/unlimadv\\\mods/unlimadv\\\MODS/g" eXoDOS/\!dos/unlimadv/dosbox_mods.conf
[ -e eXoDOS/\!dos/unlimadv/dosbox_mods_GBC.conf ] && sed -i -e "s/unlimadv\\\mods/unlimadv\\\MODS/g" eXoDOS/\!dos/unlimadv/dosbox_mods_GBC.conf
[ -e eXoDOS/\!dos/Vanguard/dosbox.conf ] && sed -i -e "s/Vanguard\\\cd\\\/Vanguard\\\CD\\\/g" eXoDOS/\!dos/Vanguard/dosbox.conf
[ -e eXoDOS/\!dos/vidjam/dosbox.conf ] && sed -i -e "s/eXoDOS\\\VidJam/eXoDOS\\\vidjam/" eXoDOS/\!dos/vidjam/dosbox.conf
[ -e eXoDOS/\!dos/VRChessP/dosbox.conf ] && sed -i -e "s/eXoDOS\\\VRCHessP/eXoDOS\\\VRChessP/" eXoDOS/\!dos/VRChessP/dosbox.conf
[ -e eXoDOS/\!dos/VRChessP/dosbox.conf ] && sed -i -e "s/eXoDOS\\\VRChessP\\\cd\\\/eXoDOS\\\VRChessP\\\CD\\\/" eXoDOS/\!dos/VRChessP/dosbox.conf
[ -e eXoDOS/\!dos/wastland/dosbox.conf ] && sed -i -e "s/exodos\\\wastland/eXoDOS\\\wastland/" eXoDOS/\!dos/wastland/dosbox.conf
[ -e eXoDOS/\!dos/wquestv2/dosbox.conf ] && sed -i -e "s/eXoDOS\\\wQuestv2/eXoDOS\\\wquestv2/" eXoDOS/\!dos/wquestv2/dosbox.conf
[ -e eXoDOS/\!dos/wucsd/dosbox.conf ] && sed -i -e "s/wucsd\\\cd\\\/wucsd\\\CD\\\/g" eXoDOS/\!dos/wucsd/dosbox.conf
[ -e eXoDOS/\!dos/Zak/dosbox.conf ] && sed -i -e "s/eXoDOS\\\zak/eXoDOS\\\Zak/" eXoDOS/\!dos/Zak/dosbox.conf
[ -e eXoDOS/\!dos/ZakEnh/dosbox.conf ] && sed -i -e "s/eXoDOS\\\zakenh/eXoDOS\\\ZakEnh/" eXoDOS/\!dos/ZakEnh/dosbox.conf
[ -e eXoDOS/\!dos/Zool2/dosbox.conf ] && sed -i -e "s/Zool2\\\cd\\\/Zool2\\\CD\\\/" eXoDOS/\!dos/Zool2/dosbox.conf
[ -e Magazines/PCGamerUS/PCGamer_1995_03/dosbox.conf ] && sed -i -e "s/cd\\\pcgamer\.iso/cd\\\pcgamer.ISO/" Magazines/PCGamerUS/PCGamer_1995_03/dosbox.conf
[ -e Magazines/PCGamerUS/PCGamer_1996_03/dosbox.conf ] && sed -i -e "s/cd\\\pcgamer\.iso/cd\\\pcgamer.ISO/" Magazines/PCGamerUS/PCGamer_1996_03/dosbox.conf
[ -e Magazines/PCGamerUS/PCGamer_1997_10/dosbox.conf ] && sed -i -e "s/cd\\\pcgamer\.cue/cd\\\PCGAMER.cue/" Magazines/PCGamerUS/PCGamer_1997_10/dosbox.conf
[ -e Magazines/PCGamerUS/PCGamer_1997_12/dosbox.conf ] && sed -i -e "s/cd\\\pcgamer_1\.cue/cd\\\pcgamer_1.CUE/" Magazines/PCGamerUS/PCGamer_1997_12/dosbox.conf
[ -e Magazines/PCGamerUS/PCGamer_1997_12/dosbox.conf ] && sed -i -e "s/cd\\\pcgamer_2\.cue/cd\\\pcgamer_2.CUE/" Magazines/PCGamerUS/PCGamer_1997_12/dosbox.conf
[ -e Magazines/PCGamerUS/PCGamer_1998_07/dosbox.conf ] && sed -i -e "s/\\\c\.img/\\\c.IMG/" Magazines/PCGamerUS/PCGamer_1998_07/dosbox.conf
[ -e Magazines/PCGamerUS/PCGamer_1998_08/dosbox.conf ] && sed -i -e "s/\\\c\.img/\\\c.IMG/" Magazines/PCGamerUS/PCGamer_1998_08/dosbox.conf
[ -e Magazines/PCGamerUS/PCGamer_1998_08/dosbox.conf ] && sed -i -e "s/cd\\\PCGAMER\.iso/cd\\\pcgamer.iso/" Magazines/PCGamerUS/PCGamer_1998_08/dosbox.conf
[ -e Magazines/PCGamerUS/PCGamer_1998_09/dosbox.conf ] && sed -i -e "s/\\\c\.img/\\\c.IMG/" Magazines/PCGamerUS/PCGamer_1998_09/dosbox.conf
[ -e Magazines/PCGamerUS/PCGamer_1998_10/dosbox.conf ] && sed -i -e "s/\\\c\.img/\\\c.IMG/" Magazines/PCGamerUS/PCGamer_1998_10/dosbox.conf
[ -e Magazines/PCGamerUS/PCGamer_1998_11/dosbox.conf ] && sed -i -e "s/\\\c\.img/\\\c.IMG/" Magazines/PCGamerUS/PCGamer_1998_08/dosbox.conf
[ -e Magazines/PCGamerUS/PCGamer_1998_12/dosbox.conf ] && sed -i -e "s/\\\c\.img/\\\c.IMG/" Magazines/PCGamerUS/PCGamer_1998_12/dosbox.conf

echo "Creating Linux DOSBox configuration files. This may take a few minutes."
rm eXo*/\!*/*/*_linux.conf eXo*/\!*/*/*/*_linux.conf dosbox/*_linux.conf dosbox/*/*_linux.conf emulators/dosbox/*_linux.conf emulators/dosbox/*/*_linux.conf Magazines/*/*_linux.conf Magazines/*/*/*_linux.conf 2>/dev/null
for file in eXo*/\!*/*/*.conf eXo*/\!*/*/*/*.conf dosbox/*.conf dosbox/*/*.conf emulators/dosbox/*.conf emulators/dosbox/*/*.conf Magazines/*/*.conf Magazines/*/*/*.conf
do
    [ -e "$file" ] && cp "$file" "${file%.conf}_linux.conf"
    [ -e "$file" ] && sed -i -e "/mount/ s|\\\|/|Ig" "${file%.conf}_linux.conf"
    [ -e "$file" ] && sed -i -e "/boot/ s|\\\|/|Ig" "${file%.conf}_linux.conf"
    [ -e "$file" ] && sed -i -e "/soundfont/ s|\\\|/|Ig" "${file%.conf}_linux.conf"
    [ -e "$file" ] && sed -i -e "/romdir/ s|\\\|/|Ig" "${file%.conf}_linux.conf"
    [ -e "$file" ] && sed -i -e "/glshader/ s|\\\|/|Ig" "${file%.conf}_linux.conf"
    [ -e "$file" ] && sed -i -e "s|^fluid\.soundfont=\./mt32/SoundCanvas\.sf2|midiconfig=128:0\nfluid.driver=alsa\nfluid.soundfont=./mt32/SoundCanvas.sf2|I" "${file%.conf}_linux.conf"
done 2>/dev/null

rm dosbox/*_linux.bak dosbox/*/*_linux.bak emulators/dosbox/*_linux.bak emulators/dosbox/*/*_linux.bak 2>/dev/null
for file in dosbox/*.bak dosbox/*/*.bak emulators/dosbox/*.bak emulators/dosbox/*/*.bak
do
    [ -e "$file" ] && cp "$file" "${file%.bak}_linux.bak"
    [ -e "$file" ] && sed -i -e "/mount/ s|\\\|/|Ig" "${file%.bak}_linux.bak"
    [ -e "$file" ] && sed -i -e "/boot/ s|\\\|/|Ig" "${file%.bak}_linux.bak"
    [ -e "$file" ] && sed -i -e "/soundfont/ s|\\\|/|Ig" "${file%.bak}_linux.bak"
    [ -e "$file" ] && sed -i -e "/romdir/ s|\\\|/|Ig" "${file%.bak}_linux.bak"
    [ -e "$file" ] && sed -i -e "/glshader/ s|\\\|/|Ig" "${file%.bak}_linux.bak"
    [ -e "$file" ] && sed -i -e "s|^fluid\.soundfont=\./mt32/SoundCanvas\.sf2|midiconfig=128:0\nfluid.driver=alsa\nfluid.soundfont=./mt32/SoundCanvas.sf2|I" "${file%.bak}_linux.bak"
done 2>/dev/null

echo "Applying Linux-only file-specific backend fixes."
[ `ls -1 ../eXoMerge.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e 's|d:\\\\|/home/user/|Ig' ../eXoMerge.bsh 2>/dev/null
[ `ls -1 ../eXoMerge.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e 's/Ctrl+Break/Ctrl+c/Ig' ../eXoMerge.bsh 2>/dev/null

[ `ls -1 Update/update_xml.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e 's#^: end#: end\
clear\
echo "Would you like to create/update an icon on your desktop?"\
while true\
do\
    read -p "\[Y\]es or \[N\]o " choice\
    case \$choice in\
        \[Yy\]* ) echo "\[Desktop Entry\]" > ~/Desktop/eXoDOS.desktop\
                echo "Encoding=UTF-8" >> ~/Desktop/eXoDOS.desktop\
                echo "Encoding=UTF-8" >> ~/Desktop/eXoDOS.desktop\
                echo "Version=1.0" >> ~/Desktop/eXoDOS.desktop\
                echo "Type=Application" >> ~/Desktop/eXoDOS.desktop\
                echo "Terminal=false" >> ~/Desktop/eXoDOS.desktop\
                echo "Exec=\\"\${scriptDir%/eXo/util}/exogui.command\\"" >> ~/Desktop/eXoDOS.desktop\
                echo "Name=eXoDOS" >> ~/Desktop/eXoDOS.desktop\
                echo "Icon=\${scriptDir}/exodos.ico" >> ~/Desktop/eXoDOS.desktop\
                break;;\
        \[Nn\]* ) errorlevel=2\
                break;;\
        *     ) printf "Invalid input.\n";;\
    esac\
done#I' Update/update_xml.bsh 2>/dev/null

echo "Applying Linux-only game fixes."
[ `ls -1 emulators/dosbox/options_linux.conf 2>/dev/null | wc -w` -gt 0 ] && grep -iq usescancodes emulators/dosbox/options_linux.conf 2>/dev/null || sed -i -e 's/\(\[sdl\]\)/\1\nusescancodes=false/' emulators/dosbox/options_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/bisle2/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/bisle2/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/breach2/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/breach2/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/Carmaged/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/Carmaged/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/comcon/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/comcon/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/comconra/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/comconra/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/gnb5dd/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/gnb5dd/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/GTA/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/GTA/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/hardnova/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/hardnova/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/heromm2d/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/heromm2d/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/JCATF/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/JCATF/dosbox_linux.conf 2>/dev/null
#[ `ls -1 eXoDOS/\!dos/kyra1/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s/cycles=40000/cycles=24000/I" eXoDOS/\!dos/kyra1/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/lemm3/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/lemm3/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/lemmings/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/lemmings/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/LewLeon/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/LewLeon/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/LivingBa/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/LivingBa/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/LowBlow/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e '/mididevice=default/a mt32.romdir=./mt32' eXoDOS/\!dos/LowBlow/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/Mean18/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/Mean18/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/MechW2/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/MechW2/dosbox_linux.conf 2>/dev/null #can be merged into the main zip at a later date
[ `ls -1 eXoDOS/\!dos/NFLChall/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/NFLChall/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/NORMAL/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/NORMAL/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/pice/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/pice/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/PPGolf/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/PPGolf/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/rarkani1/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/rarkani1/dosbox_linux.conf 2>/dev/null #can be merged into the main zip at a later date
[ `ls -1 eXoDOS/\!dos/Resurrec/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/Resurrec/dosbox_linux.conf 2>/dev/null
#[ `ls -1 eXoDOS/\!dos/stjudgec/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s/cycles=40000/cycles=25000/I" eXoDOS/\!dos/stjudgec/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/stjudgec/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/stjudgec/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/timegate/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/timegate/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/ultima5/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call transfer/call tran_lin/I" eXoDOS/\!dos/ultima5/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/ultima5/dosbox_upg_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call transfer/call tran_lin/I" eXoDOS/\!dos/ultima5/dosbox_upg_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/ultima6/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/ultima6/dosbox_linux.conf 2>/dev/null
[ `ls -1 eXoDOS/\!dos/ZAR/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" eXoDOS/\!dos/ZAR/dosbox_linux.conf 2>/dev/null
[ `ls -1 Magazines/Interactive\ Entertainment\ CD/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" Magazines/Interactive\ Entertainment\ CD/dosbox_linux.conf 2>/dev/null
[ `ls -1 Magazines/Interactive\ Entertainment\ CD/run.bak 2>/dev/null | wc -w` -gt 0 ] && cp Magazines/Interactive\ Entertainment\ CD/run.bak Magazines/Interactive\ Entertainment\ CD/run_lin.bak 2>/dev/null
[ `ls -1 Magazines/Interactive\ Entertainment\ CD/run_lin.bak 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/mount/ s|\\\|/|Ig" Magazines/Interactive\ Entertainment\ CD/run_lin.bak 2>/dev/null
[ `ls -1 Magazines/Interactive\ Entertainment\ CD/run.bat 2>/dev/null | wc -w` -gt 0 ] && cp Magazines/Interactive\ Entertainment\ CD/run.bat Magazines/Interactive\ Entertainment\ CD/run_lin.bat 2>/dev/null
[ `ls -1 Magazines/Interactive\ Entertainment\ CD/run_lin.bat 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/mount/ s|\\\|/|Ig" Magazines/Interactive\ Entertainment\ CD/run_lin.bat 2>/dev/null
[ `ls -1 Magazines/Interactive\ Entertainment\ CD/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/call run/call run_lin/I" Magazines/Interactive\ Entertainment\ CD/dosbox_linux.conf 2>/dev/null
[ `ls -1 Magazines/Interactive\ Entertainment\ CD.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/_lin/! s/run\.bak/run_lin.bak/I" Magazines/Interactive\ Entertainment\ CD.bsh 2>/dev/null
[ `ls -1 Magazines/Interactive\ Entertainment\ CD.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/run_lin\.bak/ s/run\.bat/run_lin.bat/I" Magazines/Interactive\ Entertainment\ CD.bsh 2>/dev/null
#[ `ls -1 Magazines/PCGamerUS/PCGamer_1997_10/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|cd/PCGAMER\.cue|cd/PCGAMER_linux.cue|" Magazines/PCGamerUS/PCGamer_1997_10/dosbox_linux.conf 2>/dev/null
#[ `ls -1 Magazines/PCGamerUS/PCGamer_1997_10/cd/PCGAMER.cue 2>/dev/null | wc -w` -gt 0 ] && cp Magazines/PCGamerUS/PCGamer_1997_10/cd/PCGAMER.cue Magazines/PCGamerUS/PCGamer_1997_10/cd/PCGAMER_linux.cue 2>/dev/null
#[ `ls -1 Magazines/PCGamerUS/PCGamer_1997_10/cd/PCGAMER_linux.cue 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s/PCGAMER\.BIN/PCGAMER.bin/" Magazines/PCGamerUS/PCGamer_1997_10/cd/PCGAMER_linux.cue 2>/dev/null
#[ `ls -1 Magazines/PCGamerUS/PCGamer_1997_11/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|cd/pcgamer\.cue|cd/pcgamer_linux.cue|" Magazines/PCGamerUS/PCGamer_1997_11/dosbox_linux.conf 2>/dev/null
#[ `ls -1 Magazines/PCGamerUS/PCGamer_1997_11/cd/pcgamer.cue 2>/dev/null | wc -w` -gt 0 ] && cp Magazines/PCGamerUS/PCGamer_1997_11/cd/pcgamer.cue Magazines/PCGamerUS/PCGamer_1997_11/cd/pcgamer_linux.cue 2>/dev/null
#[ `ls -1 Magazines/PCGamerUS/PCGamer_1997_11/cd/pcgamer_linux.cue 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s/PCGAMER\.BIN/pcgamer.bin/" Magazines/PCGamerUS/PCGamer_1997_11/cd/pcgamer_linux.cue 2>/dev/null
#[ `ls -1 Magazines/PCGamerUS/PCGamer_1997_12/dosbox_linux.conf 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|cd/pcgamer_1\.CUE|cd/pcgamer_1_linux.CUE|" Magazines/PCGamerUS/PCGamer_1997_12/dosbox_linux.conf 2>/dev/null
#[ `ls -1 Magazines/PCGamerUS/PCGamer_1997_12/cd/pcgamer_1.CUE 2>/dev/null | wc -w` -gt 0 ] && cp Magazines/PCGamerUS/PCGamer_1997_12/cd/pcgamer_1.CUE Magazines/PCGamerUS/PCGamer_1997_12/cd/pcgamer_1_linux.CUE 2>/dev/null
#[ `ls -1 Magazines/PCGamerUS/PCGamer_1997_12/cd/pcgamer_1_linux.CUE 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s/pcgamer_1\.bin/pcgamer_1.BIN/" Magazines/PCGamerUS/PCGamer_1997_12/cd/pcgamer_1_linux.CUE 2>/dev/null
[ `ls -1 eXoDOS/\!dos/120Deg/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/^flatpak run com\.retro_exo\.wine .\/eXoDOS\/120Deg\/sciAudio\/sciAudio.exe/,/^kill .*/ c\
flatpak run com.retro_exo.scummvm-2-3-0-git15811-gf97bfb7ce1 --config=./emulators/scummvm/svn/scummvm.ini -F -g3x --aspect-ratio -peXoDOS/120Deg sci-fanmade" eXoDOS/\!dos/120Deg/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/BRcdoom/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|flatpak run com.retro_exo.dosbox-ece-r4301|flatpak run com.retro_exo.wine emulators/dosbox/ece4230/DOSBox.exe|gI" eXoDOS/\!dos/BRcdoom/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/BRmatrix/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|flatpak run com.retro_exo.dosbox-ece-r4301|flatpak run com.retro_exo.wine emulators/dosbox/ece4230/DOSBox.exe|gI" eXoDOS/\!dos/BRmatrix/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/ckrynn/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|flatpak run com.retro_exo.dosbox-ece-r4301|flatpak run com.retro_exo.wine emulators/dosbox/ece4230/DOSBox.exe|gI" eXoDOS/\!dos/ckrynn/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/curse/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|flatpak run com.retro_exo.dosbox-ece-r4301|flatpak run com.retro_exo.wine emulators/dosbox/ece4230/DOSBox.exe|gI" eXoDOS/\!dos/curse/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/dkkrynn/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|flatpak run com.retro_exo.dosbox-ece-r4301|flatpak run com.retro_exo.wine emulators/dosbox/ece4230/DOSBox.exe|gI" eXoDOS/\!dos/dkkrynn/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/drkqueen/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|flatpak run com.retro_exo.dosbox-ece-r4301|flatpak run com.retro_exo.wine emulators/dosbox/ece4230/DOSBox.exe|gI" eXoDOS/\!dos/drkqueen/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/dune2/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e 's|"${dosbox}"|ece4230/DOSBox.exe|gI' eXoDOS/\!dos/dune2/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/dune2/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e 's|^\./eXoDOS/dune2/Dune2MouseHelper\.exe|flatpak run com.retro_exo.wine ./eXoDOS/dune2/Dune2MouseHelper.exe|gI' eXoDOS/\!dos/dune2/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/eob1/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|ASE 1|ASE.exe 1|I" eXoDOS/\!dos/eob1/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/eob1/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|flatpak run com.retro_exo.dosbox-ece-r4301|flatpak run com.retro_exo.wine emulators/dosbox/ece4230/DOSBox.exe|gI" eXoDOS/\!dos/eob1/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/eob1/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/flatpak run com.retro_exo.wine/ s|_linux||gI" eXoDOS/\!dos/eob1/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/eob2/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|ASE 2|ASE.exe 2|I" eXoDOS/\!dos/eob2/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/eob2/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|flatpak run com.retro_exo.dosbox-ece-r4301|flatpak run com.retro_exo.wine emulators/dosbox/ece4230/DOSBox.exe|gI" eXoDOS/\!dos/eob2/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/eob2/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/flatpak run com.retro_exo.wine/ s|_linux||gI" eXoDOS/\!dos/eob2/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/eob3/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|ASE3/ASE3|ASE3/ASE3.exe|I" eXoDOS/\!dos/eob3/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/eob3/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|flatpak run com.retro_exo.dosbox-ece-r4301|flatpak run com.retro_exo.wine emulators/dosbox/ece4230/DOSBox.exe|gI" eXoDOS/\!dos/eob3/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/eob3/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/flatpak run com.retro_exo.wine/ s|_linux||gI" eXoDOS/\!dos/eob3/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/eXoWAD/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|^gzrun\.bat|eval source gzrun.bsh|gI" eXoDOS/\!dos/eXoWAD/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/eXoWAD/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s/Windows 64/Linux 64/gI" eXoDOS/\!dos/eXoWAD/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/gatesf/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|flatpak run com.retro_exo.dosbox-ece-r4301|flatpak run com.retro_exo.wine emulators/dosbox/ece4230/DOSBox.exe|gI" eXoDOS/\!dos/gatesf/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/gfterri/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|^\./eXoDOS/gfterri/gf_terri/gfupdate$|flatpak run com.retro_exo.wine ./eXoDOS/gfterri/gf_terri/GFUpdate.exe|gI" eXoDOS/\!dos/gfterri/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/gftracy/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|^\./eXoDOS/gftracy/gf/gfupdate$|flatpak run com.retro_exo.wine ./eXoDOS/gftracy/GF/GFUpdate.exe|gI" eXoDOS/\!dos/gftracy/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/gnomer/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/^flatpak run com\.retro_exo\.wine .\/eXoDOS\/gnomer\/sciAudio\/sciAudio.exe/,/^kill .*/ c\
flatpak run com.retro_exo.scummvm-2-2-0 --config=./emulators/scummvm/scummvm_linux.ini -F -g3x --aspect-ratio -p./eXoDOS/gnomer sci-fanmade" eXoDOS/\!dos/gnomer/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/gob1/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|eXoDOS/gob1 gob|eXoDOS/gob1/GOB gob1|gI" eXoDOS/\!dos/gob1/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/gob2/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|eXoDOS/gob2 gob2|eXoDOS/gob2/GOB2 gob2|gI" eXoDOS/\!dos/gob2/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/GoldRush/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/echo \"Press 1 to play.*/,/^: dosbox$/ d" eXoDOS/\!dos/GoldRush/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/hoylebk3/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/SoundCanvas\.sf2.*scummvm/ s|/hoylebk3/scummvm |/hoylebk3 |gI" eXoDOS/\!dos/hoylebk3/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/LSL3/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|LSL3/scummvm|LSL3|gI" eXoDOS/\!dos/LSL3/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/pooldark/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|flatpak run com.retro_exo.dosbox-ece-r4301|flatpak run com.retro_exo.wine emulators/dosbox/ece4230/DOSBox.exe|gI" eXoDOS/\!dos/pooldark/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/poolrad/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|flatpak run com.retro_exo.dosbox-ece-r4301|flatpak run com.retro_exo.wine emulators/dosbox/ece4230/DOSBox.exe|gI" eXoDOS/\!dos/poolrad/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/RoboWar1/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|^\"\./eXoDOS/\${gamedir}/RW1_EDIT\.EXE\"|flatpak run com.retro_exo.wine \"./eXoDOS/\${gamedir}/RW1_EDIT.EXE\"|I" eXoDOS/\!dos/RoboWar1/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/secsilbl/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|flatpak run com.retro_exo.dosbox-ece-r4301|flatpak run com.retro_exo.wine emulators/dosbox/ece4230/DOSBox.exe|gI" eXoDOS/\!dos/secsilbl/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/Sigil/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|^gzrun\.bat|eval source gzrun.bsh|gI" eXoDOS/\!dos/Sigil/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/Sigil2/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|^gzrun\.bat|eval source gzrun.bsh|gI" eXoDOS/\!dos/Sigil2/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/SystemSh/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s/^SSP\.EXE/flatpak run com.retro_exo.wine SSP.exe/I" eXoDOS/\!dos/SystemSh/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/SkyNET/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e 's|"${dosbox}"|ece4481/DOSBox.exe|gI' eXoDOS/\!dos/SkyNET/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/tagent/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e '/^: end/i\
: scummvm\
cd ..\
cd ..\
cd ..\
flatpak run com.retro_exo.scummvm-2-2-0 --config=./emulators/scummvm/scummvm_linux.ini -F -g3x --aspect-ratio -p./eXoDOS/tagent teenagent\
goto end && [[ $0 != $BASH_SOURCE ]] && return\
' eXoDOS/\!dos/tagent/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/TermFS/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e 's|"${dosbox}"|ece4481/DOSBox.exe|gI' eXoDOS/\!dos/TermFS/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/TNM7SE/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e 's|tnmdbwrp |tnmdbwrp.exe |gI' eXoDOS/\!dos/TNM7SE/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/TNM7SE/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e '/*\.tnm/{p;s/*\.tnm/*.TNM/}' eXoDOS/\!dos/TNM7SE/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/TNM7SE/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e '/\*\.EXE/! s/\(for i in \*\.exe\)/\1 *.EXE/I' eXoDOS/\!dos/TNM7SE/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/TreasSav/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|flatpak run com.retro_exo.dosbox-ece-r4301|flatpak run com.retro_exo.wine emulators/dosbox/ece4230/DOSBox.exe|gI" eXoDOS/\!dos/TreasSav/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/troltale/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "/scummvm/ s/ troll/ agi:troll/gI" eXoDOS/\!dos/troltale/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/ultima5/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|flatpak run com.retro_exo.dosbox-ece-r4301|flatpak run com.retro_exo.wine emulators/dosbox/ece4230/DOSBox.exe|gI" eXoDOS/\!dos/ultima5/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/ultima5/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s/Ultimapper_5 /Ultimapper_5.exe /gI" eXoDOS/\!dos/ultima5/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/ultima5/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s/Ultimapper_5\`/Ultimapper_5.exe\`/gI" eXoDOS/\!dos/ultima5/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/unlimadv/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e "s|flatpak run com.retro_exo.dosbox-ece-r4301|flatpak run com.retro_exo.wine emulators/dosbox/ece4230/DOSBox.exe|gI" eXoDOS/\!dos/unlimadv/exception.bsh 2>/dev/null
[ `ls -1 eXoDOS/\!dos/WarCraft/exception.bsh 2>/dev/null | wc -w` -gt 0 ] && sed -i -e 's|"${dosbox}"|ece4481/DOSBox.exe|gI' eXoDOS/\!dos/WarCraft/exception.bsh 2>/dev/null
echo ""

echo "Converting shell script reference files."

rm -f util/\!*/texts*_linux.txt 2>/dev/null
for file in util/\!*/texts*.txt
do
    [ -e "$file" ] && cp "$file" "${file%.txt}_linux.txt"
done
for file in util/\!*/texts*_linux.txt
do
    [ -e "$file" ] && sed -i -e 's/\\/\\\\/g' "$file"
    [ -e "$file" ] && sed -i -e "s/\"/\\\\\"/g" "$file"
    [ -e "$file" ] && sed -i -e "s/\\$/\\\\$/g" "$file"
    [ -e "$file" ] && sed -i -e 's/`/\\`/g' "$file"
    [ -e "$file" ] && sed -i -e 's/\(^[^=]*\)=/\L\1\E=\"/' "$file"
    [ -e "$file" ] && sed -i -e 's/[[:space:]\t]*$//' "$file"
    [ -e "$file" ] && sed -i -e "s/$/\"/" "$file"
    [ -e "$file" ] && dos2unix "$file"
done

cp emulators/dosbox/alt_settings.txt emulators/dosbox/alt_settings_linux.txt 2>/dev/null
cp util/alt_launch.txt util/alt_launch_linux.txt 2>/dev/null
sed -i -e "s|\\\|/|Ig" util/alt_launch_linux.txt 2>/dev/null
dos2unix util/alt_launch_linux.txt 2>/dev/null
dos2unix emulators/dosbox/alt_settings_linux.txt 2>/dev/null
#note - these files are also used by the macOS port

echo "Fixing dosbox.txt typos."
#sed -i -e 's/\\\\/\\/g' util/dosbox.txt  2>/dev/null
#sed -i -e 's/Atlantis - The lost Tales/Atlantis - The Lost Tales/' util/dosbox.txt  2>/dev/null
#sed -i -e 's/Bluntman and Chronic P\.C\. version/Bluntman and Chronic P.C. Version/' util/dosbox.txt  2>/dev/null
#sed -i -e 's/McGee at the Fun fair/McGee at the Fun Fair/' util/dosbox.txt  2>/dev/null
#sed -i -e 's/Pure-stat College Basketball/Pure-Stat College Basketball/' util/dosbox.txt  2>/dev/null

echo "Converting dosbox.txt."

rm -f util/dosbox*_linux.txt 2>/dev/null
rm util/demoscn_linux.txt 2>/dev/null
for file in util/dosbox*.txt util/demoscn.txt
do
    [ -e "$file" ] && cp "$file" "${file%.txt}_linux.txt"
done

for file in util/dosbox*_linux.txt util/demoscn_linux.txt
do
    [ -e "$file" ] && sed -i -e 's/:074r3\\dosbox\.exe/:flatpak run com.retro_exo.dosbox-074r3-1/I' "$file" 2>/dev/null
    [ -e "$file" ] && sed -i -e 's/:dosbox\.exe/:flatpak run com.retro_exo.dosbox-074r3-1/I' "$file" 2>/dev/null
    [ -e "$file" ] && sed -i -e 's|:dosbox0.73\\dosbox\.exe|:flatpak run com.retro_exo.dosbox-074r3-1|I' "$file" 2>/dev/null
    [ -e "$file" ] && sed -i -e 's/:ece4230\\dosbox\.exe/:flatpak run com.retro_exo.dosbox-ece-r4301/I' "$file" 2>/dev/null
    [ -e "$file" ] && sed -i -e 's/:ece_svn\\dosbox\.exe/:flatpak run com.retro_exo.dosbox-ece-r4482/I' "$file" 2>/dev/null
    [ -e "$file" ] && sed -i -e 's/:ece4460\\dosbox\.exe/:flatpak run com.retro_exo.dosbox-ece-r4482/I' "$file" 2>/dev/null
    [ -e "$file" ] && sed -i -e 's/:ece4481\\dosbox\.exe/:flatpak run com.retro_exo.dosbox-ece-r4482/I' "$file" 2>/dev/null
    [ -e "$file" ] && sed -i -e 's/:staging0\.80\.2\\dosbox\.exe/:flatpak run com.retro_exo.dosbox-staging-081-2/I' "$file" 2>/dev/null
    [ -e "$file" ] && sed -i -e 's/:staging0\.80\.1\\dosbox\.exe/:flatpak run com.retro_exo.dosbox-staging-081-2/I' "$file" 2>/dev/null
    [ -e "$file" ] && sed -i -e 's/:staging0\.81\.0a\\dosbox\.exe/:flatpak run com.retro_exo.dosbox-staging-081-2/I' "$file" 2>/dev/null
    [ -e "$file" ] && sed -i -e 's/:staging0\.81\.1\\dosbox\.exe/:flatpak run com.retro_exo.dosbox-staging-081-2/I' "$file" 2>/dev/null
    [ -e "$file" ] && sed -i -e 's/:staging0\.82\.0\\dosbox\.exe/:flatpak run com.retro_exo.dosbox-staging-082-0/I' "$file" 2>/dev/null
    [ -e "$file" ] && sed -i -e 's/:x\\dosbox\.exe/:flatpak run com.retro_exo.dosbox-x-08220/I' "$file" 2>/dev/null
    [ -e "$file" ] && sed -i -e 's/:x2\\dosbox\.exe/:flatpak run com.retro_exo.dosbox-x-20240701/I' "$file" 2>/dev/null
    [ -e "$file" ] && sed -i -e 's/:X_2024\\dosbox-x.exe/:flatpak run com.retro_exo.dosbox-x-20241001/I' "$file" 2>/dev/null
    [ -e "$file" ] && sed -i -e 's/:X_Nov\\dosbox-x.exe/:flatpak run com.retro_exo.dosbox-x-20241001/I' "$file" 2>/dev/null
    [ -e "$file" ] && sed -i -e 's/:mingw\\dosbox-x.exe/:flatpak run com.retro_exo.dosbox-x-20241001/I' "$file" 2>/dev/null
    [ -e "$file" ] && sed -i -e 's|:dosbox0.63\\dosbox\.exe|:flatpak run com.retro_exo.wine emulators/dosbox/dosbox0.63/dosbox.exe|I' "$file" 2>/dev/null
    [ -e "$file" ] && sed -i -e 's|:DWDdosbox\\dosbox\.exe|:flatpak run com.retro_exo.dosbox-gridc-4-3-1|I' "$file" 2>/dev/null
    [ -e "$file" ] && sed -i -e 's|:GunStick_dosbox\\dosbox\.exe|:flatpak run com.retro_exo.wine emulators/dosbox/GunStick_dosbox/dosbox.exe|I' "$file" 2>/dev/null
    [ -e "$file" ] && sed -i -e 's|:daum\\dosbox\.exe|:flatpak run com.retro_exo.wine emulators/dosbox/daum/dosbox.exe|I' "$file" 2>/dev/null
    [ -e "$file" ] && sed -i -e 's|:mpubuild_dosbox\\dosbox\.exe|:flatpak run com.retro_exo.wine emulators/dosbox/mpubuild_dosbox/dosbox.exe|I' "$file" 2>/dev/null
    [ -e "$file" ] && sed -i -e 's|:STdosbox\\dosbox\.exe|:flatpak run com.retro_exo.wine emulators/dosbox/STdosbox/dosbox.exe|I' "$file" 2>/dev/null
    [ -e "$file" ] && sed -i -e 's|:svnr4466\\dosbox\.exe|:flatpak run com.retro_exo.wine emulators/dosbox/svnr4466/dosbox.exe|I' "$file" 2>/dev/null #try building a flatpak for this
    [ -e "$file" ] && sed -i -e 's|:tc_dosbox\\dosbox\.exe|:flatpak run com.retro_exo.wine emulators/dosbox/tc_dosbox/dosbox.exe|I' "$file" 2>/dev/null
    [ -e "$file" ] && dos2unix "$file" 2>/dev/null
done
# Game specific fixes for dosbox_linux.txt
sed -i -e '/TNM 7 Second Edition/ s|flatpak run com\.retro_exo\.dosbox.*|flatpak run com.retro_exo.wine emulators/dosbox/DOSBox.exe|I' util/dosbox_linux.txt  2>/dev/null
sed -i -e '/Battle Arena Toshinden / s/ece-r4301/ece-r4358/' util/dosbox_linux.txt  2>/dev/null
sed -i -e '/Furcol / s/ece-r4301/ece-r4358/' util/dosbox_linux.txt  2>/dev/null
#skipping dosbox_mac-x64.txt and dosbox_mac-m1.txt until requirements are determined

echo 'flatpak run com.retro_exo.dosbox-staging-082-0' > util/alt_dosbox_linux.txt  2>/dev/null
#skipping alt_dosbox_mac-x64.txt and dosbox_mac-m1.txt until requirements are determined

cp util/scummvm.txt util/scummvm_linux.txt 2>/dev/null
sed -i -e 's/:scummvm\.exe/:flatpak run com.retro_exo.scummvm-2-8-0/I' util/scummvm_linux.txt  2>/dev/null
sed -i -e 's/:2\.5\\scummvm.exe/:flatpak run com.retro_exo.scummvm-2-5-0_PENDINGFLATPAK/I' util/scummvm_linux.txt  2>/dev/null
sed -i -e 's/:2\.7\.1\\scummvm.exe/:flatpak run com.retro_exo.scummvm-2-7-1_PENDINGFLATPAK/I' util/scummvm_linux.txt  2>/dev/null
sed -i -e 's/:svn2\.3_18903\\scummvm.exe/:flatpak run com.retro_exo.scummvm-2-3-0-git18903_PENDINGFLATPAK/I' util/scummvm_linux.txt  2>/dev/null
sed -i -e 's/:svn2\.7_5300\\scummvm.exe/:flatpak run com.retro_exo.scummvm-2-7-0-git5300_PENDINGFLATPAK/I' util/scummvm_linux.txt  2>/dev/null
sed -i -e 's/:svn2\.8_2998\\scummvm.exe/:flatpak run com.retro_exo.scummvm-2-8-0-git2998_PENDINGFLATPAK/I' util/scummvm_linux.txt  2>/dev/null
sed -i -e 's/:svn2\.8_9335\\scummvm.exe/:flatpak run com.retro_exo.scummvm-2-8-0-git9335_PENDINGFLATPAK/I' util/scummvm_linux.txt  2>/dev/null
dos2unix util/scummvm_linux.txt  2>/dev/null
#skipping scummvm_mac-x64.txt and scummvm_mac-m1.txt until requirements are determined

#remove Linux conf files for games running DOSBox through Wine
rm eXoDOS/\!dos/BRcdoom/*_GBC_linux.conf eXoDOS/\!dos/BRmatrix/*_GBC_linux.conf eXoDOS/\!dos/ckrynn/*_GBC_linux.conf eXoDOS/\!dos/CosmicSh/*_linux.conf eXoDOS/\!dos/curse/*_GBC_linux.conf eXoDOS/\!dos/desund/*_linux.conf eXoDOS/\!dos/dkkrynn/*_GBC_linux.conf eXoDOS/\!dos/drkqueen/*_GBC_linux.conf eXoDOS/\!dos/dune2/*_linux.conf eXoDOS/\!dos/gatesf/*_GBC_linux.conf eXoDOS/\!dos/MikeGunn/*_linux.conf eXoDOS/\!dos/PackRega/*_linux.conf eXoDOS/\!dos/pooldark/*_GBC_linux.conf eXoDOS/\!dos/poolrad/*_GBC_linux.conf eXoDOS/\!dos/secsilbl/*_GBC_linux.conf eXoDOS/\!dos/SkyNET/*_linux.conf eXoDOS/\!dos/TermFS/*_linux.conf eXoDOS/\!dos/TNM7SE/*_linux.conf eXoDOS/\!dos/TreasSav/*_GBC_linux.conf eXoDOS/\!dos/ultima5/*_GBC_linux.conf eXoDOS/\!dos/unlimadv/*_GBC_linux.conf eXoDOS/\!dos/WarCraft/*_linux.conf 2>/dev/null

#recopy Windows conf files to Linux naming convention for games running DOSBox through Wine
for file in eXoDOS/\!dos/BRcdoom/*_GBC.conf eXoDOS/\!dos/BRmatrix/*_GBC.conf eXoDOS/\!dos/ckrynn/*_GBC.conf eXoDOS/\!dos/CosmicSh/*.conf eXoDOS/\!dos/curse/*_GBC.conf eXoDOS/\!dos/desund/*.conf eXoDOS/\!dos/dkkrynn/*_GBC.conf eXoDOS/\!dos/drkqueen/*_GBC.conf eXoDOS/\!dos/dune2/*.conf eXoDOS/\!dos/gatesf/*_GBC.conf eXoDOS/\!dos/MikeGunn/*.conf eXoDOS/\!dos/PackRega/*.conf eXoDOS/\!dos/pooldark/*_GBC.conf eXoDOS/\!dos/poolrad/*_GBC.conf eXoDOS/\!dos/secsilbl/*_GBC.conf eXoDOS/\!dos/SkyNET/*.conf eXoDOS/\!dos/TermFS/*.conf eXoDOS/\!dos/TNM7SE/*.conf eXoDOS/\!dos/TreasSav/*_GBC.conf eXoDOS/\!dos/ultima5/*_GBC.conf eXoDOS/\!dos/unlimadv/*_GBC.conf eXoDOS/\!dos/WarCraft/*.conf
do
    [ -e "$file" ] && cp "$file" "${file%.conf}_linux.conf"
done 2>/dev/null

cp util/dreamm.txt util/dreamm_linux.txt  2>/dev/null
sed -i -e 's|:2\.1\.2\\dreamm\.exe|:2.1.2/dreamm-2.1.2-linux-x64/dreamm|I' util/dreamm_linux.txt  2>/dev/null
sed -i -e 's|:3\.01\\dreamm\.exe|:3.01/dreamm-3.01-linux-x64/dreamm|I' util/dreamm_linux.txt  2>/dev/null
dos2unix util/dreamm_linux.txt 2>/dev/null
#Note: If a macOS binary is not universal, there will need to be separate text files for m1 and x64.
#      In such cases, use the endings _mac-m1.txt and _mac-x64.txt. The binaries that are referenced
#      inside of such text files should follow the location patterns of macOS/x64/ and macOS/m1/.
cp util/dreamm.txt util/dreamm_mac.txt  2>/dev/null
sed -i -e 's|:2\.1\.2\\dreamm\.exe|:2.1.2/macOS/dreamm.app/Contents/MacOS/dreamm|I' util/dreamm_mac.txt  2>/dev/null
sed -i -e 's|:3\.01\\dreamm\.exe|:3.01/macOS/dreamm.app/Contents/MacOS/dreamm|I' util/dreamm_mac.txt  2>/dev/null
dos2unix util/dreamm_mac.txt  2>/dev/null

echo "Preparing macOS shell files..."
#skipping eXoDOS and eXoScummVM files for now. They will need some additional changes in the converting macOS shell files section.
for file in eXoDREAMM/\!*/*/*.bsh eXoDREAMM/\!*/*/*/*.bsh util/*.bsh util/*/*.bsh ../xml/*.bsh ../*.bsh
do
    [ -e "$file" ] && cp "$file" "${file%.bsh}.msh"
done

echo "Converting macOS shell files..."
for currentScript in eXoDREAMM/\!*/*/*.msh eXoDREAMM/\!*/*/*/*.msh util/*.msh util/*/*.msh ../xml/*.msh ../*.msh
do
    [ -e "$currentScript" ] && sed -i -e 's/"\$OSTYPE" == "darwin"/"\$OSTYPE" == "linux"/' "$currentScript"
    [ -e "$currentScript" ] && sed -i -e 's/BASH_SOURCE%\.bsh}\.msh/BASH_SOURCE%.msh}.PENDINGbs/' "$currentScript"
    [ -e "$currentScript" ] && sed -i -e 's/\(Setup eXo.[^\.]*\)\.bsh/\1.command/Ig' "$currentScript"
    [ -e "$currentScript" ] && sed -i -e 's/\(Setup_.[^\.]*\)\.bsh/\1.command/Ig' "$currentScript"
    [ -e "$currentScript" ] && sed -i -e '/find .*\.msh/! s/\.bsh/.msh/g' "$currentScript"
    [ -e "$currentScript" ] && sed -i -e 's/PENDINGbs/bsh/g' "$currentScript"
    [ -e "$currentScript" ] && sed -i -e '/flatpak run com\.retro_exo\.wine .*foobar2000\.exe/I s/flatpak run com\.retro_exo\.wine //' "$currentScript"
    [ -e "$currentScript" ] && sed -i -e '/^[^[:space:]]\+foobar2000.exe /I s|foobar2000\.exe|macOS/foobar2000.app/Contents/MacOS/foobar2000|' "$currentScript"
    #Note: The foobar2000 app appears to be a dual-platform binary supporting both m1 and x86_64
    #      If there are other binary references that are not dual-platform, they should be split
    #      into macOS/m1/ and macOS/x64/ directories. This will require adding a line to convert
    #      the Linux reference to macOS/m1/ above this note.
    [ -e "$currentScript" ] && sed -i -e "#macOS/m1/# s#^\(.*\)/m1/\(.*\)#&\n\1/x64/\2#" "$file"
    [ -e "$currentScript" ] && sed -i -e '#macOS/m1/# s/^\([[:space:]]*\)/\1[ `uname -m | grep arm64` ] \&\& /' "$currentScript"
    [ -e "$currentScript" ] && sed -i -e '#macOS/x64/# s/^\([[:space:]]*\)/\1[ `uname -m | grep x86_64` ] \&\& /' "$currentScript"
    [ -e "$currentScript" ] && sed -i -e '/(find \|^find \|^[[:space:]]\+find \| && find/ s/find/gfind/' "$currentScript"
    [ -e "$currentScript" ] && sed -i -e 's/^sed /gsed /' "$currentScript"
    [ -e "$currentScript" ] && sed -i -e 's/(sed /(gsed /g' "$currentScript"
    [ -e "$currentScript" ] && sed -i -e 's/ sed / gsed /g' "$currentScript"
    [ -e "$currentScript" ] && sed -i -e 's/demoscn_linux\.txt/demoscn_mac-m1.txt/' "$currentScript"
    [ -e "$currentScript" ] && sed -i -e 's/dosbox3x_linux\.txt/dosbox3x_mac-m1.txt/' "$currentScript"
    [ -e "$currentScript" ] && sed -i -e 's/dosbox_linux\.txt/dosbox_mac-m1.txt/' "$currentScript"
    [ -e "$currentScript" ] && sed -i -e 's/dreamm_linux\.txt/dreamm_mac.txt/' "$currentScript"
    [ -e "$currentScript" ] && sed -i -e 's/launch_linux\.txt/launch_mac-m1.txt/' "$currentScript"
    [ -e "$currentScript" ] && sed -i -e 's/scummvm_linux\.txt/scummvm_mac-m1.txt/' "$currentScript"
    [ -e "$currentScript" ] && sed -i -e "#mac-m1# s#^\(.*\)/mac-m1\(.*\)#&\n\1mac-x64/\2#" "$file"
    [ -e "$currentScript" ] && sed -i -e '/mac-m1\.txt/ s/^\([[:space:]]*\)/\1[ `uname -m | grep arm64` ] \&\& /' "$currentScript"
    [ -e "$currentScript" ] && sed -i -e '/mac-x64\.txt/ s/^\([[:space:]]*\)/\1[ `uname -m | grep x86_64` ] \&\& /' "$currentScript"
    [ -e "$currentScript" ] && sed -i -e '/^depcheck=flatpak/,/^fi/c\
missingDependencies=no\
! [[ `which brew` ]] && missingDependencies=yes\
! [[ `which aria2c` ]] && missingDependencies=yes\
! [[ `spctl --status | grep disabled` ]] && missingDependencies=yes' "$currentScript"
done

for file in ../Setup*.msh ../eXoMerge.msh
do
    [ -e "$file" ] && sed -i -e 's/\.msh}\.bsh/.command}.bsh/' "$file"
    [ -e "$file" ] && sed -i -e 's/\.bsh}\.msh/.bsh}.command/' "${file%.msh}.bsh"
    [ -e "$file" ] && sed -i -e 's#^echo "\[Desktop Entry\]" > ~/Desktop/\(.*\).desktop#osascript <<EOF\
tell application "Finder"\
   set myapp to POSIX file "${scriptDir}/exogui.app" as alias\
   make new alias to myapp at Desktop\
   set name of result to "\1.app"\
end tell\
EOF#' "$file"
    [ -e "$file" ] && sed -i -e '/source "\$scriptDir\/\$(basename -- "\${BASH_SOURCE%.command}.bsh")"/c\
    current_term="$(ps -o sid= -p "$$" | xargs ps -o ppid= -p | xargs ps -o comm= -p)"\
    case "$current_term" in\
        "cool-retro-term"|"konsole"|"gnome-terminal-"|"xfce4-terminal"|"ptyxis-agent"|"kgx"|"xterm"|"Eterm"|"x-terminal-emul"|"mate-terminal"|"terminator"|"urxvt"|"rxvt"|"termit"|"terminology"|"tilix"|"kitty"|"aterm"|"alacritty"|"qterminal"|"foot"|"mlterm"|"stterm")\
            cd eXo/util\
            source "$scriptDir/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")"\
            exit 0\
            break;;\
    esac\
    unset current_term\
    if [ `which cool-retro-term` ]\
    then\
        cool-retro-term -e /usr/bin/env bash "$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &\
        exit 0\
    elif [ `which konsole` ]\
    then\
        konsole -e /usr/bin/env bash "$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &\
        exit 0\
    elif [ `which gnome-terminal` ]\
    then\
        gnome-terminal -- /usr/bin/env bash "$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &\
        exit 0\
    elif [ `which xfce4-terminal` ]\
    then\
        xfce4-terminal -x /usr/bin/env bash "$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &\
        exit 0\
    elif [ `which ptyxis` ]\
    then\
        ptyxis --new-window -- /usr/bin/env bash "$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &\
        exit 0\
    elif [ `which kgx` ]\
    then\
        kgx -e "/usr/bin/env bash \\"$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")\\" $@" &\
        exit 0\
    elif [ `which xterm` ]\
    then\
        xterm -e /usr/bin/env bash "$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &\
        exit 0\
    elif [ `which uxterm` ]\
    then\
        uxterm -e /usr/bin/env bash "$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &\
        exit 0\
    elif [ `which eterm` ]\
    then\
        Eterm -e /usr/bin/env bash "$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &\
        exit 0\
    elif [ `which x-terminal-emulator` ]\
    then\
        x-terminal-emulator -e /usr/bin/env bash "$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &\
        exit 0\
    elif [ `which mate-terminal` ]\
    then\
        eval mate-terminal -e \\"/usr/bin/env bash \\\\\\"$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")\\\\\\" $@\\" "$@" &\
        exit 0\
    elif [ `which terminator` ]\
    then\
        terminator -x /usr/bin/env bash "$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &\
        exit 0\
    elif [ `which urxvt` ]\
    then\
        urxvt -e /usr/bin/env bash "$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &\
        exit 0\
    elif [ `which rxvt` ]\
    then\
        rxvt -e /usr/bin/env bash "$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &\
        exit 0\
    elif [ `which termit` ]\
    then\
        termit -e /usr/bin/env bash "$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &\
        exit 0\
    elif [ `which lxterm` ]\
    then\
        lxterm -e /usr/bin/env bash "$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &\
        exit 0\
    elif [ `which terminology` ]\
    then\
        terminology -e "/usr/bin/env bash \\"$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")\\" $@" &\
        exit 0\
    elif [ `which tilix` ]\
    then\
        tilix -e /usr/bin/env bash "$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &\
        exit 0\
    elif [ `which kitty` ]\
    then\
        kitty -e /usr/bin/env bash "$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &\
        exit 0\
    elif [ `which aterm` ]\
    then\
        aterm -e /usr/bin/env bash "$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &\
        exit 0\
    elif [ `which alacritty` ]\
    then\
        alacritty -e /usr/bin/env bash "$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &\
        exit 0\
    elif [ `which qterminal` ]\
    then\
        qterminal -e "/usr/bin/env bash \\"$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")\\" $@" &\
        exit 0\
    elif [ `which foot` ]\
    then\
        foot -- /usr/bin/env bash "$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &\
        exit 0\
    elif [ `which mlterm` ]\
    then\
        mlterm -e /usr/bin/env bash "$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &\
        exit 0\
    elif [ `which stterm` ]\
    then\
        stterm -e /usr/bin/env bash "$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &\
        exit 0\
    elif [[ "$-" == *i* ]]\
    then\
        source "$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")"\
        exit 0\
    elif [[ `flatpak list 2>/dev/null | grep "retro_exo\\.konsole"` ]]\
    then\
        flatpak run com.retro_exo.konsole -e /usr/bin/env bash "$PWD/eXo/util/$(basename -- "${BASH_SOURCE%.command}.bsh")" "$@" &\
        exit 0\
    else\
        logger -s "eXo: weird system achievement unlocked - None of the 25 supported terminal emulators are installed."\
        exit 1\
    fi\
' "$file"
    [ -e "$file" ] && sed -i -e '/ ~\/Desktop\//d' "$file"
    [ -e "$file" ] && mv "$file" "${file%.msh}.command"
    [ -e "${file%.msh}.bsh" ] && sed -i -e "s|^missingDependencies=no|cd ../../\nmissingDependencies=no|" "${file%.msh}.bsh"
    [ -e "${file%.msh}.bsh" ] && sed -i -e '/command/ s|\(source "$scriptDir/\)\($(basename\)|\1../../\2|' "${file%.msh}.bsh"
    [ -e "${file%.msh}.bsh" ] && mv "${file%.msh}.bsh" ./util/
done

chmod +x ../*.command 2>/dev/null

echo "Correcting xml inconsistencies..."
#for file in ../Data/Platforms/MS-DOS.xml ../xml/all/MS-DOS.xml ../xml/family/MS-DOS.xml
#do
#    [ -e "$file" ] && sed -i -e "s/\\\abanplac/\\\Abanplac/" "$file"
#    [ -e "$file" ] && sed -i -e "s/alqadim\\\Al-Qadim - the Genie/alqadim\\\Al-Qadim - The Genie/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\amado\\\/\\\Amado\\\/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\amado</\\\Amado</" "$file"
#    [ -e "$file" ] && sed -i -e "s/Atlantis - The lost Tales (1997)\.bat/Atlantis - The Lost Tales (1997).bat/" "$file"
#    [ -e "$file" ] && sed -i -e "s/blntchrn\\\Bluntman and Chronic P\.C\. version/blntchrn\\\Bluntman and Chronic P.C. Version/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\bship86/\\\BSHIP86/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\bship88/\\\BSHIP88/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\burger\\\/\\\BURGER\\\/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\burger</\\\BURGER</" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\calcman/\\\Calcman/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\Champ Centiped-em (1997)\.bat/\\\CHAMP Centiped-em (1997).bat/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\Champ Centipede (1993)\.bat/\\\CHAMP Centipede (1993).bat/" "$file"
#    [ -e "$file" ] && sed -i -e "s/A Clue's Solution (1993)\.bat/Clue's Solution, A (1993).bat/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\crimpun/\\\CrimPun/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\DAUGHTER\\\/\\\Daughter\\\/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\DAUGHTER</\\\Daughter</" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\decimate/\\\DECIMATE/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\DiscDeep/\\\DISCDEEP/" "$file"
#    [ -e "$file" ] && sed -i -e "s/eamondx/EAMONDX/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\earthris\\\/\\\Earthris\\\/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\earthris</\\\Earthris</" "$file"
#    [ -e "$file" ] && sed -i -e "s/fatetwin/Fatetwin/" "$file"
#    [ -e "$file" ] && sed -i -e "s/flipello/Flipello/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\foxtrot\\\/\\\Foxtrot\\\/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\foxtrot</\\\Foxtrot</" "$file"
#    [ -e "$file" ] && sed -i -e "s/hyper 3-D Pinball (1995)\.bat/Hyper 3-D Pinball (1995).bat/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\lotis\\\/\\\Lotis\\\/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\lotis</\\\Lotis</" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\Mahjong9/\\\MahJong9/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\oilcap/\\\OilCap/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\Once Upon a Time - Baba Yaga (1991)\.bat/\\\Once Upon A Time - Baba Yaga (1991).bat/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\panoplia\\\/\\\Panoplia\\\/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\panoplia</\\\Panoplia</" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\plix\\\/\\\Plix\\\/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\plix</\\\Plix</" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\Pure-stat College Basketball (1987)\.bat/\\\Pure-Stat College Basketball (1987).bat/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\quato\\\/\\\Quato\\\/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\quato</\\\Quato</" "$file"
#    [ -e "$file" ] && sed -i -e "s/rakumast/RakuMast/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\robix\\\/\\\Robix\\\/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\robix</\\\Robix</" "$file"
#    [ -e "$file" ] && sed -i -e "s/Taxirun/TaxiRun/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\Tpatien3/\\\TPatien3/" "$file"
#    [ -e "$file" ] && sed -i -e "s/Scramb90/scramb90/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\searun/\\\SeaRun/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\SeoGun\\\/\\\Seogun\\\/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\SeoGun</\\\Seogun</" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\SeoGun95/\\\Seogun95/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\squarex\\\/\\\Squarex\\\/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\squarex</\\\Squarex</" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\ultima1/\\\Ultima1/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\ultima2/\\\Ultima2/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\ultima3/\\\Ultima3/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\Weebee\\\/\\\WeeBee\\\/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\Weebee</\\\WeeBee</" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\wordle\\\/\\\Wordle\\\/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\wordle</\\\Wordle</" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\zak\\\/\\\Zak\\\/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\zak</\\\Zak</" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\Zblast/\\\ZBlast/" "$file"
    #Corrections for manuals
#    [ -e "$file" ] && sed -i -e "s/\\\Crime Patrol (1994)\.TXT/\\\Crime Patrol (1994).pdf/" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\Cyclemania (1994)\.TXT/\\\Cyclemania (1994).pdf/" "$file"
#    [ -e "$file" ] && sed -i -e "s|<ManualPath>Manuals\\\MS-DOS\\\Pro League Baseball (1992)\.pdf</ManualPath>|<ManualPath />|" "$file"
#    [ -e "$file" ] && sed -i -e "s/\\\Waterloo (1989)\.txt/\\\Waterloo (1989).pdf/" "$file"
#done

echo "Removing unnecessary files..."
[ -e Magazines/BBD/run.bsh ] && rm Magazines/BBD/run.bsh
[ -e Magazines/BBD/run.command ] && rm Magazines/BBD/run.command
[ -e Magazines/BBD/run.msh ] && rm Magazines/BBD/run.msh
[ -e Magazines/BBD/BBDS2/Go.bsh ] && rm Magazines/BBD/BBDS2/Go.bsh
[ -e Magazines/BBD/BBDS2/Go.command ] && rm Magazines/BBD/BBDS2/Go.command
[ -e Magazines/BBD/BBDS2/Go.msh ] && rm Magazines/BBD/BBDS2/Go.msh
[ `ls -1 Magazines/GameBytes/*.bsh 2>/dev/null | wc -w` -gt 0 ] && rm Magazines/GameBytes/*.bsh
[ `ls -1 Magazines/GameBytes/*.command 2>/dev/null | wc -w` -gt 0 ] && rm Magazines/GameBytes/*.command
[ `ls -1 Magazines/GameBytes/*.msh 2>/dev/null | wc -w` -gt 0 ] && rm Magazines/GameBytes/*.msh
[ `ls -1 Magazines/Interactive\ Entertainment\ CD/*.bsh 2>/dev/null | wc -w` -gt 0 ] && rm Magazines/Interactive\ Entertainment\ CD/*.bsh
[ `ls -1 Magazines/Interactive\ Entertainment\ CD/*.command 2>/dev/null | wc -w` -gt 0 ] && rm Magazines/Interactive\ Entertainment\ CD/*.command
[ `ls -1 Magazines/Interactive\ Entertainment\ CD/*.msh 2>/dev/null | wc -w` -gt 0 ] && rm Magazines/Interactive\ Entertainment\ CD/*.msh

echo "Conversion complete."
