#!/usr/bin/env bash

# Linux Compatibility Patch for eXoDOS 6 / eXoDemoScene / eXoDREAMM / eXoScummVM / eXoWin3x
# Revised: 2026-02-15
# This file is a dependency for regenerate.bash and cannot be executed directly.

: 'Legend for temporary references:
DELAYEDVARBEG - denotes the beginning of a delayed expansion variable
DELAYEDVAREND - denotes the end of a delayed expansion variable
DELAYEDVARECHBEG - denotes the beginning of a delayed expansion variable used in an echo statement
DELAYEDVARECHEND - denotes the end of a delayed expansion variable used in an echo statement
DETERMINEBYTESFREE - placeholder that is later substituted with Linux command to determine bytes free
PENDINGAST - pending asterisk (*)
PENDINGBACKTICK - pending `
PENDINGBASENOEXT - pending current script basename without extension
PENDINGCAT - pending cat to set variable
PENDINGDLR - pending $ character
pendingdq - pending double quote
PENDINGEXECHECK - placeholder that is later substituted with Linux command to determine if process is running
pendingIFS - placeholder for IFS
PENDINGPCT - pending % character
pendingSED - short term placeholder to handle sed commands that need to be broken up due to token limitation
PENDINGTONULL - pending &>/dev/null
PENDINGTLTRU - pending top level true condition
PENDINGTLFAL - pending top level false condition
PENDINGTLEOC - pending top level end of true/false condition
PENDINGNSTRU - pending nested true condition
PENDINGNSFAL - pending nested false condition
PENDINGNSEOC - pending nested end of true/false condition
PENDINGTLDBI - pending top level do before if (for when a for loop has a multi-line if as part of its declaration)
PENDINGL2IAD - pending level2 if after do (if statement declared as part of a for loop)
PENDINGthen - then statement corresponding to level 2 multi-line if statments and multi-line if statements lacking inner loops
PENDINGFI - fi statements (not including ones corresponding with PENDINGTLIBF or pendingL3FI)
pendingPrepL3FI - ed replaced )))
pendingL3FI - fi statement
pendingL3I - pending level 3 if
pendingL3then - pending level 3 then for if
PENDINGTLIBF - pending top level if before for (for when an if statement has a multi-line for loop as part of its declaration)
PENDINGtBF - pending then before for (the then statement that corresponds to PENDINGTLIBF)
PENDINGL2FAI - pending level 2 for after if (the for loop declared as part of an if statement)
PENDINGTRAILTLIBF - temporarily appended to the end of the PENDINGTLIBF line to fake other substitution commands into thinking it is a one-liner
PENDINGTLFI - fi statements corresponding with PENDINGTLIBF
pendingYYYYMMDD - pending quoted YYYYMMDD value
TEMPDONECHOICE - done statement at the end of a case statement
'

function convertScript
{    
    
    #change ..\.\ instances to ..\
    sed -i -e 's/\.\.\\\.\\/..\\/g' "$currentScript"
    
    #prepare loop variables
    sed -i -e '/\%\%[[:space:]\t]*$/!s/\(\%\%\)\([^[:space:]\%]\)/\%\L\2\E\%/g' "$currentScript"
    
    #rename parameter variables
    sed -i -e 's/\([\\= ]\)\%1/\1\%parameterone\%/g' "$currentScript"
    sed -i -e 's/\([\\= ]\)\%2/\1\%parametertwo\%/g' "$currentScript"
    sed -i -e 's/\([\\= ]\)\%3/\1\%parameterthree\%/g' "$currentScript"
    sed -i -e 's/\([\\= ]\)\%4/\1\%parameterfour\%/g' "$currentScript"
    sed -i -e 's/\%~1/\%parameterone\%/g' "$currentScript"
    sed -i -e 's/\%~2/\%parametertwo\%/g' "$currentScript"
    sed -i -e 's/\%~3/\%parameterthree\%/g' "$currentScript"
    sed -i -e 's/\%~4/\%parameterfour\%/g' "$currentScript"
    sed -i -e 's/ \[\%1\] / [\%parameterone\%] /g' "$currentScript"
    sed -i -e 's/ \[\%2\] / [\%parametertwo\%] /g' "$currentScript"
    sed -i -e 's/ \[\%3\] / [\%parameterthree\%] /g' "$currentScript"
    sed -i -e 's/ \[\%4\] / [\%parameterfour\%] /g' "$currentScript"
    
    #prepare variable for current script basename without extension
    sed -i -e 's/\%~n0/PENDINGBASENOEXT/g' "$currentScript"
    
    #prepare true / false tests
    sed -i -e "/^[^[:space:]]\+/ s/ && ([[:space:]\t\r]*$/\nPENDINGTLTRU/" "$currentScript"
    sed -i -e 's/^) || ([[:space:]\t]*$/PENDINGTLFAL/' "$currentScript"
    sed -i -e "/^PENDINGTLTRU/,/^)[[:space:]\t]*$/I s/^)[[:space:]\t]*$/PENDINGTLEOC/" "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)\(.*\) && ([[:space:]\t\r]*$/\1\2\n\1PENDINGNSTRU/" "$currentScript"
    sed -i -e 's/^\([[:space:]]\+\)) || ([[:space:]\t]*$/\1PENDINGNSFAL/' "$currentScript"
    sed -i -e "/^[[:space:]]\+PENDINGNSTRU/,/^[[:space:]]\+)[[:space:]\t]*$/I s/^\([[:space:]]\+\))[[:space:]\t]*$/\1PENDINGNSEOC/" "$currentScript"
    
    sed -i -e "/^>nul /I s/([[:space:]\t\r]*$//" "$currentScript"
    sed -i -e "s/^>nul \(.*\)/\1 PENDINGTONULL/I" "$currentScript"
    sed -i -e "s/ >nul[[:space:]\t\r]*$/ PENDINGTONULL/I" "$currentScript"
    sed -i -e "/^> nul /I s/([[:space:]\t\r]*$//" "$currentScript"
    sed -i -e "s/^> nul \(.*\)/\1 PENDINGTONULL/I" "$currentScript"
    sed -i -e "s/ > nul[[:space:]\t\r]*$/ PENDINGTONULL/I" "$currentScript"
    
    #at this time, robocopy is only used for merging (subsequent delete line not implemented for now)
    sed -i -e 's|robocopy \([^[:space:]]\+ [^[:space:]]\+ \)/MOVE.* PENDINGTONULL|copy \1PENDINGTONULL|I' "$currentScript"
    
    #ensure if statements are lowercase
    sed -i -e '/^[[:space:]]\+if/Is/^\([[:space:]]\+\)if/\1if/I' "$currentScript"
    sed -i -e 's/^if/if/I' "$currentScript"
    
    #prepare triple-nested multi-line if
    while grep "[^(]*)))" "$currentScript"
    do
        ed "$currentScript" <<EOF &>/dev/null
\$
?      [^(]*)))[[:space:]\t]*\$? s/)))/pendingPrepL3FI/
?[[:space:]]*if.*([[:space:]\t]*\$? s/if /pendingL3I /
wq
EOF
    done
    sed -i -e '/pendingL3I / s/([[:space:]\t\r]*$/pendingL3then/' "$currentScript"
    sed -i -e '/^         /s/pendingPrepL3FI[[:space:]\t]*$/\n      pendingL3FI\n   )\n)/' "$currentScript"
    sed -i -e '/^      /s/pendingPrepL3FI[[:space:]\t]*$/\n    pendingL3FI\n  )\n)/' "$currentScript"
    
    #move nested double ending parenthesis to separate lines
    sed -i -e '/(/!{ /^      /s/))[[:space:]\t]*$/\n   )\n)/ }' "$currentScript"
    sed -i -e '/(/!{ /^    /s/))[[:space:]\t]*$/\n  )\n)/ }' "$currentScript"
    
    #ensure if statements with multiple lines of execution commands do not have the first execution command on same line as the opening (
    sed -i -e '/)/! s/^\(if .*\)(\([[:alnum:]_].*\)/\1(\n    \2/I' "$currentScript"
    
    #remove surrounding quotes in variable declaration values
    sed -i -e 's/^\(set [[:alnum:]_]\+=\)"\(.*\)"[[:space:]\t\r]*$/\1\2/I' "$currentScript"
    
    #replace " in variable declaration values with pendingdq placeholder
    sed -i -e '/^set [[:alnum:]_]\+=/I s/\"/pendingdq/Ig' "$currentScript"
    
    #prepare set variable to line in file
    sed -i -e 's|set /p \([[:alnum:]_]\+\)=<|set \1=PENDINGCAT|I' "$currentScript"
    
    #fix prompts
    sed -i -e 's|set /p \([[:alnum:]_]\+\)=\(".*"\)[[:space:]\t\r]*$|read -p \2 \L\1\E|I' "$currentScript"
    
    #fix null value checks
    sed -i -e 's/if \[\(.*\)\]==\[\]/if \1==""/I' "$currentScript"
    sed -i -e 's/pendingL3I \[\(.*\)\]==\[\]/pendingL3I \1==""/I' "$currentScript"
    
    #convert ren commands to mv commands
    sed -i -e "/^ren\|^[[:space:]]\+ren/I s/ren \([^[:space:]\"]*\)\\\\\([^[:space:]\"]*\) \([^[:space:]\"]*\)/mv \1\\\\\2 \1\\\\\3/I" "$currentScript"
    sed -i -e "/^ren\|^[[:space:]]\+ren/I s/ren \"\([^\"]*\)\\\\\([^\"]*\)\" \"\([^\"]*\)\"/mv \"\1\\\\\2\" \"\1\\\\\3\"/I" "$currentScript"
    
    #prepare updatefile names
    sed -i -e "s|^for /F \"tokens=1,2,3,4 delims=/ \" %\([[:alnum:]_]\+\)% in (\"[%\!]\(.[^\"%\!]*\)[%\!]\") do set \(.[^=]*\)=%b%[[:space:]\t\r]*$|\L\3\E=PENDINGDLR{\L\2\E##*/}|I" "$currentScript"
    
    #prepare shader type declarations
    sed -i -e "s|^for /f \"tokens=1 delims=\\\\\" %\([[:alnum:]_]\+\)% in (\"[%\!]\(.[^\"%\!]*\)[%\!]\") do set \(.[^=]*\)=%\1%|\L\3\E=PENDINGDLR{\L\2\EPENDINGPCTPENDINGPCT/*}|I"  "$currentScript"
    
    #change LaunchBox.exe check variable and references to exogui
    sed -i -e 's/^SET EXE=LaunchBox\.exe/set exe=exogui/I' "$currentScript"
    sed -i -e 's/LaunchBox must be closed/exogui must be closed/I' "$currentScript"
    sed -i -e 's/closing LaunchBox/closing exogui/I' "$currentScript"
    
    #prepare $exe run check
    sed -i -e 's|^FOR /F %\([[:alnum:]_]\+\)% .*tasklist.*IMAGENAME eq %EXE%.*DO IF NOT %\1% == %EXE% |if PENDINGEXECHECK equ 0 |I' "$currentScript"
    
    #prepare localdatetime variable assignments
    sed -i -e 's|for /f "tokens=2 delims==" %\([[:alpha:]]\)% in (.wmic OS Get localdatetime /value.) do set "\([[:alnum:]_]\+\)=%\1%"|\2=pendingYYYYMMDD|I' "$currentScript"
    
    #fix findstr declarations
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /C:\"\(.[^\"]*\)\" \"\([^'\")]*\)\"') do (set \(.[^=]*\)=%\1%)[[:space:]\t\r]*$|\4=\`grep \"\2\" \"\3\"\`|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /i /C:\"\(.[^\"]*\)\" \"\([^'\")]*\)\"') do (set \(.[^=]*\)=%\1%)[[:space:]\t\r]*$|\4=\`grep -i \"\2\" \"\3\"\`|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /b /C:\"\(.[^\"]*\)\" \"\([^'\")]*\)\"') do (set \(.[^=]*\)=%\1%)[[:space:]\t\r]*$|\4=\`grep \"^\2\" \"\3\"\`|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /i /b /C:\"\(.[^\"]*\)\" \"\([^'\")]*\)\"') do (set \(.[^=]*\)=%\1%)[[:space:]\t\r]*$|\4=\`grep -i \"^\2\" \"\3\"\`|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /C:\"\(.[^\"]*\)\" \([^'\")]*\)') do (set \(.[^=]*\)=%\1%)[[:space:]\t\r]*$|\4=\`grep \"\2\" \"\3\"\`|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /i /C:\"\(.[^\"]*\)\" \([^'\")]*\)') do (set \(.[^=]*\)=%\1%)[[:space:]\t\r]*$|\4=\`grep -i \"\2\" \"\3\"\`|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /b /C:\"\(.[^\"]*\)\" \([^'\")]*\)') do (set \(.[^=]*\)=%\1%)[[:space:]\t\r]*$|\4=\`grep \"^\2\" \"\3\"\`|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /i /b /C:\"\(.[^\"]*\)\" \([^'\")]*\)') do (set \(.[^=]*\)=%\1%)[[:space:]\t\r]*$|\4=\`grep -i \"^\2\" \"\3\"\`|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /C:\"\(.[^\"]*\)\" \"\([^'\")]*\)\"') do (set \(.[^=]*\)=\(.[^)]*\))[[:space:]\t\r]*$|grep -q \"\2\" \"\3\" \&\& \4=\5|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /i /C:\"\(.[^\"]*\)\" \"\([^'\")]*\)\"') do (set \(.[^=]*\)=\(.[^)]*\))[[:space:]\t\r]*$|grep -iq \"\2\" \"\3\" \&\& \4=\5|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /b /C:\"\(.[^\"]*\)\" \"\([^'\")]*\)\"') do (set \(.[^=]*\)=\(.[^)]*\))[[:space:]\t\r]*$|grep -q \"^\2\" \"\3\" \&\& \4=\5|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /i /b /C:\"\(.[^\"]*\)\" \"\([^'\")]*\)\"') do (set \(.[^=]*\)=\(.[^)]*\))[[:space:]\t\r]*$|grep -iq \"^\2\" \"\3\" \&\& \4=\5|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /C:\"\(.[^\"]*\)\" \([^'\")]*\)') do (set \(.[^=]*\)=\(.[^)]*\))[[:space:]\t\r]*$|grep -q \"\2\" \"\3\" \&\& \4=\5|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /i /C:\"\(.[^\"]*\)\" \([^'\")]*\)') do (set \(.[^=]*\)=\(.[^)]*\))[[:space:]\t\r]*$|grep -iq \"\2\" \"\3\" \&\& \4=\5|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /b /C:\"\(.[^\"]*\)\" \([^'\")]*\)') do (set \(.[^=]*\)=\(.[^)]*\))[[:space:]\t\r]*$|grep -q \"^\2\" \"\3\" \&\& \4=\5|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /i /b /C:\"\(.[^\"]*\)\" \([^'\")]*\)') do (set \(.[^=]*\)=\(.[^)]*\))[[:space:]\t\r]*$|grep -iq \"^\2\" \"\3\" \&\& \4=\5|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /C:\"\(.[^\"]*\)\" \([^')]*\)') do set \(.[^=]*\)=%\1%[[:space:]\t\r]*$|\4=\`grep \"\2\" \3\`|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /i /C:\"\(.[^\"]*\)\" \([^')]*\)') do set \(.[^=]*\)=%\1%[[:space:]\t\r]*$|\4=\`grep -i \"\2\" \3\`|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /b /C:\"\(.[^\"]*\)\" \([^')]*\)') do set \(.[^=]*\)=%\1%[[:space:]\t\r]*$|\4=\`grep \"^\2\" \3\`|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /i /b /C:\"\(.[^\"]*\)\" \([^')]*\)') do set \(.[^=]*\)=%\1%[[:space:]\t\r]*$|\4=\`grep -i \"^\2\" \3\`|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /C:\"\(.[^\"]*\)\" \"\([^'\")]*\)\"') do ([[:space:]\t\r]*$|grep -q \"\2\" \"\3\"\ndo|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /i /C:\"\(.[^\"]*\)\" \"\([^'\")]*\)\"') do ([[:space:]\t\r]*$|grep -iq \"\2\" \"\3\"\ndo|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /b /C:\"\(.[^\"]*\)\" \"\([^'\")]*\)\"') do ([[:space:]\t\r]*$|grep -q \"^\2\" \"\3\"\ndo|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /i /b /C:\"\(.[^\"]*\)\" \"\([^'\")]*\)\"') do ([[:space:]\t\r]*$|grep -iq \"^\2\" \"\3\"\ndo|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /C:\"\(.[^\"]*\)\" \([^'\")]*\)') do ([[:space:]\t\r]*$|grep -q \"\2\" \"\3\"\ndo|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /i /C:\"\(.[^\"]*\)\" \([^'\")]*\)') do ([[:space:]\t\r]*$|grep -iq \"\2\" \"\3\"\ndo|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /b /C:\"\(.[^\"]*\)\" \([^'\")]*\)') do ([[:space:]\t\r]*$|grep -q \"^\2\" \"\3\"\ndo|I" "$currentScript"
    sed -i -e "s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in ('findstr /i /b /C:\"\(.[^\"]*\)\" \([^'\")]*\)') do ([[:space:]\t\r]*$|grep -iq \"^\2\" \"\3\"\ndo|I" "$currentScript"
    
    #fix standalone findstr commands
    sed -i -e "/^findstr \|^[[:space:]]\+findstr /I s#findstr /C:\"\(.[^\"]*\)\" \"\([^'\")]*\)\" PENDINGTONULL#grep -q \"\1\" \"\2\" PENDINGTONULL#I" "$currentScript"
    sed -i -e "/^findstr \|^[[:space:]]\+findstr /I s#findstr /i /C:\"\(.[^\"]*\)\" \"\([^'\")]*\)\" PENDINGTONULL#grep -iq \"\1\" \"\2\" PENDINGTONULL#I" "$currentScript"
    sed -i -e "/^findstr \|^[[:space:]]\+findstr /I s#findstr /b /C:\"\(.[^\"]*\)\" \"\([^'\")]*\)\" PENDINGTONULL#grep -q \"^\1\" \"\2\" PENDINGTONULL#I" "$currentScript"
    sed -i -e "/^findstr \|^[[:space:]]\+findstr /I s#findstr /i /b /C:\"\(.[^\"]*\)\" \"\([^'\")]*\)\" PENDINGTONULL#grep -iq \"^\1\" \"\2\" PENDINGTONULL#I" "$currentScript"
    sed -i -e "/^findstr \|^[[:space:]]\+findstr /I s#findstr /C:\"\(.[^\"]*\)\" \([^'\")]*\) PENDINGTONULL#grep -q \"\1\" \"\2\" PENDINGTONULL#I" "$currentScript"
    sed -i -e "/^findstr \|^[[:space:]]\+findstr /I s#findstr /i /C:\"\(.[^\"]*\)\" \([^'\")]*\) PENDINGTONULL#grep -iq \"\1\" \"\2\" PENDINGTONULL#I" "$currentScript"
    sed -i -e "/^findstr \|^[[:space:]]\+findstr /I s#findstr /b /C:\"\(.[^\"]*\)\" \([^'\")]*\) PENDINGTONULL#grep -q \"^\1\" \"\2\" PENDINGTONULL#I" "$currentScript"
    sed -i -e "/^findstr \|^[[:space:]]\+findstr /I s#findstr /i /b /C:\"\(.[^\"]*\)\" \([^'\")]*\) PENDINGTONULL#grep -iq \"^\1\" \"\2\" PENDINGTONULL#I" "$currentScript"
    sed -i -e "/^findstr \|^[[:space:]]\+findstr /I s#findstr /C:\"\(.[^\"]*\)\" \([^')]*\) PENDINGTONULL#grep \"\1\" \2 PENDINGTONULL#I" "$currentScript"
    sed -i -e "/^findstr \|^[[:space:]]\+findstr /I s#findstr /i /C:\"\(.[^\"]*\)\" \([^')]*\) PENDINGTONULL#grep -i \"\1\" \2 PENDINGTONULL#I" "$currentScript"
    sed -i -e "/^findstr \|^[[:space:]]\+findstr /I s#findstr /b /C:\"\(.[^\"]*\)\" \([^')]*\) PENDINGTONULL#grep \"^\1\" \2 PENDINGTONULL#I" "$currentScript"
    sed -i -e "/^findstr \|^[[:space:]]\+findstr /I s#findstr /i /b /C:\"\(.[^\"]*\)\" \([^')]*\) PENDINGTONULL#grep -i \"^\1\" \2 PENDINGTONULL#I" "$currentScript"
    
    #fix sourced text files
    sed -i -e "/\.txt/s|^for /F \"delims=\" %\([[:alnum:]_]\+\)% in (\(.*\)\.txt) do (set \"\%\1\%\")[[:space:]\t\r]*$|. \"\2.txt\"|I" "$currentScript"
    
    #set text file references to Linux
    #The update file references as well as zip files will be handled by regenerate.bash, as those changes are also be applied to the Windows batch files.
    #sed -i -e "/ver/I s/\.txt/_linux.txt/Ig" "$currentScript"
    sed -i -e "s/demoscn\.txt/demoscn_linux.txt/Ig" "$currentScript"
    sed -i -e "s/dosbox\.txt/dosbox_linux.txt/Ig" "$currentScript"
    sed -i -e "s/dosbox3x\.txt/dosbox3x_linux.txt/Ig" "$currentScript"
    sed -i -e "s/dreamm\.txt/dreamm_linux.txt/Ig" "$currentScript"
    sed -i -e "s/launch\.txt/launch_linux.txt/Ig" "$currentScript"
    sed -i -e "s/scummvm\.txt/scummvm_linux.txt/Ig" "$currentScript"
    sed -i -e "s/settings\.txt/settings_linux.txt/Ig" "$currentScript"
    sed -i -e "s/\(texts[[:alpha:]_-]*\)\.txt/\1_linux.txt/Ig" "$currentScript"
    #sed -i -e 's/MediaPack\.txt/MediaPack_linux.txt/Ig' "$currentScript"
    #sed -i -e '/DownloadFile/I s/\.exo/_linux.exo/Ig' "$currentScript"
    #sed -i -e 's/\.lang/_linux.lang/Ig' "$currentScript"
    
    #set dosbox bak files to Linux versions
    sed -i -e "/dosbox/I s/\.bak/_linux.bak/Ig" "$currentScript"
    
    #set zip files to Linux versions
    #sed -i -e "s/util\.zip/util_linux.zip/Ig" "$currentScript"

    #ensure echo commands are lowercase
    sed -i -e '/^if .* echo /Is/ echo / echo /Ig' "$currentScript"
    sed -i -e 's/^echo/echo/I' "$currentScript"
    sed -i -e '/^[[:space:]]\+echo/Is/^\([[:space:]]\+\)echo/\1echo/I' "$currentScript"
    
    #prepare echoed ` instances
    sed -i -e '/echo /s/`/PENDINGBACKTICK/g' "$currentScript"
    
    #remove DelayedExpansion global variables
    sed -i -e '/setlocal .*DelayedExpansion/Id' "$currentScript"
    sed -i -e '/SETLOCAL .*Extensions/Id' "$currentScript"
    sed -i -e '/setlocal$/Id' "$currentScript"
    
    #remove current drive variable assignment
    sed -i -e '/set current=%CD:.*/d' "$currentScript"
    
    #remove B2E call for shortcut creation
    sed -i -e '1{$!N};$!N;/^echo %cd%.*eXo\.b.*\n.*B2E .*eXo\.exe .*exodos.*\ndel exo.*/Id;P;D' "$currentScript"
    
    #prepare freespace variable assignment
    sed -i -e 's/for.*usebackq delims.*wmic logicaldisk where.*get FreeSpace.*set FreeSpace.*/freespace=DETERMINEBYTESFREE/' "$currentScript"
    
    #prepare DelayedExpansion references
    sed -i -e 's/\!\([[:alnum:]_]\+\)\!/\DELAYEDVARBEG\L\1\EDELAYEDVAREND/g' "$currentScript"

    #remove trailing \ characters excluding echo and comment lines
    sed -i -e '/^if .* echo /Is|\( echo .*\)\\|\1####|Ig' "$currentScript"
    sed -i -e '/^echo\|^#/I!s|\\ | |g' "$currentScript"
    sed -i -e 's/####/\\/' "$currentScript"
    
    #fix initial redirects
    sed -i -e 's/@echo off >/printf "" > /' "$currentScript"
    
    #remove @echo off lines
    sed -i -e '/^@echo off/d' "$currentScript"
    sed -i -e '/^echo off[[:space:]\t\r]*$/d' "$currentScript"
    
    #remove batch silencers
    sed -i -e 's/^@//' "$currentScript"
    
    #remove code page commands
    sed -i -e '/^chcp /d' "$currentScript"
    
    #fix recursive directory deletion commands
    sed -i -e 's/^rd/rm -rf/I' "$currentScript"
    sed -i -e 's/^rmdir/rm -rf/I' "$currentScript"
    sed -i -e 's/ rmdir / rm -rf /I' "$currentScript"
    sed -i -e '/^[[:space:]]\+rd/Is/^\([[:space:]]\+\)rd/\1rm -rf/I' "$currentScript"
    
    #remove extra spaces
    sed -i -e 's/rm -rf  /rm -rf /I' "$currentScript"
    
    #fix file deletion commands
    sed -i -e 's|del /Q |del |I' "$currentScript"
    sed -i -e 's/^del/rm/I' "$currentScript"
    sed -i -e '/^[[:space:]]\+del/Is/^\([[:space:]]\+\)del/\1rm/I' "$currentScript"
    sed -i -e 's/ del / rm /I' "$currentScript"
    sed -i -e 's/^erase/rm/I' "$currentScript"
    sed -i -e '/^[[:space:]]\+erase/Is/^\([[:space:]]\+\)erase/\1rm/I' "$currentScript"
    
    #fix comments
    sed -i -e 's/^rem/#/I' "$currentScript"
    sed -i -e 's/^[[:space:]]\+rem/#/I' "$currentScript"
    sed -i -e 's/^::/#/' "$currentScript"
    sed -i -e 's/^[[:space:]]\+::/#/' "$currentScript"
    
    #fix goto references
    sed -i -e 's/^:\(.*\)/: \L\1\E/' "$currentScript"
    sed -i -e 's/^[[:space:]]\+:\(.*\)/: \L\1\E/' "$currentScript"
    
    #fix goto commands
    sed -i -e 's/goto :/goto /I' "$currentScript"
    
    #fix cp commands
    sed -i -e 's/^copy/cp/I' "$currentScript"
    sed -i -e 's|^cp /Y |cp -f |I' "$currentScript"
    sed -i -e '/^[[:space:]]\+copy/Is/^\([[:space:]]\+\)copy/\1cp/I' "$currentScript"
    sed -i -e 's|^\([[:space:]]\+\)cp /Y |\1cp -f |I' "$currentScript"
    sed -i -e 's|xcopy \(.*\) /Y[[:space:]\t\r]*$|cp -f \1|I' "$currentScript"
    sed -i -e 's|xcopy /Y \(.*\)[[:space:]\t\r]*$|cp -f \1|I' "$currentScript"
    
    #fix quoted wildcard paths
    sed -i -e '/\*/ { /^cp /s/\"//g }' "$currentScript"
    
    #fix & commands
    sed -i -e '/echo/I! s/ & / \&\& /g' "$currentScript"
    
    #fix mv commands
    sed -i -e 's/^move/mv/I' "$currentScript"
    sed -i -e '/^[[:space:]]\+move/Is/^\([[:space:]]\+\)move/\1mv/I' "$currentScript"
    sed -i -e 's/&& move /\&\& mv /I' "$currentScript"
    
    #fix mkdir commands
    sed -i -e 's/^md /mkdir /I' "$currentScript"
    sed -i -e '/^[[:space:]]\+md /Is/^\([[:space:]]\+\)md /\1mkdir /I' "$currentScript"
    sed -i -e 's/^mkdir /mkdir /I' "$currentScript"
    sed -i -e 's/ mkdir / mkdir /I' "$currentScript"
    
    #fix clear screen commands
    sed -i -e 's/^cls/clear/I' "$currentScript"
    sed -i -e '/^[[:space:]]\+cls/Is/^\([[:space:]]\+\)cls/\1clear/I' "$currentScript"
    
    #fix call to bash
    sed -i -e 's/\(call :[[:alnum:]_]\+ \)/\L\1\E/' "$currentScript"
    sed -i -e '/call :/s/ \"\(%.*%\)\"/ \1/' "$currentScript"
    sed -i -e 's/call ://I' "$currentScript"
    sed -i -e 's/^call/source/I' "$currentScript"
    sed -i -e '/^[[:space:]]\+call/Is/^\([[:space:]]\+\)call/\1source/I' "$currentScript"
    
    #fix script references
    sed -i -e '/source set/!s/^source \(.*\)\.bat/source \1\.bsh/' "$currentScript"

    #fix empty line echo commands
    sed -i -e 's/^echo\./echo /I' "$currentScript"
    sed -i -e '/^[[:space:]]\+echo\./I s/\(^[[:space:]]\+\)echo\./\1echo /I' "$currentScript"
    sed -i -e '/^[[:space:]]\+if \|^if /I s/\( echo\)\./\L\1\E /I' "$currentScript"
    sed -i -e 's/ echo\.[[:space:]\t\r]*$/ echo /I' "$currentScript"
    
    #fix sleep commands
    sed -i -e 's/PING localhost -n \([[:digit:]]\+\)/sleep \1/I' "$currentScript"
    
    #fix problematic cd .. commands
    sed -i -e 's/^cd\.\.[[:space:]\t\r]*$/cd ../I' "$currentScript"
    sed -i -e 's/^\([[:space:]]\+\)cd\.\.[[:space:]\t\r]*$/\1cd ../I' "$currentScript"

    #remove path from choice commands
    sed -i -e 's/^\([\.\\eXo]\+util\\\)\(choice\)/\2/I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)\([\.\\eXo]\+util\\\)\(choice\)/\1\3/I' "$currentScript"
        
    #ensure choice commands do not have .exe appended
    sed -i -e 's/^choice\.exe/choice/I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)choice\.exe/\1choice/I' "$currentScript"
    
    #ensure aria2c commands do not have .exe appended
    sed -i -e '/cp \|mv \|rm /! s/aria2c\.exe/aria2c/I' "$currentScript"
    
    # remove ./ from aria2c commands
    sed -i -e 's|"%[[:alnum:]_]\+%[\.\\]\+eXo\\util\\aria\\aria2c" |aria2c |I' "$currentScript"
    sed -i -e 's|[\.\\]\+eXo\\util\\aria\\aria2c |aria2c |I' "$currentScript"
    sed -i -e 's|"%[[:alnum:]_]\+%[\.\\]\+util\\aria\\aria2c" |aria2c |I' "$currentScript"
    sed -i -e 's|[\.\\]\+util\\aria\\aria2c |aria2c |I' "$currentScript"
    sed -i -e 's|"%[[:alnum:]_]\+%[\.\\]\+aria\\aria2c" |aria2c |I' "$currentScript"
    sed -i -e 's|[\.\\]\+aria\\aria2c |aria2c |I' "$currentScript"
    sed -i -e 's|"%[[:alnum:]_]\+%[\.\\]\+aria2c" |aria2c |I' "$currentScript"
    sed -i -e 's|[\.\\]\+aria2c |aria2c |I' "$currentScript"

    # remove ./ from unzip commands
    sed -i -e 's|"%[[:alnum:]_]\+%[\.\\]\+eXo\\util\\unzip" -o|unzip -o|I' "$currentScript"
    sed -i -e 's|[\.\\]\+eXo\\util\\unzip -o|unzip -o|I' "$currentScript"
    sed -i -e 's|"%[[:alnum:]_]\+%[\.\\]\+util\\unzip" -o|unzip -o|I' "$currentScript"
    sed -i -e 's|[\.\\]\+util\\unzip -o|unzip -o|I' "$currentScript"
    sed -i -e 's|"%[[:alnum:]_]\+%[\.\\]\+unzip" -o|unzip -o|I' "$currentScript"
    sed -i -e 's|[\.\\]\+unzip -o|unzip -o|I' "$currentScript"
    sed -i -e 's|\.\.\\util\\unzip -o|unzip -o|I' "$currentScript"
    sed -i -e 's|\.\.\\unzip -o|unzip -o|I' "$currentScript"
    sed -i -e 's|"%[[:alnum:]_]\+%[\.\\]\+eXo\\util\\unzip" "|unzip -o "|I' "$currentScript"
    sed -i -e 's|[\.\\]\+eXo\\util\\unzip "|unzip -o "|I' "$currentScript"
    sed -i -e 's|"%[[:alnum:]_]\+%[\.\\]\+util\\unzip" "|unzip -o "|I' "$currentScript"
    sed -i -e 's|[\.\\]\+util\\unzip "|unzip -o "|I' "$currentScript"
    sed -i -e 's|"%[[:alnum:]_]\+%[\.\\]\+unzip" "|unzip -o "|I' "$currentScript"
    sed -i -e 's|[\.\\]\+unzip "|unzip -o "|I' "$currentScript"
    sed -i -e 's|\.\.\\util\\unzip "|unzip -o "|I' "$currentScript"
    sed -i -e 's|\.\.\\unzip "|unzip -o "|I' "$currentScript"
    sed -i -e 's|\.\\util\\unzip -o|unzip -o|I' "$currentScript"
    sed -i -e 's|\.\\unzip -o|unzip -o|I' "$currentScript"
    sed -i -e 's|\.\\util\\unzip "|unzip -o "|I' "$currentScript"
    sed -i -e 's|\.\\unzip "|unzip -o "|I' "$currentScript"
    sed -i -e 's|"%[[:alnum:]_]\+%[\.\\]\+eXo\\util\\unzip" -n|unzip -n|I' "$currentScript"
    sed -i -e 's|[\.\\]\+eXo\\util\\unzip -n|unzip -n|I' "$currentScript"
    sed -i -e 's|"%[[:alnum:]_]\+%[\.\\]\+util\\unzip" -n|unzip -n|I' "$currentScript"
    sed -i -e 's|[\.\\]\+util\\unzip -n|unzip -n|I' "$currentScript"
    sed -i -e 's|"%[[:alnum:]_]\+%[\.\\]\+unzip" -n|unzip -n|I' "$currentScript"
    sed -i -e 's|[\.\\]\+unzip -n|unzip -n|I' "$currentScript"
    sed -i -e 's|\.\.\\util\\unzip -n|unzip -n|I' "$currentScript"
    sed -i -e 's|\.\.\\unzip -n|unzip -n|I' "$currentScript"
    sed -i -e 's|\.\\util\\unzip -n|unzip -n|I' "$currentScript"
    sed -i -e 's|\.\\unzip -n|unzip -n|I' "$currentScript"
    
    # remove ./ from zip2 commands
    sed -i -e 's|"%[[:alnum:]_]\+%[\.\\]\+eXo\\util\\zip2" |zip |I' "$currentScript"
    sed -i -e 's|[\.\\]\+eXo\\util\\zip2 |zip |I' "$currentScript"
    sed -i -e 's|"%[[:alnum:]_]\+%[\.\\]\+util\\zip2" |zip |I' "$currentScript"
    sed -i -e 's|[\.\\]\+util\\zip2 |zip |I' "$currentScript"
    sed -i -e 's|"%[[:alnum:]_]\+%[\.\\]\+zip2" |zip |I' "$currentScript"
    sed -i -e 's|[\.\\]\+zip2 |zip |I' "$currentScript"
    sed -i -e 's|\.\\util\\zip2 |zip |I' "$currentScript"
    sed -i -e 's|\.\\zip2 |zip |I' "$currentScript"
    sed -i -e 's|\.\.\\util\\zip2 |zip |I' "$currentScript"
    sed -i -e 's|\.\.\\zip2 |zip |I' "$currentScript"
               
    #change \ to / excluding echo and comment lines
    sed -i -e '/^if .* echo /Is|\( echo .*\)\\|\1####|Ig' "$currentScript"
    sed -i -e '/^echo\|^#\|^[[:space:]]\+echo/I!s|\\|/|Ig' "$currentScript"
    sed -i -e 's/####/\\/' "$currentScript"
    
    #fix ^! instances
    sed -i -e 's/\^\!/\!/g' "$currentScript"
    
    #fix ^< instances
    sed -i -e '/echo /s/\^</</g' "$currentScript"
    
    #prepare ^> instances for fix
    sed -i -e '/echo /s/\^>/RIGHTANGLEBRACKET/g' "$currentScript"
    
    #fix ^( instances
    sed -i -e '/echo /s/\^(/(/g' "$currentScript"
    
    #fix ^) instances
    sed -i -e '/echo /s/\^)/)/g' "$currentScript"
    
    #fix ^| instances
    sed -i -e '/echo /s/\^|/|/g' "$currentScript"
    
    #fix ^\ instances
    sed -i -e '/echo /s/\^\\/\\/g' "$currentScript"
    
    #fix ^& instances
    sed -i -e '/echo /s/\^&/\&/g' "$currentScript"

    #escape ! excluding echo and comment lines
    sed -i -e '/^if .* echo /Is|\( echo .*\)\!|\1####|Ig' "$currentScript"
    sed -i -e '/^echo\|^#\|^[[:space:]]\+echo/I!s/\!/\\\!/Ig' "$currentScript"
    sed -i -e 's/####/\!/' "$currentScript"

    #remove /s /q
    sed -i -e '/^echo\|^#\|^[[:space:]]\+echo/I!s|/s /q||Ig' "$currentScript"
    
    #remove /q /s
    sed -i -e '/^echo\|^#\|^[[:space:]]\+echo/I!s|/q /s||Ig' "$currentScript"

    #change unzip.exe to unzip
    sed -i -e '/^echo\|^cp \|^#\| erase \|^[[:space:]]\+echo\|^[[:space:]]\+cp /I!s|unzip\.exe |unzip |Ig' "$currentScript"

    #change ./eXo/util/unzip to unzip
    sed -i -e '/^echo\|^#\|^[[:space:]]\+echo/I!s|[\./]*eXo/util/unzip |unzip |Ig' "$currentScript"
    
    #change util/unzip to unzip
    sed -i -e '/^echo\|^cp \|^#\|^[[:space:]]\+echo\|^[[:space:]]\+cp /I!s|[\./]*util/unzip |unzip |Ig' "$currentScript"
    
#    #change unzip -o to unzip
#    sed -i -e '/^echo\|^#\|^[[:space:]]\+echo/I!s/unzip -o/unzip/Ig' "$currentScript"
    
    #remove -q from unzip commands
    sed -i -e '/^echo\|^#\|^[[:space:]]\+echo/I!{ /unzip/ s/ -q// }' "$currentScript"
    
    #escape backslashes in all echoes, change \ to / after the redirects
    sed -i -e '/^echo.*\\\|^[[:space:]]\+echo.*\\/I{
                   s|#|##|g;
                   s|\\|/#|g;
                   :a;
                   s|^\(echo.*>.*\)/#\(.*\)|\1/\2|;
                   ta;
                   s|/#|\\\\|g;
                   s|##|#|g;
               }' "$currentScript"
               
    sed -i -e '/^if .* echo \|^[[:space:]]\+if .* echo /I{
                   s|\( echo .*\)#|\1##|Ig;
                   s|\( echo .*\)\\|\1/#|Ig;
                   s|\( echo .*\)/#|\1\\\\|Ig;
                   s|\( echo .*\)##|\1#|Ig;
               }' "$currentScript"
    
    #take set out of echo commands with redirects
    sed -i -e "/echo set .*>/I s/echo set /echo /I" "$currentScript"
    
    #escape quotes on echoes without redirects
    sed -i -e "/^echo\|^[[:space:]]\+echo/I{ />/! s/\"/\\\\\"/g }" "$currentScript"
    sed -i -e "/^if .* echo \|^[[:space:]]\+if .* echo /I{ />/! s/\( echo .*\)\"/\1\\\\\"/g }" "$currentScript"
    
    #escape quotes on echos with redirects
    sed -i -e "/^echo\|^[[:space:]]\+echo/I { :a s/\(echo .*[^\\]\)\"\(.* > \)/\1\\\\\"\2/Ig; ta; }" "$currentScript"
    sed -i -e "/^if .* echo \|^[[:space:]]\+if .* echo /I { :a; s/\( echo .*[^\\]\)\"\(.* > \)/\1\\\\\"\2/Ig; ta; }" "$currentScript"
    sed -i -e "/^echo\|^[[:space:]]\+echo/I { :a; s/\(echo .*[^\\]\)\"\(.* >> \)/\1\\\\\"\2/Ig; ta; }" "$currentScript"
    sed -i -e "/^if .* echo \|^[[:space:]]\+if .* echo /I { :a; s/\( echo .*[^\\]\)\"\(.* >> \)/\1\\\\\"\2/Ig; ta; }" "$currentScript"
    
    #add a double quote to the beginning of echoes
    sed -i -e "s/^echo /echo \"/" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)echo /\1echo \"/" "$currentScript"
    sed -i -e "/^if .* echo \|^[[:space:]]\+if .* echo /Is/ echo / echo \"/" "$currentScript"

    #add a double quote to the end of echoes without redirects
    sed -i -e "/^echo/I{ />\|echo \"set .*>/!s/[[:space:]\t\r]*$/\"/ }" "$currentScript"
    sed -i -e "/^\(^[[:space:]]\+\)echo/I{ />\|echo \"set .*>/!s/[[:space:]\t\r]*$/\"/ }" "$currentScript"
    sed -i -e "/^if .* echo \|^[[:space:]]\+if .* echo /I{ />/!s/[[:space:]\t\r]*$/\"/ }" "$currentScript"

    #ensure echo redirects are preceded by spaces
    sed -i -e "/^echo\|^[[:space:]]\+echo/I {/[^[:space:]]>>/ s/>>/ >>/;}" "$currentScript"
    sed -i -e "/^echo.*[^[:space:]]>\|^[[:space:]]\+echo.*[^[:space:]]>/I{ />>/! s/>/ >/;}" "$currentScript" 
    
    #add a double quote to the end of echoes with redirects
    sed -i -e "/^echo\|^[[:space:]]\+echo/I s/ >>/\" >> /" "$currentScript"
    sed -i -e "/^echo.*>\|^[[:space:]]\+echo.*>/I{ />>/! s/ >/\" > /;}" "$currentScript"
    
    #prepare multi-line if statements declared as part of a for loop
    sed -i -e '/^for/I s|) do if \([^(]*\)([[:space:]\t]*$|\nPENDINGTLDBI\nPENDINGL2IAD \1(|I' "$currentScript"
    
    #prepare multi-line for loop declared as part of an if statement
    sed -i -e '/ echo /I! { /^if.* for .*([[:space:]\t]*$/I {
                       s|^if|PENDINGTLIBF|I;
                       s| for \(.*\)|\nPENDINGtBF\nPENDINGL2FAI \1|I;
               } }' "$currentScript"
    
    #prepare ending parenthesis for if statement declared with multi-line for loop
    sed -i -e "/^PENDINGL2FAI .*([[:space:]\t]*$/,/^)[[:space:]\t]*$/I s/^)[[:space:]\t]*$/)\nPENDINGTLFI/" "$currentScript"
    sed -i -e "s/PENDINGL2FAI/for/" "$currentScript"
    
    #escape all $ characters
    sed -i -e "s/\\$/\\\\$/g" "$currentScript"

    #make all occurrences of goto lowercase except on echo and comment lines
    sed -i -e '/^echo\|^#\|^[[:space:]]\+echo/!s/goto \(.[^[:space:]]*\)/goto \L\1\E/gI' "$currentScript"
    
    #change all occurrences of GOTO to goto only after echo redirections
    sed -i -e '/^echo.*>.*GOTO\|^[[:space:]]\+echo.*>.*GOTO/ {
                   s/#/##/g;
                   s/GOTO/goto#/g;
                   :a;
                   s/^\(echo.*>.*\)goto#\(.*\)/\1goto\L\2\E/;
                   ta;
                   s/goto#/GOTO/g;
                   s/##/#/g;
               }' "$currentScript"
    
    #add spaces to &set instances and change & to &&
    sed -i -e 's/\([^ ]\)&set/\1 \&\& set/Ig' "$currentScript"
    
    #convert 1-9 token assignments pulled from variables with : or ; delimiters
    sed -i -e "s|^for /f \"tokens=1,2,3,4,5,6,7,8,9 delims=\([:;]\)\" %\([[:alnum:]_]\+\)% in (\"[%\!]\(.[^\"%\!]*\)[%\!]\") do set \(.[^=]*\)=%a% && set \(.[^=]*\)=%b% && set \(.[^=]*\)=%c% && set \(.[^=]*\)=%d% && set \(.[^=]*\)=%e% && \(set .[^=]*=%f% && set .[^=]*=%g% && set .[^=]*=%h% && set .[^=]*=%i%\)[[:space:]\t\r]*$|pendingIFS='\1' read -r \L\4 \5 \6 \7 \8\E pendingSED \9 <<< PENDINGDLR{\L\3\E}|I" "$currentScript"
    sed -i -e "s|pendingSED set \(.[^=]*\)=%f% && set \(.[^=]*\)=%g% && set \(.[^=]*\)=%h% && set \(.[^=]*\)=%i%|\L\1 \2 \3 \4\E|I" "$currentScript"
    sed -i -e "s|^for /f \"tokens=1,2,3,4,5,6,7,8 delims=\([:;]\)\" %\([[:alnum:]_]\+\)% in (\"[%\!]\(.[^\"%\!]*\)[%\!]\") do set \(.[^=]*\)=%a% && set \(.[^=]*\)=%b% && set \(.[^=]*\)=%c% && set \(.[^=]*\)=%d% && set \(.[^=]*\)=%e% && \(set .[^=]*=%f% && set .[^=]*=%g% && set .[^=]*=%h%\)[[:space:]\t\r]*$|pendingIFS='\1' read -r \L\4 \5 \6 \7 \8\E pendingSED \9 <<< PENDINGDLR{\L\3\E}|I" "$currentScript"
    sed -i -e "s|pendingSED set \(.[^=]*\)=%f% && set \(.[^=]*\)=%g% && set \(.[^=]*\)=%h%|\L\1 \2 \3\E|I" "$currentScript"
    sed -i -e "s|^for /f \"tokens=1,2,3,4,5,6,7 delims=\([:;]\)\" %\([[:alnum:]_]\+\)% in (\"[%\!]\(.[^\"%\!]*\)[%\!]\") do set \(.[^=]*\)=%a% && set \(.[^=]*\)=%b% && set \(.[^=]*\)=%c% && set \(.[^=]*\)=%d% && set \(.[^=]*\)=%e% && \(set .[^=]*=%f% && set .[^=]*=%g%\)[[:space:]\t\r]*$|pendingIFS='\1' read -r \L\4 \5 \6 \7 \8\E pendingSED \9 <<< PENDINGDLR{\L\3\E}|I" "$currentScript"
    sed -i -e "s|pendingSED set \(.[^=]*\)=%f% && set \(.[^=]*\)=%g%|\L\1 \2\E|I" "$currentScript"
    sed -i -e "s|^for /f \"tokens=1,2,3,4,5,6 delims=\([:;]\)\" %\([[:alnum:]_]\+\)% in (\"[%\!]\(.[^\"%\!]*\)[%\!]\") do set \(.[^=]*\)=%a% && set \(.[^=]*\)=%b% && set \(.[^=]*\)=%c% && set \(.[^=]*\)=%d% && set \(.[^=]*\)=%e% && set \(.[^=]*\)=%f%[[:space:]\t\r]*$|pendingIFS='\1' read -r \L\4 \5 \6 \7 \8 \9\E <<< PENDINGDLR{\L\3\E}|I" "$currentScript"
    sed -i -e "s|^for /f \"tokens=1,2,3,4,5 delims=\([:;]\)\" %\([[:alnum:]_]\+\)% in (\"[%\!]\(.[^\"%\!]*\)[%\!]\") do set \(.[^=]*\)=%a% && set \(.[^=]*\)=%b% && set \(.[^=]*\)=%c% && set \(.[^=]*\)=%d% && set \(.[^=]*\)=%e%[[:space:]\t\r]*$|pendingIFS='\1' read -r \L\4 \5 \6 \7 \8\E <<< PENDINGDLR{\L\3\E}|I" "$currentScript"
    sed -i -e "s|^for /f \"tokens=1,2,3,4 delims=\([:;]\)\" %\([[:alnum:]_]\+\)% in (\"[%\!]\(.[^\"%\!]*\)[%\!]\") do set \(.[^=]*\)=%a% && set \(.[^=]*\)=%b% && set \(.[^=]*\)=%c% && set \(.[^=]*\)=%d%[[:space:]\t\r]*$|pendingIFS='\1' read -r \L\4 \5 \6 \7\E <<< PENDINGDLR{\L\3\E}|I" "$currentScript"
    sed -i -e "s|^for /f \"tokens=1,2,3 delims=\([:;]\)\" %\([[:alnum:]_]\+\)% in (\"[%\!]\(.[^\"%\!]*\)[%\!]\") do set \(.[^=]*\)=%a% && set \(.[^=]*\)=%b% && set \(.[^=]*\)=%c%[[:space:]\t\r]*$|pendingIFS='\1' read -r \L\4 \5 \6\E <<< PENDINGDLR{\L\3\E}|I" "$currentScript"
    sed -i -e "s|^for /f \"tokens=1,2 delims=\([:;]\)\" %\([[:alnum:]_]\+\)% in (\"[%\!]\(.[^\"%\!]*\)[%\!]\") do set \(.[^=]*\)=%a% && set \(.[^=]*\)=%b%[[:space:]\t\r]*$|pendingIFS='\1' read -r \L\4 \5\E <<< PENDINGDLR{\L\3\E}|I" "$currentScript"
    sed -i -e "s|^for /f \"tokens=1 delims=\([:;]\)\" %\([[:alnum:]_]\+\)% in (\"[%\!]\(.[^\"%\!]*\)[%\!]\") do set \(.[^=]*\)=%a%[[:space:]\t\r]*$|pendingIFS='\1' read -r \L\4\E <<< PENDINGDLR{\L\3\E}|I" "$currentScript"
    
    #convert 1-9 token assignments pulled from files with : or ; delimiters
    sed -i -e "s|^for /f \"tokens=1,2,3,4,5,6,7,8,9 delims=\([:;]\)\" %\([[:alnum:]_]\+\)% in (\(.[^\"%\!]*\)) do set \(.[^=]*\)=%a% && set \(.[^=]*\)=%b% && set \(.[^=]*\)=%c% && set \(.[^=]*\)=%d% && set \(.[^=]*\)=%e% && \(set .[^=]*=%f% && set .[^=]*=%g% && set .[^=]*=%h% && set .[^=]*=%i%\)[[:space:]\t\r]*$|pendingIFS='\1' read -r \L\4 \5 \6 \7 \8\E pendingSED \9 < <(tr -d '\\\r' < \3)|I" "$currentScript"
    sed -i -e "s|pendingSED set \(.[^=]*\)=%f% && set \(.[^=]*\)=%g% && set \(.[^=]*\)=%h% && set \(.[^=]*\)=%i%|\L\1 \2 \3 \4\E|I" "$currentScript"
    sed -i -e "s|^for /f \"tokens=1,2,3,4,5,6,7,8 delims=\([:;]\)\" %\([[:alnum:]_]\+\)% in (\(.[^\"%\!]*\)) do set \(.[^=]*\)=%a% && set \(.[^=]*\)=%b% && set \(.[^=]*\)=%c% && set \(.[^=]*\)=%d% && set \(.[^=]*\)=%e% && \(set .[^=]*=%f% && set .[^=]*=%g% && set .[^=]*=%h%\)[[:space:]\t\r]*$|pendingIFS='\1' read -r \L\4 \5 \6 \7 \8\E pendingSED \9 < <(tr -d '\\\r' < \3)|I" "$currentScript"
    sed -i -e "s|pendingSED set \(.[^=]*\)=%f% && set \(.[^=]*\)=%g% && set \(.[^=]*\)=%h%|\L\1 \2 \3\E|I" "$currentScript"
    sed -i -e "s|^for /f \"tokens=1,2,3,4,5,6,7 delims=\([:;]\)\" %\([[:alnum:]_]\+\)% in (\(.[^\"%\!]*\)) do set \(.[^=]*\)=%a% && set \(.[^=]*\)=%b% && set \(.[^=]*\)=%c% && set \(.[^=]*\)=%d% && set \(.[^=]*\)=%e% && \(set .[^=]*=%f% && set .[^=]*=%g%\)[[:space:]\t\r]*$|pendingIFS='\1' read -r \L\4 \5 \6 \7 \8\E pendingSED \9 < <(tr -d '\\\r' < \3)|I" "$currentScript"
    sed -i -e "s|pendingSED set \(.[^=]*\)=%f% && set \(.[^=]*\)=%g%|\L\1 \2\E|I" "$currentScript"
    sed -i -e "s|^for /f \"tokens=1,2,3,4,5,6 delims=\([:;]\)\" %\([[:alnum:]_]\+\)% in (\(.[^\"%\!]*\)) do set \(.[^=]*\)=%a% && set \(.[^=]*\)=%b% && set \(.[^=]*\)=%c% && set \(.[^=]*\)=%d% && set \(.[^=]*\)=%e% && set \(.[^=]*\)=%f%[[:space:]\t\r]*$|pendingIFS='\1' read -r \L\4 \5 \6 \7 \8 \9\E < <(tr -d '\\\r' < \3)|I" "$currentScript"
    sed -i -e "s|^for /f \"tokens=1,2,3,4,5 delims=\([:;]\)\" %\([[:alnum:]_]\+\)% in (\(.[^\"%\!]*\)) do set \(.[^=]*\)=%a% && set \(.[^=]*\)=%b% && set \(.[^=]*\)=%c% && set \(.[^=]*\)=%d% && set \(.[^=]*\)=%e%[[:space:]\t\r]*$|pendingIFS='\1' read -r \L\4 \5 \6 \7 \8\E < <(tr -d '\\\r' < \3)|I" "$currentScript"
    sed -i -e "s|^for /f \"tokens=1,2,3,4 delims=\([:;]\)\" %\([[:alnum:]_]\+\)% in (\(.[^\"%\!]*\)) do set \(.[^=]*\)=%a% && set \(.[^=]*\)=%b% && set \(.[^=]*\)=%c% && set \(.[^=]*\)=%d%[[:space:]\t\r]*$|pendingIFS='\1' read -r \L\4 \5 \6 \7\E < <(tr -d '\\\r' < \3)|I" "$currentScript"
    sed -i -e "s|^for /f \"tokens=1,2,3 delims=\([:;]\)\" %\([[:alnum:]_]\+\)% in (\(.[^\"%\!]*\)) do set \(.[^=]*\)=%a% && set \(.[^=]*\)=%b% && set \(.[^=]*\)=%c%[[:space:]\t\r]*$|pendingIFS='\1' read -r \L\4 \5 \6\E < <(tr -d '\\\r' < \3)|I" "$currentScript"
    sed -i -e "s|^for /f \"tokens=1,2 delims=\([:;]\)\" %\([[:alnum:]_]\+\)% in (\(.[^\"%\!]*\)) do set \(.[^=]*\)=%a% && set \(.[^=]*\)=%b%[[:space:]\t\r]*$|pendingIFS='\1' read -r \L\4 \5\E < <(tr -d '\\\r' < \3)|I" "$currentScript"
    sed -i -e "s|^for /f \"tokens=1 delims=\([:;]\)\" %\([[:alnum:]_]\+\)% in (\(.[^\"%\!]*\)) do set \(.[^=]*\)=%a%[[:space:]\t\r]*$|pendingIFS='\1' read -r \L\4\E < <(tr -d '\\\r' < \3)|I" "$currentScript"
    
    #make batch statements lowercase
    sed -i -e '/^[[:space:]]\+if/Is/^\([[:space:]]\+\)if/\1if/I' "$currentScript"
    sed -i -e 's/^if/if/I' "$currentScript"
    sed -i -e '/^[[:space:]]\+if exist/Is/^\([[:space:]]\+\)if exist/\1if exist/I' "$currentScript"
    sed -i -e 's/^if exist/if exist/I' "$currentScript"
    sed -i -e 's/PENDINGL2IAD exist/PENDINGL2IAD exist/I' "$currentScript"
    sed -i -e 's/PENDINGTLIBF exist/PENDINGTLIBF exist/I' "$currentScript"
    sed -i -e 's/pendingL3I exist/pendingL3I exist/I' "$currentScript"
    sed -i -e '/^[[:space:]]\+if not exist/Is/^\([[:space:]]\+\)if not exist/\1if not exist/I' "$currentScript"
    sed -i -e 's/^if not exist/if not exist/I' "$currentScript"
    sed -i -e 's/PENDINGL2IAD not exist/PENDINGL2IAD not exist/I' "$currentScript"
    sed -i -e 's/PENDINGTLIBF not exist/PENDINGTLIBF not exist/I' "$currentScript"
    sed -i -e 's/pendingL3I not exist/pendingL3I not exist/I' "$currentScript"
    sed -i -e '/^[[:space:]]\+if not/Is/^\([[:space:]]\+\)if not/\1if not/I' "$currentScript"
    sed -i -e 's/^if not/if not/I' "$currentScript"
    sed -i -e 's/PENDINGL2IAD not/PENDINGL2IAD not/I' "$currentScript"
    sed -i -e 's/PENDINGTLIBF not/PENDINGTLIBF not/I' "$currentScript"
    sed -i -e 's/pendingL3I not/pendingL3I not/I' "$currentScript"
    sed -i -e '/^[[:space:]]\+if not defined/Is/^\([[:space:]]\+\)if not defined/\1if not defined/I' "$currentScript"
    sed -i -e 's/^if not defined/if not defined/I' "$currentScript"
    sed -i -e 's/PENDINGL2IAD not defined/PENDINGL2IAD not defined/I' "$currentScript"
    sed -i -e 's/PENDINGTLIBF not defined/PENDINGTLIBF not defined/I' "$currentScript"
    sed -i -e 's/pendingL3I not defined/pendingL3I not defined/I' "$currentScript"
    sed -i -e '/^[[:space:]]\+if defined/Is/^\([[:space:]]\+\)if defined/\1if defined/I' "$currentScript"
    sed -i -e 's/^if defined/if defined/I' "$currentScript"
    sed -i -e 's/PENDINGL2IAD defined/PENDINGL2IAD defined/I' "$currentScript"
    sed -i -e 's/PENDINGTLIBF defined/PENDINGTLIBF defined/I' "$currentScript"
    sed -i -e 's/pendingL3I defined/pendingL3I defined/I' "$currentScript"
    sed -i -e '/^[[:space:]]\+if errorlevel/Is/^\([[:space:]]\+\)if errorlevel/\1if errorlevel/I' "$currentScript"
    sed -i -e 's/^if errorlevel/if errorlevel/I' "$currentScript"
    sed -i -e 's/PENDINGL2IAD errorlevel/PENDINGL2IAD errorlevel/I' "$currentScript"
    sed -i -e 's/PENDINGTLIBF errorlevel/PENDINGTLIBF errorlevel/I' "$currentScript"
    sed -i -e 's/pendingL3I errorlevel/pendingL3I errorlevel/I' "$currentScript"
    sed -i -e '/^[[:space:]]\+set/Is/^\([[:space:]]\+\)set/\1set/I' "$currentScript"
    sed -i -e 's/^set/set/I' "$currentScript"
    sed -i -e '/^[[:space:]]\+for/Is/^\([[:space:]]\+\)for/\1for/I' "$currentScript"
    sed -i -e 's/^for/for/gI' "$currentScript"
    sed -i -e '/^[[:space:]]\+for/Is/do (/do (/gI' "$currentScript"
    sed -i -e '/^for/ s/do (/do (/gI' "$currentScript"
    
    #make if errorlevel statements consistent
    sed -i -e 's/if errorlevel = /if errorlevel /' "$currentScript"
    sed -i -e 's/PENDINGL2IAD errorlevel = /PENDINGL2IAD errorlevel /' "$currentScript"
    sed -i -e 's/PENDINGTLIBF errorlevel = /PENDINGTLIBF errorlevel /' "$currentScript"
    sed -i -e 's/pendingL3I errorlevel = /pendingL3I errorlevel /' "$currentScript"
    sed -i -e 's/if errorlevel=/if errorlevel /' "$currentScript"
    sed -i -e 's/PENDINGL2IAD errorlevel=/PENDINGL2IAD errorlevel /' "$currentScript"
    sed -i -e 's/PENDINGTLIBF errorlevel=/PENDINGTLIBF errorlevel /' "$currentScript"
    sed -i -e 's/pendingL3I errorlevel=/pendingL3I errorlevel /' "$currentScript"
    
    #convert if errorlevel statements
    sed -i -e "/^if errorlevel/ \
               s/^if \(errorlevel \)\(.[^[:space:]]*\)\(.*\)/[ $\1== \'\2\' ] \&\&\3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+if errorlevel/ \
               s/^\([[:space:]]\+\)if \(errorlevel\) \(.[^[:space:]]*\)\(.*\)/\1[ $\{\2\} == \'\3\' ] \&\&\4/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+pendingL3I errorlevel/ \
               s/^\([[:space:]]\+\)pendingL3I \(errorlevel\) \(.[^[:space:]]*\)\(.*\)/\1pendingL3I [ $\{\2\} == \'\3\' ] \&\&\4/" \
        "$currentScript"
    sed -i -e "/^PENDINGL2IAD errorlevel/ \
               s/^PENDINGL2IAD \(errorlevel\) \(.[^[:space:]]*\)\(.*\)/PENDINGL2IAD 2RMV [ $\{\1\} == \'\2\' ] \&\&\3/" \
        "$currentScript"
    sed -i -e "/^PENDINGTLIBF errorlevel/ \
               s/^PENDINGTLIBF \(errorlevel\) \(.[^[:space:]]*\)/PENDINGTLIBF 2RMV [ $\{\1\} == \'\2\' ] \&\& PENDINGTRAILTLIBF/" \
        "$currentScript"
    
    #convert if variable comparison statements
    sed -i -e "s/^if not \"\(.[^[:space:]\"]*\)\"==\"\(.[^[:space:]\"]*\)\" \(.*\)/[ \"\1\" != \"\2\" ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^if not \"\(.[^[:space:]\"]*\)\"==\"\" \(.*\)/[ \"\1\" != \"\" ] \&\& \2/" \
        "$currentScript"
    sed -i -e "s/^if not \"\(.[^[:space:]\"]*\)\" == \(.[^[:space:]]*\) \(.*\)/[ \"\1\" != \2 ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^if not \(.[^[:space:]\"]*\) == \(.[^[:space:]]*\) \(.*\)/[ \"\1\" != \2 ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^if not \(.[^[:space:]\"]*\)==\(.[^[:space:]]*\) \(.*\)/[ \"\1\" != \2 ] \&\& \3/" \
        "$currentScript"
        
    sed -i -e "s/^PENDINGL2IAD not \"\(.[^[:space:]\"]*\)\"==\"\(.[^[:space:]\"]*\)\" \(.*\)/PENDINGL2IAD 2RMV [ \"\1\" != \"\2\" ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^PENDINGL2IAD not \"\(.[^[:space:]\"]*\)\"==\"\" \(.*\)/PENDINGL2IAD 2RMV [ \"\1\" != \"\" ] \&\& \2/" \
        "$currentScript"
    sed -i -e "s/^PENDINGL2IAD not \"\(.[^[:space:]\"]*\)\" == \(.[^[:space:]]*\) \(.*\)/PENDINGL2IAD 2RMV [ \"\1\" != \2 ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^PENDINGL2IAD not \(.[^[:space:]\"]*\) == \(.[^[:space:]]*\) \(.*\)/PENDINGL2IAD 2RMV [ \"\1\" != \2 ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^PENDINGL2IAD not \(.[^[:space:]\"]*\)==\(.[^[:space:]]*\) \(.*\)/PENDINGL2IAD 2RMV [ \"\1\" != \2 ] \&\& \3/" \
        "$currentScript"
    
    sed -i -e "s/^PENDINGTLIBF not \"\(.[^[:space:]\"]*\)\"==\"\(.[^[:space:]\"]*\)\"/PENDINGTLIBF 2RMV [ \"\1\" != \"\2\" ] \&\& PENDINGTRAILTLIBF/" \
        "$currentScript"
    sed -i -e "s/^PENDINGTLIBF not \"\(.[^[:space:]\"]*\)\"==\"\"/PENDINGTLIBF 2RMV [ \"\1\" != \"\" ] \&\& PENDINGTRAILTLIBF/" \
        "$currentScript"
    sed -i -e "s/^PENDINGTLIBF not \"\(.[^[:space:]\"]*\)\" == \(.[^[:space:]]*\)/PENDINGTLIBF 2RMV [ \"\1\" != \2 ] \&\& PENDINGTRAILTLIBF/" \
        "$currentScript"
    sed -i -e "s/^PENDINGTLIBF not \(.[^[:space:]\"]*\) == \(.[^[:space:]]*\)/PENDINGTLIBF 2RMV [ \"\1\" != \2 ] \&\& PENDINGTRAILTLIBF/" \
        "$currentScript"
    sed -i -e "s/^PENDINGTLIBF not \(.[^[:space:]\"]*\)==\(.[^[:space:]]*\)/PENDINGTLIBF 2RMV [ \"\1\" != \2 ] \&\& PENDINGTRAILTLIBF/" \
        "$currentScript"
    
    sed -i -e "s/^if \"\(.[^[:space:]\"]*\)\"==\"\(.[^[:space:]\"]*\)\" \(.*\)/[ \"\1\" == \"\2\" ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^if \"\(.[^[:space:]\"]*\)\"==\"\" \(.*\)/[ \"\1\" == \"\" ] \&\& \2/" \
        "$currentScript"
    sed -i -e "s/^if \"\(.[^[:space:]\"]*\)\" == \(.[^[:space:]]*\) \(.*\)/[ \"\1\" == \2 ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^if \(.[^[:space:]\"]*\) == \(.[^[:space:]]*\) \(.*\)/[ \"\1\" == \2 ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^if \(.[^[:space:]\"]*\)==\(.[^[:space:]]*\) \(.*\)/[ \"\1\" == \2 ] \&\& \3/" \
        "$currentScript"
    
    sed -i -e "s/^PENDINGL2IAD \"\(.[^[:space:]\"]*\)\"==\"\(.[^[:space:]\"]*\)\" \(.*\)/PENDINGL2IAD 2RMV [ \"\1\" == \"\2\" ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^PENDINGL2IAD \"\(.[^[:space:]\"]*\)\"==\"\" \(.*\)/PENDINGL2IAD 2RMV [ \"\1\" == \"\" ] \&\& \2/" \
        "$currentScript"
    sed -i -e "s/^PENDINGL2IAD \"\(.[^[:space:]\"]*\)\" == \(.[^[:space:]]*\) \(.*\)/PENDINGL2IAD 2RMV [ \"\1\" == \2 ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^PENDINGL2IAD \(.[^[:space:]\"]*\) == \(.[^[:space:]]*\) \(.*\)/PENDINGL2IAD 2RMV [ \"\1\" == \2 ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^PENDINGL2IAD \(.[^[:space:]\"]*\)==\(.[^[:space:]]*\) \(.*\)/PENDINGL2IAD 2RMV [ \"\1\" == \2 ] \&\& \3/" \
        "$currentScript"
    
    sed -i -e "s/^PENDINGTLIBF \"\(.[^[:space:]\"]*\)\"==\"\(.[^[:space:]\"]*\)\"/PENDINGTLIBF 2RMV [ \"\1\" == \"\2\" ] \&\& PENDINGTRAILTLIBF/" \
        "$currentScript"
    sed -i -e "s/^PENDINGTLIBF \"\(.[^[:space:]\"]*\)\"==\"\"/PENDINGTLIBF 2RMV [ \"\1\" == \"\" ] \&\& PENDINGTRAILTLIBF/" \
        "$currentScript"
    sed -i -e "s/^PENDINGTLIBF \"\(.[^[:space:]\"]*\)\" == \(.[^[:space:]]*\)/PENDINGTLIBF 2RMV [ \"\1\" == \2 ] \&\& PENDINGTRAILTLIBF/" \
        "$currentScript"
    sed -i -e "s/^PENDINGTLIBF \(.[^[:space:]\"]*\) == \(.[^[:space:]]*\)/PENDINGTLIBF 2RMV [ \"\1\" == \2 ] \&\& PENDINGTRAILTLIBF/" \
        "$currentScript"
    sed -i -e "s/^PENDINGTLIBF \(.[^[:space:]\"]*\)==\(.[^[:space:]]*\)/PENDINGTLIBF 2RMV [ \"\1\" == \2 ] \&\& PENDINGTRAILTLIBF/" \
        "$currentScript"
    
    #convert if varible existence checks
    sed -i -e "s/^if not defined \"%\(.[^[:space:]%\"]*\)\" /if not defined \"$\{\1\}\" /" "$currentScript"
    sed -i -e "s/^PENDINGL2IAD not defined \"%\(.[^[:space:]%\"]*\)\" /PENDINGL2IAD not defined \"$\{\1\}\" /" "$currentScript"
    sed -i -e "s/^PENDINGTLIBF not defined \"%\(.[^[:space:]%\"]*\)\" /PENDINGTLIBF not defined \"$\{\1\}\" /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)if not defined \"%\(.[^[:space:]%\"]*\)\" /\1if not defined \"$\{\2\}\" /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)pendingL3I not defined \"%\(.[^[:space:]%\"]*\)\" /\1pendingL3I not defined \"$\{\2\}\" /" "$currentScript"
    sed -i -e "s/^if defined \"%\(.[^[:space:]%\"]*\)\" /if defined \"$\{\1\}\" /" "$currentScript"
    sed -i -e "s/^PENDINGL2IAD defined \"%\(.[^[:space:]%\"]*\)\" /PENDINGL2IAD defined \"$\{\1\}\" /" "$currentScript"
    sed -i -e "s/^PENDINGTLIBF defined \"%\(.[^[:space:]%\"]*\)\" /PENDINGTLIBF defined \"$\{\1\}\" /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)if defined \"%\(.[^[:space:]%\"]*\)\" /\1if defined \"$\{\1\}\" /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)pendingL3I defined \"%\(.[^[:space:]%\"]*\)\" /\1pendingL3I defined \"$\{\1\}\" /" "$currentScript"
    sed -i -e "s/^if not defined %\(.[^[:space:]%\"]*\) /if not defined $\{\1\} /" "$currentScript"
    sed -i -e "s/^PENDINGL2IAD not defined %\(.[^[:space:]%\"]*\) /PENDINGL2IAD not defined $\{\1\} /" "$currentScript"
    sed -i -e "s/^PENDINGTLIBF not defined %\(.[^[:space:]%\"]*\) /PENDINGTLIBF not defined $\{\1\} /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)if not defined %\(.[^[:space:]%\"]*\) /\1if not defined $\{\2\} /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)pendingL3I not defined %\(.[^[:space:]%\"]*\) /\1pendingL3I not defined $\{\2\} /" "$currentScript"
    sed -i -e "s/^if defined %\(.[^[:space:]%\"]*\) /if defined $\{\1\} /" "$currentScript"
    sed -i -e "s/^PENDINGL2IAD defined %\(.[^[:space:]%\"]*\) /PENDINGL2IAD defined $\{\1\} /" "$currentScript"
    sed -i -e "s/^PENDINGTLIBF defined %\(.[^[:space:]%\"]*\) /PENDINGTLIBF defined $\{\1\} /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)if defined %\(.[^[:space:]%\"]*\) /\1if defined $\{\2\} /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)pendingL3I defined %\(.[^[:space:]%\"]*\) /\1pendingL3I defined $\{\2\} /" "$currentScript"
    sed -i -e "s/^if not defined \([[:alnum:]_]*\) /if not defined $\{\1\} /" "$currentScript"
    sed -i -e "s/^PENDINGL2IAD not defined \([[:alnum:]_]*\) /PENDINGL2IAD not defined $\{\1\} /" "$currentScript"
    sed -i -e "s/^PENDINGTLIBF not defined \([[:alnum:]_]*\) /PENDINGTLIBF not defined $\{\1\} /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)if not defined \([[:alnum:]_]*\) /\1if not defined $\{\2\} /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)pendingL3I not defined \([[:alnum:]_]*\) /\1pendingL3I not defined $\{\2\} /" "$currentScript"
    sed -i -e "s/^if defined \([[:alnum:]_]*\) /if defined $\{\1\} /" "$currentScript"
    sed -i -e "s/^PENDINGL2IAD defined \([[:alnum:]_]*\) /PENDINGL2IAD defined $\{\1\} /" "$currentScript"
    sed -i -e "s/^PENDINGTLIBF defined \([[:alnum:]_]*\) /PENDINGTLIBF defined $\{\1\} /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)if defined \([[:alnum:]_]*\) /\1if defined $\{\2\} /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)pendingL3I defined \([[:alnum:]_]*\) /\1pendingL3I defined $\{\2\} /" "$currentScript"
    sed -i -e "s/^if not defined \(.[^[:space:]]*\) \(.*\)/[ \1 = \"\" ] \&\& \2/" \
        "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)if not defined \(.[^[:space:]]*\) \(.*\)/\1[ \2 = \"\" ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)pendingL3I not defined \(.[^[:space:]]*\) \(.*\)/\1pendingL3I [ \2 = \"\" ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^if defined \(.[^[:space:]]*\) \(.*\)/[ \1 != \"\" ] \&\& \2/" \
        "$currentScript"
    sed -i -e "s/^PENDINGL2IAD defined \(.[^[:space:]]*\) \(.*\)/PENDINGL2IAD 2RMV [ \1 != \"\" ] \&\& \2/" \
        "$currentScript"
    sed -i -e "s/^PENDINGTLIBF defined \(.[^[:space:]]*\)/PENDINGTLIBF 2RMV [ \1 != \"\" ] \&\& PENDINGTRAILTLIBF/" \
        "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)if defined \(.[^[:space:]]*\) \(.*\)/\1[ \2 != \"\" ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)pendingL3I defined \(.[^[:space:]]*\) \(.*\)/\1pendingL3I [ \2 != \"\" ] \&\& \3/" \
        "$currentScript"
    
    #fix ! on all echo lines as well as redirects (except conditional echos)
    sed -i -e "/^echo.*\!/ {
                   s/#/##/g;
                   s/\!/\\\!#/g;
                   :a;
                   s/^\(echo.*>.*\)\\\!#\(.*\)/\1\\\!\2/;
                   ta;
                   s/\\\!#/\"'\!'\"/g;
                   s/##/#/g;
               }" "$currentScript"
               
    sed -i -e "/^[[:space:]]\+echo.*\!/ {
                   s/#/##/g;
                   s/\!/\\\!#/g;
                   :a;
                   s/^\([[:space:]]\+\)\(echo.*>.*\)\\\!#\(.*\)/\1\2\\\!\3/;
                   ta;
                   s/\\\!#/\"'\!'\"/g;
                   s/##/#/g;
               }" "$currentScript"
    
    #removing setconsole lines
    sed -i -e '/setconsole\.exe/Id' "$currentScript"
    
    #fix %cd% references
    sed -i -e 's/%cd%/$\{PWD\}/I' "$currentScript"
    
    #correct beginning part of for loop declaration
    sed -i -e 's|^for /f %\(.\)%|for \1|I' "$currentScript"
    sed -i -e 's|^\(^[[:space:]]\+\)for /f %\(.\)%|\1for \2|I' "$currentScript"
    
    #correct middle part of for loop declaration
    sed -i -e '/^for/I s/in (/in /I' "$currentScript"
    sed -i -e '/^\(^[[:space:]]\+\)for/I s/in (/in /I' "$currentScript"
    
    #correct last part of for loop declaration
    sed -i -e '/^for/I s/) do (\(.*\))/\ndo\n\1\ndone/I' "$currentScript"
    sed -i -e '/^for/I s/) do ([[:space:]\t]*$/\ndo/I' "$currentScript"
    sed -i -e '/^for/I s|) do \([^(]*\)[[:space:]\t]*$|\ndo\n\1\ndone|I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)\(for.*\)) do (\(.*\))/\1\2\n\1do\n\1\3\n\1done/I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)\(for.*\)) do ([[:space:]\t]*$/\1\2\n\1do/I' "$currentScript"
    sed -i -e 's|^\(^[[:space:]]\+\)\(for.*\)) do \([^(]*\)[[:space:]\t]*$|\1\2\n\1do\n\1\3\n\1done|I' "$currentScript"
    
    #convert for loop to obtain public IP
    sed -i -e '$!N;/^for.*\n.*powershell.*Invoke-Web/I!P;D' "$currentScript"
    sed -i -e '$!N;/powershell.*Invoke-Web.*\n) Do Set ExtIP.*/I!P;D' "$currentScript"
    sed -i -e '/) Do Set ExtIP=.*/Ic extip=`curl -4 ident.me`' "$currentScript"
    
    #convert for loop to obtain private IP
    sed -i -e '$!N;/^for.*tokens.*ipconfig.*\ndo.*/I!P;D' "$currentScript"
    sed -i -e '$!N;/^do\n.*ip==%b%/I!P;D' "$currentScript"
    sed -i -e '/^set ip==%b%/,+1d' "$currentScript"
    
    sed -i -e '/ipaddress=.*/Ic ipaddress=`ip -4 -o addr show up primary scope global | sed -e "s|^.*inet \\(.*\\)/.* brd.*|\\1|"`' "$currentScript"

    #prevent ending parenthesis for if statements from becoming done .... we'll name them something temporary (all of the if substitutions using done later will need to be changed to account for this)
    sed -i -e "/^PENDINGL2IAD .*([[:space:]\t]*$/,/^)[[:space:]\t]*$/I s/^)[[:space:]\t]*$/PENDINGFI\n\done/" "$currentScript"
    sed -i -e "/^if .*([[:space:]\t]*$/,/^)[[:space:]\t]*$/I s/^)[[:space:]\t]*$/PENDINGFI/" "$currentScript"
    sed -i -e "/^\(^[[:space:]]\+\)if .*([[:space:]\t]*$/,/^\(^[[:space:]]\+\))[[:space:]\t]*$/I s/^\(^[[:space:]]\+\))[[:space:]\t]*$/\1PENDINGFI/" "$currentScript"
    sed -i -e "/^\[ .* && ([[:space:]\t]*$/,/^)[[:space:]\t]*$/I s/^)[[:space:]\t]*$/PENDINGFI/" "$currentScript"
    sed -i -e "/^\(^[[:space:]]\+\)\[ .* && ([[:space:]\t]*$/,/^\(^[[:space:]]\+\))[[:space:]\t]*$/I s/^\(^[[:space:]]\+\))[[:space:]\t]*$/\1PENDINGFI/" "$currentScript"
    sed -i -e "s/^PENDINGL2IAD 2RMV //" "$currentScript"
    sed -i -e "s/^PENDINGTLIBF 2RMV //" "$currentScript"
    sed -i -e "s/^PENDINGL2IAD/if/" "$currentScript"
    sed -i -e "s/^PENDINGTLIBF/if/" "$currentScript"
    
    #correct end of for loop
    sed -i -e '/^)[[:space:]\t]*$/ s/)/done/' "$currentScript"
    sed -i -e '/^[[:space:]]\+)[[:space:]\t]*$/ s/\(^[[:space:]]\+\))/\1done/' "$currentScript"
    
    #add quotes to if exist statements if not present (for consistency)
    sed -i -e "/^if exist \"/I! \
               s/^if exist \([^ ]*\) rd \(.*\)/if exist \"\1\" rd \2/" \
        "$currentScript"
    sed -i -e "/^if exist \"/I! \
               s/^if exist \([^ ]*\) cd \(.*\)/if exist \"\1\" cd \2/" \
        "$currentScript"
    sed -i -e "/^if exist \"/I! \
               s/^if exist \([^ ]*\) unzip \(.*\)/if exist \"\1\" unzip \2/" \
        "$currentScript"
    sed -i -e "/^if exist \"/I! \
               s/^if exist \([^\.]*\)\([^ ]*\)\(.*\)/if exist \"\1\2\"\3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+if exist \"/I! \
               s/^\(^[[:space:]]\+\)if exist \([^ ]*\) rd \(.*\)/\1if exist \"\2\" rd \3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+if exist \"/I! \
               s/^\(^[[:space:]]\+\)if exist \([^ ]*\) cd \(.*\)/\1if exist \"\2\" cd \3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+if exist \"/I! \
               s/^\(^[[:space:]]\+\)if exist \([^ ]*\) unzip \(.*\)/\1if exist \"\2\" unzip \3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+if exist \"/I! \
               s/^\(^[[:space:]]\+\)if exist \([^\.]*\)\([^ ]*\)\(.*\)/\1if exist \"\2\3\"\4/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+pendingL3I exist \"/I! \
               s/^\(^[[:space:]]\+\)pendingL3I exist \([^\.]*\)\([^ ]*\)\(.*\)/\1pendingL3I exist \"\2\3\"\4/" \
        "$currentScript"
    
    #add quotes to if not exist statements if not present (for consistency)
    sed -i -e "/^if not exist \"/I! \
               s/^if not exist \([^ ]*\) rd \(.*\)/if not exist \"\1\" rd \2/" \
        "$currentScript"
    sed -i -e "/^if not exist \"/I! \
               s/^if not exist \([^ ]*\) cd \(.*\)/if not exist \"\1\" cd \2/" \
        "$currentScript"
    sed -i -e "/^if not exist \"/I! \
               s/^if not exist \([^ ]*\) unzip \(.*\)/if not exist \"\1\" unzip \2/" \
        "$currentScript"
    sed -i -e "/^if not exist \"/I! \
               s/^if not exist \([^\.]*\)\([^ ]*\)\(.*\)/if not exist \"\1\2\"\3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+if not exist \"/I! \
               s/^\(^[[:space:]]\+\)if not exist \([^ ]*\) rd \(.*\)/\1if not exist \"\2\" rd \3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+if not exist \"/I! \
               s/^\(^[[:space:]]\+\)if not exist \([^ ]*\) cd \(.*\)/\1if not exist \"\2\" cd \3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+if not exist \"/I! \
               s/^\(^[[:space:]]\+\)if not exist \([^ ]*\) unzip \(.*\)/\1if not exist \"\2\" unzip \3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+if not exist \"/! \
               s/^\(^[[:space:]]\+\)if not exist \([^\.]*\)\([^ ]*\)\(.*\)/\1if not exist \"\2\3\"\4/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+pendingL3I not exist \"/! \
               s/^\(^[[:space:]]\+\)pendingL3I not exist \([^\.]*\)\([^ ]*\)\(.*\)/\1pendingL3I not exist \"\2\3\"\4/" \
        "$currentScript"
    
    #fix if exist statements (structure)
    sed -i -e "/^if exist \"/I \
               s/^if exist \"\([^\"]*\)\"\(.*\)/[ -e \"\1\" ] \&\&\2/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+if exist \"/I \
               s/^\(^[[:space:]]\+\)if exist \"\([^\"]*\)\"\(.*\)/\1[ -e \"\2\" ] \&\&\3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+pendingL3I exist \"/I \
               s/^\(^[[:space:]]\+\)pendingL3I exist \"\([^\"]*\)\"\(.*\)/\1pendingL3I [ -e \"\2\" ] \&\&\3/" \
        "$currentScript"
    sed -i -e "s/ \"\[\(\%[[:alnum:]_]\+\%\)\]\" == \[\] / -z \"\1\" /" "$currentScript"
    sed -i -e "s/ \"\[\(\%[[:alnum:]_]\+\%\)\]\" \!= \[\] / \! -z \"\1\" /" "$currentScript"
    sed -i -e "s/ \"\[\([[:alnum:]_]\+\)\]\" == \[\] / -z \"\1\" /" "$currentScript"
    sed -i -e "s/ \"\[\([[:alnum:]_]\+\)\]\" \!= \[\] / \! -z \"\1\" /" "$currentScript"
    
    #fix if not exist statements (structure)
    sed -i -e "/^if not exist \"/I \
               s/^if not exist \"\([^\"]*\)\"\(.*\)/[ ! -e \"\1\" ] \&\&\2/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+if not exist \"/I \
               s/^\(^[[:space:]]\+\)if not exist \"\([^\"]*\)\"\(.*\)/\1[ ! -e \"\2\" ] \&\&\3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+pendingL3I not exist \"/I \
               s/^\(^[[:space:]]\+\)pendingL3I not exist \"\([^\"]*\)\"\(.*\)/\1pendingL3I [ ! -e \"\2\" ] \&\&\3/" \
        "$currentScript"
    
    #fix if exist/if not exist statements (escape ( characters)
    sed -i -e "/^\[ -e \"\|^\[ ! -e \"\|^[[:space:]]\+\[ -e \"\|^[[:space:]]\+\[ ! -e \"\|^[[:space:]]\+pendingL3I \[ -e \"\|^[[:space:]]\+pendingL3I \[ ! -e \"/ {
                   s|\(echo \"\)\([^\"]*\)%|\1\2#####|g;
                   s|\(echo \"\)\([^\"]*\)(|\1\2=====|g;
                   s|%|%%|g;
                   s|(|(%|g;
                   :a;
                   s|\"\(.*\)(%\(.*\)\" ] &&|\"\1\\\(\2\" ] \&\&|;
                   ta;
                   s|(%|(|g;
                   s|%%|%|g;
                   s|#####|%|g;
                   s|=====|(|g;
               }" "$currentScript"
    
    #fix if exist/if not exist statements (escape ) characters)
    sed -i -e "/^\[ -e \"\|^\[ ! -e \"\|^[[:space:]]\+\[ -e \"\|^[[:space:]]\+\[ ! -e \"\|^[[:space:]]\+pendingL3I \[ -e \"\|^[[:space:]]\+pendingL3I \[ ! -e \"/ {
                   s|\(echo \"\)\([^\"]*\)%|\1\2#####|g;
                   s|\(echo \"\)\([^\"]*\))|\1\2=====|g;
                   s|%|%%|g;
                   s|)|)%|g;
                   :a;
                   s|\"\(.*\))%\(.*\)\" ] &&|\"\1\\\)\2\" ] \&\&|;
                   ta;
                   s|)%|)|g;
                   s|%%|%|g;
                   s|#####|%|g;
                   s|=====|)|g;
               }" "$currentScript"
    
    #fix if exist/if not exist statements (escape & characters)
    sed -i -e "/^\[ -e \"\|^\[ ! -e \"\|^[[:space:]]\+\[ -e \"\|^[[:space:]]\+\[ ! -e \"\|^[[:space:]]\+pendingL3I \[ -e \"\|^[[:space:]]\+pendingL3I \[ ! -e \"/ {
                   s|\] \&\&|] ######|g;
                   s|\] ######\(.*\) \&\&|] ######\1 ######|g;
                   s|\&|\\\&|g;
                   s|######|\&\&|g;
               }" "$currentScript"
    
    # remove quotes from if exist/if not exist statements
    sed -i -e "s/\[ -e \"\([^\"]*\)\" \]/[ -e \1 ]/" "$currentScript"
    sed -i -e "s/\[ ! -e \"\([^\"]*\)\" \]/[ ! -e \1 ]/" "$currentScript"

    #fix if numeric comparisons
    sed -i -e "s/^if \(.[^[:space:]]*\) gtr \(.[^[:space:]]*\) \(.*\)/[ \1 -gt \2 ] \&\& \3/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \(.[^[:space:]]*\) gtr \(.[^[:space:]]*\) \(.*\)/\1[ \2\ -gt \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)pendingL3I \(.[^[:space:]]*\) gtr \(.[^[:space:]]*\) \(.*\)/\1pendingL3I [ \2\ -gt \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^if \(.[^[:space:]]*\) lss \(.[^[:space:]]*\) \(.*\)/[ \1 -lt \2 ] \&\& \3/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \(.[^[:space:]]*\) lss \(.[^[:space:]]*\) \(.*\)/\1[ \2 -lt \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)pendingL3I \(.[^[:space:]]*\) lss \(.[^[:space:]]*\) \(.*\)/\1pendingL3I [ \2 -lt \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^if \(.[^[:space:]]*\) equ \(.[^[:space:]]*\) \(.*\)/[ \1 -eq \2 ] \&\& \3/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \(.[^[:space:]]*\) equ \(.[^[:space:]]*\) \(.*\)/\1[ \2 -eq \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)pendingL3I \(.[^[:space:]]*\) equ \(.[^[:space:]]*\) \(.*\)/\1pendingL3I [ \2 -eq \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^if \(.[^[:space:]]*\) neq \(.[^[:space:]]*\) \(.*\)/[ \1 -ne \2 ] \&\& \3/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \(.[^[:space:]]*\) neq \(.[^[:space:]]*\) \(.*\)/\1[ \2 -ne \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)pendingL3I \(.[^[:space:]]*\) neq \(.[^[:space:]]*\) \(.*\)/\1pendingL3I [ \2 -ne \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^if \(.[^[:space:]]*\) leq \(.[^[:space:]]*\) \(.*\)/[ \1 -le \2 ] \&\& \3/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \(.[^[:space:]]*\) leq \(.[^[:space:]]*\) \(.*\)/\1[ \2 -le \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)pendingL3I \(.[^[:space:]]*\) leq \(.[^[:space:]]*\) \(.*\)/\1pendingL3I [ \2 -le \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^if \(.[^[:space:]]*\) geq \(.[^[:space:]]*\) \(.*\)/[ \1 -ge \2 ] \&\& \3/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \(.[^[:space:]]*\) geq \(.[^[:space:]]*\) \(.*\)/\1[ \2 -ge \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)pendingL3I \(.[^[:space:]]*\) geq \(.[^[:space:]]*\) \(.*\)/\1pendingL3I [ \2 -ge \3 ] \&\& \4/I" \
        "$currentScript"
    
    #convert conditional ren commands to mv commands
    sed -i -e "/&& ren/I s|ren \([^[:space:]\"]*\)/\([^[:space:]\"]*\) \([^[:space:]\"]*\)|mv \1/\2 \1/\3|I" "$currentScript"
    sed -i -e "/&& ren/I s|ren \"\([^\"]*\)/\([^\"]*\)\" \"\([^\"]*\)\"|mv \"\1/\2\" \"\1/\3\"|I" "$currentScript"
    
    #evaluate numeric expressions
    sed -i -e '/set \/A/Is|set /A \([^+-=]*\)+=\(.[^[:space:]]*\)|\1=$(( $\1 + \2 ))|I' "$currentScript"
    sed -i -e '/set \/A/Is|set /A \([^+-=]*\)-=\(.[^[:space:]]*\)|\1=$(( $\1 - \2 ))|I' "$currentScript"
    sed -i -e '/set \/A/Is|set /A \([^=]*\)\(=\)\(.[^[:space:]]*\)|\1\2$(( \3 ))|I' "$currentScript"
    
    #change vlc references to use ffplay instead (ensure ffmpeg is present)
    sed -i -e 's|\./eXo/util/ffplay\.exe |ffplay |I' "$currentScript"
    sed -i -e 's|\./ThirdParty/VLC/x64/vlc\.exe --play-and-exit |ffplay -v 0 -nodisp -autoexit |I' "$currentScript"
    
    #escape " in variable declaration values
#    sed -i -e 's/\(^set [[:alnum:]_]\+=[^"]*\)\"/\1\\\"/I' "$currentScript"
    
    #Make variable declarations lowercase and remove 'set '
    sed -i -e 's/\(^set \)\([^=]*\)\(=\)/\L\2\E\3/I' "$currentScript"
    sed -i -e 's/Updaterline/updaterline/Ig' "$currentScript"

    #Make all variable references lowercase in bash style
    sed -i -e '/\%\%/!s/\%\([[:alnum:]_]\+\)\%\([[:alnum:]_]\+\)/$\{\L\1\E\}\2/g' "$currentScript"
    sed -i -e '/\%\%/!s/\(\%\)\([^[:space:]\%]\+\)\(\%\)/$\{\L\2\E\}/g' "$currentScript"
    sed -i -e '/\%\%/!s|/\${\(.\)}\"|/\$\{\L\1\E\}\"|' "$currentScript"
    sed -i -e 's/PENDINGDLR/$/g' "$currentScript"
    sed -i -e 's/PENDINGPCT/%/g' "$currentScript"
    
    #make utility run references consistent
    sed -i -e 's|^[\./]*choice\.exe \(.*\)|choice \1|I' "$currentScript"
    sed -i -e 's|^[\./]*choice \(.*\)|choice \1|I' "$currentScript"
    sed -i -e 's|^[\./]*util/choice\.exe \(.*\)|choice \1|I' "$currentScript"
    sed -i -e 's|^[\./]*util/choice \(.*\)|choice \1|I' "$currentScript"
    sed -i -e 's|^[\./]*exo/util/choice\.exe \(.*\)|choice \1|I' "$currentScript"
    sed -i -e 's|^[\./]*exo/util/choice \(.*\)|choice \1|I' "$currentScript"
    
    #make ssr references consistent
    sed -i -e 's|^[\./]*util/ssr\.exe \(.*\)|ssr \1|I' "$currentScript"
    sed -i -e 's|^[\./]*ssr\.exe \(.*\)|ssr \1|I' "$currentScript"
    sed -i -e 's|^[\./]*util/ssr \(.*\)|ssr \1|I' "$currentScript"
    sed -i -e 's|^[\./]*ssr \(.*\)|ssr \1|I' "$currentScript"
    sed -i -e 's|\&\& [\./]*util/ssr\.exe |\&\& ssr |I' "$currentScript"
    sed -i -e 's|\&\& [\./]*ssr\.exe |\&\& ssr |I' "$currentScript"
    sed -i -e 's|\&\& [\./]*util/ssr |\&\& ssr |I' "$currentScript"
    sed -i -e 's|\&\& [\./]*ssr |\&\& ssr |I' "$currentScript"
    
    #fix scummvm references
    sed -i -e 's|^"[\./]*scummvm/scummvm\.exe"|flatpak run com.retro_exo.scummvm-2-2-0|I' "$currentScript"
    sed -i -e 's|^"[\./]*emulators/scummvm/scummvm\.exe"|flatpak run com.retro_exo.scummvm-2-2-0|I' "$currentScript"
    sed -i -e 's|^"scummvm/svn/scummvm\.exe"|flatpak run com.retro_exo.scummvm-2-3-0-git15811-gf97bfb7ce1|I' "$currentScript"
    sed -i -e 's|^"emulators/scummvm/svn/scummvm\.exe"|flatpak run com.retro_exo.scummvm-2-3-0-git15811-gf97bfb7ce1|I' "$currentScript"
    sed -i -e 's|^"\./scummvm/svn/scummvm\.exe"|flatpak run com.retro_exo.scummvm-2-3-0-git15811-gf97bfb7ce1|I' "$currentScript"
    sed -i -e 's|^"\./emulators/scummvm/svn/scummvm\.exe"|flatpak run com.retro_exo.scummvm-2-3-0-git15811-gf97bfb7ce1|I' "$currentScript"
    sed -i -e "s|^\"[\./]*emulators/scmvm/\(\${svm}\"\)|\"\1|I" "$currentScript"
    sed -i -e "s|\&\& \"[\./]*emulators/scvm/\(\${svm}\"\)|\&\& \"\1|I" "$currentScript"
    sed -i -e '/--config=/! s|flatpak run com.retro_exo.scummvm-2-2-0|flatpak run com.retro_exo.scummvm-2-2-0 --config=./emulators/scummvm/scummvm_linux.ini|I' "$currentScript"
    sed -i -e '/--config=/! s|flatpak run com.retro_exo.scummvm-2-3-0-git15811-gf97bfb7ce1|flatpak run com.retro_exo.scummvm-2-3-0-git15811-gf97bfb7ce1 --config=./emulators/scummvm/svn/scummvm_linux.ini|I' "$currentScript"
    
    #fix gzdoom references
    sed -i -e 's|[\./]*gzdoom/gzdoom |flatpak run --env=DOOMWADDIR=./gzdoom com.retro_exo.gzdoom-4-11-3 -config ./gzdoom/gzdoom.ini |I' "$currentScript"
    sed -i -e 's|[\./]*gzdoom/gzdoom\.exe |flatpak run --env=DOOMWADDIR=./gzdoom com.retro_exo.gzdoom-4-11-3 -config ./gzdoom/gzdoom.ini |I' "$currentScript"
    
    #fix 86Box references
    sed -i -e 's|^"\([\./]*emulators/86Box/\)86Box\.exe" -C|\186Box-Linux-x86_64-b6130.AppImage -R \1Roms -C|I' "$currentScript"
    
#    #fix RW1_EDIT.EXE execution line
#    sed -i -e 's|^"eXoDOS/\$gamedir/RW1_EDIT.EXE"|wine "eXoDOS/$gamedir/RW1_EDIT.EXE"|I' "$currentScript"

    #fix dosbox references
    sed -i -e 's|^taskkill /IM \(.*\)|kill \`pidof \1\` 2>/dev/null|I' "$currentScript"
    sed -i -e 's|^taskkill /F /IM \(.*\)|kill \`pidof \1\` 2>/dev/null|I' "$currentScript"
    sed -i -e 's|^"./dosbox/dosbox\.exe"|flatpak run com.retro_exo.dosbox-074r3-1|I' "$currentScript"
    sed -i -e 's|^"dosbox/dosbox\.exe"|flatpak run com.retro_exo.dosbox-074r3-1|I' "$currentScript"
    sed -i -e 's|^"[\./]*emulators/dosbox/dosbox\.exe"|flatpak run com.retro_exo.dosbox-074r3-1|I' "$currentScript"
    sed -i -e 's|^"dosbox/074r3/dosbox\.exe"|flatpak run com.retro_exo.dosbox-074r3-1|I' "$currentScript"
    sed -i -e 's|^"dosbox/dosboxsvn\.exe"|flatpak run com.retro_exo.dosbox-ece-r4301|I' "$currentScript"
    sed -i -e 's|^"[\./]*emulators/dosbox/DWDdosbox/dosbox\.exe"|flatpak run com.retro_exo.dosbox-gridc-4-3-1|I' "$currentScript"
    sed -i -e 's|^"dosbox/ece/dosbox\.exe"|flatpak run com.retro_exo.dosbox-ece-r4301|I' "$currentScript"
    sed -i -e 's|^"[\./]*emulators/dosbox/ece4230/dosbox\.exe"|flatpak run com.retro_exo.dosbox-ece-r4301|I' "$currentScript"
    sed -i -e 's|^"dosbox/ece_svn/dosbox\.exe"|flatpak run com.retro_exo.dosbox-ece-r4482|I' "$currentScript"
    sed -i -e 's|^"[\./]*emulators/dosbox/ece4460/dosbox\.exe"|flatpak run com.retro_exo.dosbox-ece-r4482|I' "$currentScript"
    sed -i -e 's|^"[\./]*emulators/dosbox/ece4481/dosbox\.exe"|flatpak run com.retro_exo.dosbox-ece-r4482|I' "$currentScript"
    sed -i -e 's|^"dosbox/x/dosbox\.exe"|flatpak run com.retro_exo.dosbox-x-08220|I' "$currentScript"
    sed -i -e 's|^"[\./]*emulators/dosbox/x/dosbox\.exe"|flatpak run com.retro_exo.dosbox-x-08220|I' "$currentScript"
    sed -i -e 's|^"[\./]*emulators/dosbox/x2/dosbox\.exe"|flatpak run com.retro_exo.dosbox-x-20240701|I' "$currentScript"
    sed -i -e 's|^"[\./]*emulators/dosbox/staging0\.82\.0/dosbox\.exe"|flatpak run com.retro_exo.dosbox-staging-082-0|I' "$currentScript"
    sed -i -e 's|^"[\./]*emulators/dosbox/staging0\.81\.2/dosbox\.exe"|flatpak run com.retro_exo.dosbox-staging-081-2|I' "$currentScript"
    sed -i -e 's|^"[\./]*emulators/dosbox/staging0\.81\.1/dosbox\.exe"|flatpak run com.retro_exo.dosbox-staging-081-2|I' "$currentScript"
    sed -i -e 's|^"[\./]*emulators/dosbox/staging0\.81\.0a/dosbox\.exe"|flatpak run com.retro_exo.dosbox-staging-081-2|I' "$currentScript"
    sed -i -e 's|^"[\./]*emulators/dosbox/staging0\.80\.1/dosbox\.exe"|flatpak run com.retro_exo.dosbox-staging-081-2|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*emulators/dosbox/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-074r3-1"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*emulators/dosbox/daum/dosbox\.exe|dosbox="flatpak run com.retro_exo.wine emulators/dosbox/daum/dosbox.exe"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*emulators/dosbox/DWDdosbox/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-gridc-4-3-1"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*emulators/dosbox/ece4230/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-ece-r4301"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*emulators/dosbox/ece4460/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-ece-r4482"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*emulators/dosbox/ece4481/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-ece-r4482"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*emulators/dosbox/x/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-x-08220"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*emulators/dosbox/x2/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-x-20240701"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*emulators/dosbox/staging0\.82\.0/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-staging-082-0"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*emulators/dosbox/staging0\.81\.2/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-staging-081-2"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*emulators/dosbox/staging0\.81\.1/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-staging-081-2"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*emulators/dosbox/staging0\.81\.0a/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-staging-081-2"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*emulators/dosbox/staging0\.80\.1/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-staging-081-2"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*dosbox/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-074r3-1"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*dosbox/daum/dosbox\.exe|dosbox="flatpak run com.retro_exo.wine dosbox/daum/dosbox.exe"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*dosbox/DWDdosbox/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-gridc-4-3-1"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*dosbox/ece4230/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-ece-r4301"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*dosbox/ece4460/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-ece-r4482"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*dosbox/ece4481/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-ece-r4482"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*dosbox/x/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-x-08220"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*dosbox/x2/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-x-20240701"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*dosbox/staging0\.82\.0/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-staging-082-0"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*dosbox/staging0\.81\.2/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-staging-081-2"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*dosbox/staging0\.81\.1/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-staging-081-2"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*dosbox/staging0\.81\.0a/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-staging-081-2"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*dosbox/staging0\.80\.1/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-staging-081-2"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-074r3-1"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*daum/dosbox\.exe|dosbox="flatpak run com.retro_exo.wine daum/dosbox.exe"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*DWDdosbox/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-gridc-4-3-1"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*ece4230/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-ece-r4301"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*ece4460/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-ece-r4482"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*ece4481/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-ece-r4482"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*x/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-x-08220"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*x2/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-x-20240701"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*staging0\.82\.0/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-staging-082-0"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*staging0\.81\.2/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-staging-081-2"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*staging0\.81\.1/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-staging-081-2"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*staging0\.81\.0a/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-staging-081-2"|I' "$currentScript"
    sed -i -e 's|dosbox=[\./]*staging0\.80\.1/dosbox\.exe|dosbox="flatpak run com.retro_exo.dosbox-staging-081-2"|I' "$currentScript"
    sed -i -e 's|"dosbox/dosbox\.exe"|"dosbox/DOSBox\.exe"|I' "$currentScript"
    sed -i -e 's|"dosbox/ece/dosbox\.exe"|"dosbox/ece/DOSBox\.exe"|I' "$currentScript"
    sed -i -e 's|"dosbox/074r3/dosbox\.exe"|"dosbox/074r3/DOSBox\.exe"|I' "$currentScript"
    sed -i -e 's|"dosbox/ece_svn/dosbox\.exe"|"dosbox/ece_svn/DOSBox\.exe"|I' "$currentScript"
    sed -i -e 's|"dosbox/svn/dosbox\.exe"|"dosbox/svn/dosbox\.exe"|I' "$currentScript"
    sed -i -e 's|"dosbox/svn2/dosbox\.exe"|"dosbox/svn2/dosbox\.exe"|I' "$currentScript"
    sed -i -e 's|"dosbox/x/dosbox\.exe"|"dosbox/x/dosbox\.exe"|I' "$currentScript"  
    sed -i -e "s|^\"[\./]*emulators/dosbox/\(\${dosbox}\"\)|\"\1|I" "$currentScript"
    sed -i -e "s|\&\& \"[\./]*emulators/dosbox/\(\${dosbox}\"\)|\&\& \"\1|I" "$currentScript"
    sed -i -e '/dosbox\.exe" -/I {
                   s/^"/flatpak run com.retro_exo.wine "/;
                }' "$currentScript"
    # Note: DAUM conversion disabled due to Linux bugs and lack of Direct3D support; Wine used instead
    
    #fix aria2c references
    sed -i -e '/^cp \|^[[:space:]]\+cp \| cp \|^rm \|^[[:space:]]\+rm \| rm \|tasklist/I! s/aria2c /flatpak run com.retro_exo.aria2c /I' "$currentScript"
    
    #fix vlc references
    sed -i -e '/^cp \|^[[:space:]]\+cp \| cp \|^rm \|^[[:space:]]\+rm \| rm \|tasklist/I! s|./ThirdParty/VLC/x64/vlc.exe |flatpak run com.retro_exo.vlc |I' "$currentScript"
    sed -i -e '/^cp \|^[[:space:]]\+cp \| cp \|^rm \|^[[:space:]]\+rm \| rm \|tasklist/I! s|[\./]*eXo/util/VLC/vlc.exe |flatpak run com.retro_exo.vlc |I' "$currentScript"
    sed -i -e '/^cp \|^[[:space:]]\+cp \| cp \|^rm \|^[[:space:]]\+rm \| rm \|tasklist/I! s|[\./]*util/VLC/vlc.exe |flatpak run com.retro_exo.vlc |I' "$currentScript"
    
    #remove timeout commands
    sed -i -e '/^timeout /Id' "$currentScript"

#    #remove ! escapes from dosbox and wine commands
#    sed -i -e '/^dosbox\|^wine/s/\\\!/\!/g' "$currentScript"
    
    #point dosbox configuration references to Linux version
    sed -i -e '/_linux\.conf/I! s/\.conf/_linux.conf/Ig' "$currentScript"
#    sed -i -e '/^dosbox\(.*\) -conf/ s/\.conf/_linux.conf/g' "$currentScript"
#    sed -i -e '/^flatpak run com\.dosbox\(.*\) -conf/ s/\.conf/_linux.conf/g' "$currentScript"
#    sed -i -e '/^\${dosbox}\(.*\) -conf/ s/\.conf/_linux.conf/g' "$currentScript"
#    sed -i -e '/^conf=\(.*\)\.conf/ s/\.conf/_linux.conf/g' "$currentScript"
    sed -i -e '$!N;/dosbox=.*wine.*\nconf=.*_linux\.conf/ s/_linux\.conf/.conf/' "$currentScript"
    
    #point ANS files to Linux version
    sed -i -e '/_LIN\.ANS/! s/\.ANS/_LIN\.ANS/g' "$currentScript"
    
    #fix conditional cp statements
    sed -i -e 's|\&\& copy |\&\& cp |I' "$currentScript"

    #fix conditional mv commands
    sed -i -e 's/\&\& move /\&\& mv /I' "$currentScript"
    
    #fix conditional rm statements
    sed -i -e 's|\&\& del |\&\& rm |I' "$currentScript"
    sed -i -e 's/\&\& erase /\&\& rm /I' "$currentScript"
    
    #fix conditional rmdir statements
    sed -i -e 's|\&\& rd |\&\& rm -rf |I' "$currentScript"
    
    #fix conditional clear screen commands
    sed -i -e 's/\&\& cls/\&\& clear/I' "$currentScript"
    
    #fix conditional call to bash
    sed -i -e 's/\&\& call/\&\& source/I' "$currentScript"
    sed -i -e 's/\&\& source \(.*\)\.bat/\&\& source \1\.bsh/' "$currentScript"
    
    #indent for loop body
    sed -i -e '/^do$/,/^done/ {
                   s/^/    /;
                   s/^    do/do/;
                   s/^    done/done/;
               }' "$currentScript"
    sed -i -e '/^do.$/,/^done/ {
                   s/^/    /;
                   s/^    do/do/;
                   s/^    done/done/;
               }' "$currentScript"
               
    sed -i -e '/^[[:space:]]\+do$/,/^[[:space:]]\+done/ {
                   s/^\(^[[:space:]]\+\)/\1    /;
                   s/^\(^[[:space:]]\+\)    do/\1do/;
                   s/^\(^[[:space:]]\+\)    done/\1done/;
               }' "$currentScript"
    sed -i -e '/^[[:space:]]\+do.$/,/[[:space:]]\+^done/ {
                   s/^\(^[[:space:]]\+\)/\1    /;
                   s/^\(^[[:space:]]\+\)    do/\1do/;
                   s/^\(^[[:space:]]\+\)    done/\1done/;
               }' "$currentScript"
    
    #correct for loop condition
    sed -i -e "s|'dir /a:d /b'|*/|Ig" "$currentScript"
    
    #convert global ssr commands to sed
    sed -i -e "s/ssr 0 \([^ ]*\) \([^ ]*\) \"\(.*\)\"/sed -i -e \"s|\1|\2|g\" ######\3######/" \
        "$currentScript"
    sed -i -e "/sed/ s/\(######\)\(.*\)\\\!\(.*\)\(######\)/\1\2\"\\\!\"\3\4/g" \
        "$currentScript"
    perl -i -pE 's{(######.*?######)}{$1 =~ s/&/\\&/gr}eg' "$currentScript"
    sed -i -e "/sed/ s/######/\"/g" "$currentScript"
    sed -i -e "s#ssr 0 \([^ ]*\) \([^ ]*\) \(.*\)#sed -i -e \"s|\1|\2|g\" \3#" \
        "$currentScript"
    
    #fix remaining mv and cp statements
    sed -i -e 's/^\(^[[:space:]]\+\)move /\1mv /I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)copy /\1cp /I' "$currentScript"
    
    #escape & for cd, rm, mv, and cp commands
    sed -i -e "/^cd\|^cp\|^mv\|^rm/ {
                   s|\&\&|######|g;
                   s|\&|\\\&|g;
                   s|######|\&\&|g;
               }" "$currentScript"
    
    #change eXo tool calls to use Linux python scripts
    sed -i -e "s/^eXoLBpm\.exe /python3 eXoLBpm_linux.py /I" "$currentScript"
    sed -i -e "s/^eXoLBpm /python3 eXoLBpm_linux.py /I" "$currentScript"
    sed -i -e "s/&& eXoLBpm\.exe /\&\& python3 eXoLBpm_linux.py /I" "$currentScript"
    sed -i -e "s/&& eXoLBpm /\&\& python3 eXoLBpm_linux.py /I" "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)eXoLBpm\.exe /\1 python3 eXoLBpm_linux.py /I" "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)eXoLBpm /\1 python3 eXoLBpm_linux.py /I" "$currentScript"
    sed -i -e "s/^\(.[^[:space:]]*\)eXoLBpm\.exe /python3 \1eXoLBpm_linux.py /I" "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)\(.[^[:space:]]*\)eXoLBpm\.exe /\1python3 \2eXoLBpm_linux.py /I" "$currentScript"
    sed -i -e "s/&& \(.[^[:space:]]*\)eXoLBpm\.exe /\&\& python3 \1eXoLBpm_linux.py /I" "$currentScript"
    sed -i -e "s/^\(.[^[:space:]]*\)eXoLBpm\.exe\" /python3 \1eXoLBpm_linux.py\" /I" "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)\(.[^[:space:]]*\)eXoLBpm\.exe\" /\1python3 \2eXoLBpm_linux.py\" /I" "$currentScript"
    sed -i -e "s/&& \(.[^[:space:]]*\)eXoLBpm\.exe\" /\&\& python3 \1eXoLBpm_linux.py\" /I" "$currentScript"
    sed -i -e "s/^\(.[^[:space:]]*\)eXoLBpm /python3 \1eXoLBpm_linux.py /I" "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)\(.[^[:space:]]*\)eXoLBpm /\1python3 \2eXoLBpm_linux.py /I" "$currentScript"
    sed -i -e "s/&& \(.[^[:space:]]*\)eXoLBpm /\&\& python3 \1eXoLBpm_linux.py /I" "$currentScript"
    sed -i -e "s/^\(.[^[:space:]]*\)eXoLBpm\" /python3 \1eXoLBpm_linux.py\" /I" "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)\(.[^[:space:]]*\)eXoLBpm\" /\1python3 \2eXoLBpm_linux.py\" /I" "$currentScript"
    sed -i -e "s/&& \(.[^[:space:]]*\)eXoLBpm\" /\&\& python3 \1eXoLBpm_linux.py\" /I" "$currentScript"
    sed -i -e "s/eXoLBpm /eXoLBpm_linux.py /Ig" "$currentScript"
    sed -i -e "s/eXoLBpm\" /eXoLBpm_linux.py\" /Ig" "$currentScript"
    sed -i -e "s/eXoLBpm\.exe/eXoLBpm_linux.py/Ig" "$currentScript"
    #Timber replaced eXoLBXMLedit with eXoLPLBXMLedit
    #sed -i -e "s/^eXoLBXMLedit\.exe /python3 eXoLBXMLedit_linux.py /I" "$currentScript"
    #sed -i -e "s/^eXoLBXMLedit /python3 eXoLBXMLedit_linux.py /I" "$currentScript"
    #sed -i -e "s/&& eXoLBXMLedit\.exe /\&\& python3 eXoLBXMLedit_linux.py /I" "$currentScript"
    #sed -i -e "s/&& eXoLBXMLedit /\&\& python3 eXoLBXMLedit_linux.py /I" "$currentScript"
    #sed -i -e "s/^\([[:space:]]\+\)eXoLBXMLedit\.exe /\1 python3 eXoLBXMLedit_linux.py /I" "$currentScript"
    #sed -i -e "s/^\([[:space:]]\+\)eXoLBXMLedit /\1 python3 eXoLBXMLedit_linux.py /I" "$currentScript"
    #sed -i -e "s/^\(.[^[:space:]]*\)eXoLBXMLedit\.exe /python3 \1eXoLBXMLedit_linux.py /I" "$currentScript"
    #sed -i -e "s/^\([[:space:]]\+\)\(.[^[:space:]]*\)eXoLBXMLedit\.exe /\1python3 \2eXoLBXMLedit_linux.py /I" "$currentScript"
    #sed -i -e "s/&& \(.[^[:space:]]*\)eXoLBXMLedit\.exe /\&\& python3 \1eXoLBXMLedit_linux.py /I" "$currentScript"
    #sed -i -e "s/^\(.[^[:space:]]*\)eXoLBXMLedit\.exe\" /python3 \1eXoLBXMLedit_linux.py\" /I" "$currentScript"
    #sed -i -e "s/^\([[:space:]]\+\)\(.[^[:space:]]*\)eXoLBXMLedit\.exe\" /\1python3 \2eXoLBXMLedit_linux.py\" /I" "$currentScript"
    #sed -i -e "s/&& \(.[^[:space:]]*\)eXoLBXMLedit\.exe\" /\&\& python3 \1eXoLBXMLedit_linux.py\" /I" "$currentScript"
    #sed -i -e "s/^\(.[^[:space:]]*\)eXoLBXMLedit /python3 \1eXoLBXMLedit_linux.py /I" "$currentScript"
    #sed -i -e "s/^\([[:space:]]\+\)\(.[^[:space:]]*\)eXoLBXMLedit /\1python3 \2eXoLBXMLedit_linux.py /I" "$currentScript"
    #sed -i -e "s/&& \(.[^[:space:]]*\)eXoLBXMLedit /\&\& python3 \1eXoLBXMLedit_linux.py /I" "$currentScript"
    #sed -i -e "s/^\(.[^[:space:]]*\)eXoLBXMLedit\" /python3 \1eXoLBXMLedit_linux.py\" /I" "$currentScript"
    #sed -i -e "s/^\([[:space:]]\+\)\(.[^[:space:]]*\)eXoLBXMLedit\" /\1python3 \2eXoLBXMLedit_linux.py\" /I" "$currentScript"
    #sed -i -e "s/&& \(.[^[:space:]]*\)eXoLBXMLedit\" /\&\& python3 \1eXoLBXMLedit_linux.py\" /I" "$currentScript"
    #sed -i -e "s/eXoLBXMLedit /eXoLBXMLedit_linux.py /Ig" "$currentScript"
    #sed -i -e "s/eXoLBXMLedit\" /eXoLBXMLedit_linux.py\" /Ig" "$currentScript"
    #sed -i -e "s/eXoLBXMLedit\.exe/eXoLBXMLedit_linux.py/Ig" "$currentScript"
    sed -i -e "s/^eXoLPLBXMLedit\.exe /python3 eXoLPLBXMLedit_linux.py /I" "$currentScript"
    sed -i -e "s/^eXoLPLBXMLedit /python3 eXoLPLBXMLedit_linux.py /I" "$currentScript"
    sed -i -e "s/&& eXoLPLBXMLedit\.exe /\&\& python3 eXoLPLBXMLedit_linux.py /I" "$currentScript"
    sed -i -e "s/&& eXoLPLBXMLedit /\&\& python3 eXoLPLBXMLedit_linux.py /I" "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)eXoLPLBXMLedit\.exe /\1 python3 eXoLPLBXMLedit_linux.py /I" "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)eXoLPLBXMLedit /\1 python3 eXoLPLBXMLedit_linux.py /I" "$currentScript"
    sed -i -e "s/^\(.[^[:space:]]*\)eXoLPLBXMLedit\.exe /python3 \1eXoLPLBXMLedit_linux.py /I" "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)\(.[^[:space:]]*\)eXoLPLBXMLedit\.exe /\1python3 \2eXoLPLBXMLedit_linux.py /I" "$currentScript"
    sed -i -e "s/&& \(.[^[:space:]]*\)eXoLPLBXMLedit\.exe /\&\& python3 \1eXoLPLBXMLedit_linux.py /I" "$currentScript"
    sed -i -e "s/^\(.[^[:space:]]*\)eXoLPLBXMLedit\.exe\" /python3 \1eXoLPLBXMLedit_linux.py\" /I" "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)\(.[^[:space:]]*\)eXoLPLBXMLedit\.exe\" /\1python3 \2eXoLPLBXMLedit_linux.py\" /I" "$currentScript"
    sed -i -e "s/&& \(.[^[:space:]]*\)eXoLPLBXMLedit\.exe\" /\&\& python3 \1eXoLPLBXMLedit_linux.py\" /I" "$currentScript"
    sed -i -e "s/^\(.[^[:space:]]*\)eXoLPLBXMLedit /python3 \1eXoLPLBXMLedit_linux.py /I" "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)\(.[^[:space:]]*\)eXoLPLBXMLedit /\1python3 \2eXoLPLBXMLedit_linux.py /I" "$currentScript"
    sed -i -e "s/&& \(.[^[:space:]]*\)eXoLPLBXMLedit /\&\& python3 \1eXoLPLBXMLedit_linux.py /I" "$currentScript"
    sed -i -e "s/^\(.[^[:space:]]*\)eXoLPLBXMLedit\" /python3 \1eXoLPLBXMLedit_linux.py\" /I" "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)\(.[^[:space:]]*\)eXoLPLBXMLedit\" /\1python3 \2eXoLPLBXMLedit_linux.py\" /I" "$currentScript"
    sed -i -e "s/&& \(.[^[:space:]]*\)eXoLPLBXMLedit\" /\&\& python3 \1eXoLPLBXMLedit_linux.py\" /I" "$currentScript"
    sed -i -e "s/eXoLPLBXMLedit /eXoLPLBXMLedit_linux.py /Ig" "$currentScript"
    sed -i -e "s/eXoLPLBXMLedit\" /eXoLPLBXMLedit_linux.py\" /Ig" "$currentScript"
    sed -i -e "s/eXoLPLBXMLedit\.exe/eXoLPLBXMLedit_linux.py/Ig" "$currentScript"
    sed -i -e "s/^eXoLPPPM\.exe /python3 eXoLPPPM_linux.py /I" "$currentScript"
    sed -i -e "s/^eXoLPPPM /python3 eXoLPPPM_linux.py /I" "$currentScript"
    sed -i -e "s/&& eXoLPPPM\.exe /\&\& python3 eXoLPPPM_linux.py /I" "$currentScript"
    sed -i -e "s/&& eXoLPPPM /\&\& python3 eXoLPPPM_linux.py /I" "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)eXoLPPPM\.exe /\1 python3 eXoLPPPM_linux.py /I" "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)eXoLPPPM /\1 python3 eXoLPPPM_linux.py /I" "$currentScript"
    sed -i -e "s/^\(.[^[:space:]]*\)eXoLPPPM\.exe /python3 \1eXoLPPPM_linux.py /I" "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)\(.[^[:space:]]*\)eXoLPPPM\.exe /\1python3 \2eXoLPPPM_linux.py /I" "$currentScript"
    sed -i -e "s/&& \(.[^[:space:]]*\)eXoLPPPM\.exe /\&\& python3 \1eXoLPPPM_linux.py /I" "$currentScript"
    sed -i -e "s/^\(.[^[:space:]]*\)eXoLPPPM\.exe\" /python3 \1eXoLPPPM_linux.py\" /I" "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)\(.[^[:space:]]*\)eXoLPPPM\.exe\" /\1python3 \2eXoLPPPM_linux.py\" /I" "$currentScript"
    sed -i -e "s/&& \(.[^[:space:]]*\)eXoLPPPM\.exe\" /\&\& python3 \1eXoLPPPM_linux.py\" /I" "$currentScript"
    sed -i -e "s/^\(.[^[:space:]]*\)eXoLPPPM /python3 \1eXoLPPPM_linux.py /I" "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)\(.[^[:space:]]*\)eXoLPPPM /\1python3 \2eXoLPPPM_linux.py /I" "$currentScript"
    sed -i -e "s/&& \(.[^[:space:]]*\)eXoLPPPM /\&\& python3 \1eXoLPPPM_linux.py /I" "$currentScript"
    sed -i -e "s/^\(.[^[:space:]]*\)eXoLPPPM\" /python3 \1eXoLPPPM_linux.py\" /I" "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)\(.[^[:space:]]*\)eXoLPPPM\" /\1python3 \2eXoLPPPM_linux.py\" /I" "$currentScript"
    sed -i -e "s/&& \(.[^[:space:]]*\)eXoLPPPM\" /\&\& python3 \1eXoLPPPM_linux.py\" /I" "$currentScript"
    sed -i -e "s/eXoLPPPM /eXoLPPPM_linux.py /Ig" "$currentScript"
    sed -i -e "s/eXoLPPPM\" /eXoLPPPM_linux.py\" /Ig" "$currentScript"
    sed -i -e "s/eXoLPPPM\.exe/eXoLPPPM_linux.py/Ig" "$currentScript"
    
    #change restore.exe to restore.py
    sed -i -e "s|./exo/Update/restore.exe|./eXo/Update/restore.py|Ig" "$currentScript"
    sed -i -e "s|./exo/util/restore.exe|./eXo/util/restore.py|Ig" "$currentScript"
    sed -i -e "s|^./exo/Update/restore.py|python3 ./eXo/Update/restore.py|I" "$currentScript"
    sed -i -e "s|^./exo/util/restore.py|python3 ./eXo/util/restore.py|I" "$currentScript"
    sed -i -e "s|source ./exo/Update/restore.py|python3 ./eXo/Update/restore.py|I" "$currentScript"
    sed -i -e "s|source ./exo/util/restore.py|python3 ./eXo/util/restore.py|I" "$currentScript"
    sed -i -e "/util\.zip/ s/restore\.exe/restore.py/Ig" "$currentScript"
    sed -i -e "/restore\.py/ s/util\.zip/utilPENDINGAST.zip/" "$currentScript"
    
    #fix echo lines that already had quotes
    sed -i -e 's/echo "\\"\(.*\)\\""/echo "\1"/' "$currentScript"
    
    #fix % characters that were supposed to be present in echo text
    sed -i -e '/echo.*\$/s/\${}/%/' "$currentScript"
    
    #remove carriage return characters
    sed -i -e 's/\r//g' "$currentScript"
    
    #remove ctrl+z characters
    sed -i -e 's/\d26//g' "$currentScript"
    
    #remove trailing whitespace
    sed -i -e 's/[[:space:]\t]*$//' "$currentScript"
    
    #standardize choice usage convention
    sed -i -e '/^choice /s| /M "\(.*\)"| /N \1|' "$currentScript"
    sed -i -e '/^choice .* \/N /s| /M | |I' "$currentScript"
    sed -i -e '/^choice /s| /M | /N |I' "$currentScript"
    sed -i -e '/^choice /s| /N /N | /N |I' "$currentScript"
    sed -i -e '/^choice /s|choice /C |choice /C:|I' "$currentScript"
    
    #add better text output to common choice commands that lack it
    sed -i -e 's/^\(choice \/C:1234567890 \/N\)$/\1 Please choose (0-9):/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:1234567890\)$/\1 \/N Please choose (0-9):/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:123456789 \/N\)$/\1 Please choose (1-9):/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:123456789\)$/\1 \/N Please choose (1-9):/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:12345678 \/N\)$/\1 Please choose (1-8):/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:12345678\)$/\1 \/N Please choose (1-8):/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:1234567 \/N\)$/\1 Please choose (1-7):/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:1234567\)$/\1 \/N Please choose (1-7):/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:123456 \/N\)$/\1 Please choose (1-6):/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:123456\)$/\1 \/N Please choose (1-6):/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:12345 \/N\)$/\1 Please choose (1-5):/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:12345\)$/\1 \/N Please choose (1-5):/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:1234 \/N\)$/\1 Please choose (1-4):/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:1234\)$/\1 \/N Please choose (1-4):/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:123 \/N\)$/\1 Please choose (1-3):/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:123\)$/\1 \/N Please choose (1-3):/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:12 \/N\)$/\1 Please choose (1\/2):/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:12\)$/\1 \/N Please choose (1\/2):/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:YN \/N\)$/\1 [Y]es or [N]o:/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:YN\)$/\1 \/N [Y]es or [N]o:/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:NY \/N\)$/\1 [Y]es or [N]o:/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:NY\)$/\1 \/N [Y]es or [N]o:/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:FW \/N\)$/\1 Please choose (F\/W):/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:FW\)$/\1 \/N Please choose (F\/W):/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:LS \/N\)$/\1 Please choose (L\/S):/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:LS\)$/\1 \/N Please choose (L\/S):/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:LMS \/N\)$/\1 Please choose (L\/M\/S):/I' "$currentScript"
    sed -i -e 's/^\(choice \/C:LMS\)$/\1 \/N Please choose (L\/M\/S):/I' "$currentScript"
    
    #fix choice 15 items with note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?]\) \/N \(.*\)/while true\
do\
    read -p "\9 " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        STILLNEEDSPROCESSING \8\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)STILLNEEDSPROCESSING \([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)/\1[\2] ) errorlevel=8\
\1        break;;\
\1[\3] ) errorlevel=9\
\1        break;;\
\1[\4] ) errorlevel=10\
\1        break;;\
\1[\5] ) errorlevel=11\
\1        break;;\
\1[\6] ) errorlevel=12\
\1        break;;\
\1[\7] ) errorlevel=13\
\1        break;;\
\1[\8] ) errorlevel=14\
\1        break;;\
\1[\9] ) errorlevel=15\
\1        break;;/I' "$currentScript"

    #fix choice 14 items with note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?]\) \/N \(.*\)/while true\
do\
    read -p "\9 " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        STILLNEEDSPROCESSING \8\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)STILLNEEDSPROCESSING \([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)/\1[\2] ) errorlevel=8\
\1        break;;\
\1[\3] ) errorlevel=9\
\1        break;;\
\1[\4] ) errorlevel=10\
\1        break;;\
\1[\5] ) errorlevel=11\
\1        break;;\
\1[\6] ) errorlevel=12\
\1        break;;\
\1[\7] ) errorlevel=13\
\1        break;;\
\1[\8] ) errorlevel=14\
\1        break;;/I' "$currentScript"

    #fix choice 13 items with note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?]\) \/N \(.*\)/while true\
do\
    read -p "\9 " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        STILLNEEDSPROCESSING \8\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)STILLNEEDSPROCESSING \([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)/\1[\2] ) errorlevel=8\
\1        break;;\
\1[\3] ) errorlevel=9\
\1        break;;\
\1[\4] ) errorlevel=10\
\1        break;;\
\1[\5] ) errorlevel=11\
\1        break;;\
\1[\6] ) errorlevel=12\
\1        break;;\
\1[\7] ) errorlevel=13\
\1        break;;/I' "$currentScript"

    #fix choice 12 items with note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?]\) \/N \(.*\)/while true\
do\
    read -p "\9 " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        STILLNEEDSPROCESSING \8\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)STILLNEEDSPROCESSING \([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)/\1[\2] ) errorlevel=8\
\1        break;;\
\1[\3] ) errorlevel=9\
\1        break;;\
\1[\4] ) errorlevel=10\
\1        break;;\
\1[\5] ) errorlevel=11\
\1        break;;\
\1[\6] ) errorlevel=12\
\1        break;;/I' "$currentScript"

    #fix choice 11 items with note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?]\) \/N \(.*\)/while true\
do\
    read -p "\9 " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        STILLNEEDSPROCESSING \8\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)STILLNEEDSPROCESSING \([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)/\1[\2] ) errorlevel=8\
\1        break;;\
\1[\3] ) errorlevel=9\
\1        break;;\
\1[\4] ) errorlevel=10\
\1        break;;\
\1[\5] ) errorlevel=11\
\1        break;;/I' "$currentScript"
    
    #fix choice 10 items with note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?][[:alnum:]?][[:alnum:]?]\) \/N \(.*\)/while true\
do\
    read -p "\9 " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        STILLNEEDSPROCESSING \8\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)STILLNEEDSPROCESSING \([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)/\1[\2] ) errorlevel=8\
\1        break;;\
\1[\3] ) errorlevel=9\
\1        break;;\
\1[\4] ) errorlevel=10\
\1        break;;/I' "$currentScript"

    #fix choice 9 items with note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?][[:alnum:]?]\) \/N \(.*\)/while true\
do\
    read -p "\9 " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        STILLNEEDSPROCESSING \8\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)STILLNEEDSPROCESSING \([[:alnum:]?]\)\([[:alnum:]?]\)/\1[\2] ) errorlevel=8\
\1        break;;\
\1[\3] ) errorlevel=9\
\1        break;;/I' "$currentScript"

    #fix choice 8 items with note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\) \/N \(.*\)/while true\
do\
    read -p "\9 " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        [\8] ) errorlevel=8\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"

    #fix choice 7 items with note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\) \/N \(.*\)/while true\
do\
    read -p "\8 " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"

    #fix choice 6 items with note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\) \/N \(.*\)/while true\
do\
    read -p "\7 " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"

    #fix choice 5 items with note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\) \/N \(.*\)/while true\
do\
    read -p "\6 " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"

    #fix choice 4 items with note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\) \/N \(.*\)/while true\
do\
    read -p "\5 " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"

    #fix choice 3 items with note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\) \/N \(.*\)/while true\
do\
    read -p "\4 " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"

    #fix choice 2 items with note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\) \/N \(.*\)/while true\
do\
    read -p "\3 " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"

    #fix choice 15 items with empty note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?]\) \/N$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        [\8] ) errorlevel=8\
                break;;\
        STILLNEEDSPROCESSING \9\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)STILLNEEDSPROCESSING \([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)/\1[\2] ) errorlevel=9\
\1        break;;\
\1[\3] ) errorlevel=10\
\1        break;;\
\1[\4] ) errorlevel=11\
\1        break;;\
\1[\5] ) errorlevel=12\
\1        break;;\
\1[\6] ) errorlevel=13\
\1        break;;\
\1[\7] ) errorlevel=14\
\1        break;;\
\1[\8] ) errorlevel=15\
\1        break;;/' "$currentScript"

    #fix choice 14 items with empty note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?]\) \/N$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        [\8] ) errorlevel=8\
                break;;\
        STILLNEEDSPROCESSING \9\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)STILLNEEDSPROCESSING \([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)/\1[\2] ) errorlevel=9\
\1        break;;\
\1[\3] ) errorlevel=10\
\1        break;;\
\1[\4] ) errorlevel=11\
\1        break;;\
\1[\5] ) errorlevel=12\
\1        break;;\
\1[\6] ) errorlevel=13\
\1        break;;\
\1[\7] ) errorlevel=14\
\1        break;;/' "$currentScript"

    #fix choice 13 items with empty note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?]\) \/N$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        [\8] ) errorlevel=8\
                break;;\
        STILLNEEDSPROCESSING \9\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)STILLNEEDSPROCESSING \([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)/\1[\2] ) errorlevel=9\
\1        break;;\
\1[\3] ) errorlevel=10\
\1        break;;\
\1[\4] ) errorlevel=11\
\1        break;;\
\1[\5] ) errorlevel=12\
\1        break;;\
\1[\6] ) errorlevel=13\
\1        break;;/' "$currentScript"

    #fix choice 12 items with empty note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?]\) \/N$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        [\8] ) errorlevel=8\
                break;;\
        STILLNEEDSPROCESSING \9\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)STILLNEEDSPROCESSING \([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)/\1[\2] ) errorlevel=9\
\1        break;;\
\1[\3] ) errorlevel=10\
\1        break;;\
\1[\4] ) errorlevel=11\
\1        break;;\
\1[\5] ) errorlevel=12\
\1        break;;/' "$currentScript"

    #fix choice 11 items with empty note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?][[:alnum:]?][[:alnum:]?]\) \/N$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        [\8] ) errorlevel=8\
                break;;\
        STILLNEEDSPROCESSING \9\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)STILLNEEDSPROCESSING \([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)/\1[\2] ) errorlevel=9\
\1        break;;\
\1[\3] ) errorlevel=10\
\1        break;;\
\1[\4] ) errorlevel=11\
\1        break;;/' "$currentScript"

    #fix choice 10 items with empty note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?][[:alnum:]?]\) \/N$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        [\8] ) errorlevel=8\
                break;;\
        STILLNEEDSPROCESSING \9\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)STILLNEEDSPROCESSING \([[:alnum:]?]\)\([[:alnum:]?]\)/\1[\2] ) errorlevel=9\
\1        break;;\
\1[\3] ) errorlevel=10\
\1        break;;/' "$currentScript"

    #fix choice 9 items with empty note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\) \/N$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        [\8] ) errorlevel=8\
                break;;\
        [\9] ) errorlevel=9\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"

    #fix choice 8 items with empty note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\) \/N$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        [\8] ) errorlevel=8\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"

    #fix choice 7 items with empty note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\) \/N$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"

    #fix choice 6 items with empty note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\) \/N$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"

    #fix choice 5 items with empty note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\) \/N$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"

    #fix choice 4 items with empty note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\) \/N$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"

    #fix choice 3 items with empty note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\) \/N$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"

    #fix choice 2 items with empty note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\) \/N$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"

    #fix choice 15 items without note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?]\)$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        [\8] ) errorlevel=8\
                break;;\
        STILLNEEDSPROCESSING \9\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)STILLNEEDSPROCESSING \([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)/\1[\2] ) errorlevel=9\
\1        break;;\
\1[\3] ) errorlevel=10\
\1        break;;\
\1[\4] ) errorlevel=11\
\1        break;;\
\1[\5] ) errorlevel=12\
\1        break;;\
\1[\6] ) errorlevel=13\
\1        break;;\
\1[\7] ) errorlevel=14\
\1        break;;\
\1[\8] ) errorlevel=15\
\1        break;;/' "$currentScript"

    #fix choice 14 items without note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?]\)$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        [\8] ) errorlevel=8\
                break;;\
        STILLNEEDSPROCESSING \9\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)STILLNEEDSPROCESSING \([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)/\1[\2] ) errorlevel=9\
\1        break;;\
\1[\3] ) errorlevel=10\
\1        break;;\
\1[\4] ) errorlevel=11\
\1        break;;\
\1[\5] ) errorlevel=12\
\1        break;;\
\1[\6] ) errorlevel=13\
\1        break;;\
\1[\7] ) errorlevel=14\
\1        break;;/' "$currentScript"

    #fix choice 13 items without note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?]\)$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        [\8] ) errorlevel=8\
                break;;\
        STILLNEEDSPROCESSING \9\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)STILLNEEDSPROCESSING \([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)/\1[\2] ) errorlevel=9\
\1        break;;\
\1[\3] ) errorlevel=10\
\1        break;;\
\1[\4] ) errorlevel=11\
\1        break;;\
\1[\5] ) errorlevel=12\
\1        break;;\
\1[\6] ) errorlevel=13\
\1        break;;/' "$currentScript"

    #fix choice 12 items without note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?][[:alnum:]?][[:alnum:]?][[:alnum:]?]\)$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        [\8] ) errorlevel=8\
                break;;\
        STILLNEEDSPROCESSING \9\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)STILLNEEDSPROCESSING \([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)/\1[\2] ) errorlevel=9\
\1        break;;\
\1[\3] ) errorlevel=10\
\1        break;;\
\1[\4] ) errorlevel=11\
\1        break;;\
\1[\5] ) errorlevel=12\
\1        break;;/' "$currentScript"

    #fix choice 11 items without note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?][[:alnum:]?][[:alnum:]?]\)$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        [\8] ) errorlevel=8\
                break;;\
        STILLNEEDSPROCESSING \9\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)STILLNEEDSPROCESSING \([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)/\1[\2] ) errorlevel=9\
\1        break;;\
\1[\3] ) errorlevel=10\
\1        break;;\
\1[\4] ) errorlevel=11\
\1        break;;/' "$currentScript"

    #fix choice 10 items without note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?][[:alnum:]?]\)$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        [\8] ) errorlevel=8\
                break;;\
        STILLNEEDSPROCESSING \9\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)STILLNEEDSPROCESSING \([[:alnum:]?]\)\([[:alnum:]?]\)/\1[\2] ) errorlevel=9\
\1        break;;\
\1[\3] ) errorlevel=10\
\1        break;;/' "$currentScript"

    #fix choice 9 items without note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        [\8] ) errorlevel=8\
                break;;\
        [\9] ) errorlevel=9\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"

    #fix choice 8 items without note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        [\8] ) errorlevel=8\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"

    #fix choice 7 items without note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        [\7] ) errorlevel=7\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"

    #fix choice 6 items without note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        [\6] ) errorlevel=6\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"

    #fix choice 5 items without note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        [\5] ) errorlevel=5\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"

    #fix choice 4 items without note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        [\4] ) errorlevel=4\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"

    #fix choice 3 items without note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)\([[:alnum:]?]\)$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        [\3] ) errorlevel=3\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"

    #fix choice 2 items without note
    sed -i -e 's/^choice \/C:\([[:alnum:]?]\)\([[:alnum:]?]\)$/while true\
do\
    read -p "Please choose: " choice\
    case $choice in\
        [\1] ) errorlevel=1\
                break;;\
        [\2] ) errorlevel=2\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE/I' "$currentScript"
    
    #add case insensitivity to choices
    sed -i -e 's/\(\[\)\([[:alpha:]]\)\(\]\)\( ) errorlevel\)/\1\U\2\E\L\2\E\3*\4/I' "$currentScript"
    
    #fix choice Uninstall
    sed -i -e '/^choice Uninstall/Ic\
while true\
do\
    read -p "Uninstall (y\/n)? " choice\
    case $choice in\
        [Yy]* ) errorlevel=1\
                break;;\
        [Nn]* ) errorlevel=2\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE' "$currentScript"
    
    #fix choice
    sed -i -e '/^choice$/Ic\
while true\
do\
    read -p "(y\/n)? " choice\
    case $choice in\
        [Yy]* ) errorlevel=1\
                break;;\
        [Nn]* ) errorlevel=2\
                break;;\
        *     ) printf "Invalid input.\\n";;\
    esac\
TEMPDONECHOICE' "$currentScript"
    
    #call function for dynamic choices
    sed -i -e 's/^choice \/C:\(${[[:alnum:]_]\+}\) \/N \([[:space:]]*${[[:alnum:]_]\+}\)$/dynchoice \"\1\" \"\2\"/I' "$currentScript"
    
    #remove noconsole option for scummvm
    sed -i -e 's/ --no-console//' "$currentScript"

    #convert pause
    sed -i -e 's/^\([[:space:]]*\)pause$/\1read -s -n 1 -p "Press any key to continue..."\n\1printf "\\n\\n"/I' "$currentScript"
    sed -i -e 's/^\([[:space:]]*\)\(.*\)\( && \)pause$/\1\2\3read -s -n 1 -p "Press any key to continue..."\n\1printf "\\n\\n"/I' "$currentScript"
    sed -i -e 's/^\([[:space:]]*\)pause PENDINGTONULL$/\1read -s -n 1\n\1printf "\\n\\n"/I' "$currentScript"
    sed -i -e 's/^\([[:space:]]*\)\(.*\)\( && \)pause PENDINGTONULL$/\1\2\3read -s -n 1\n\1printf "\\n\\n"/I' "$currentScript"
    
    #add quotes to nested if exist / if not exist statements if not present (for consistency)
    sed -i -e "/^[[:space:]]\+if exist \"/I! \
               s/^\(^[[:space:]]\+\)if exist \([^ ]*\) rd \(.*\)/\1if exist \"\2\" rd \3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+if exist \"/I! \
               s/^\(^[[:space:]]\+\)if exist \([^ ]*\) unzip \(.*\)/\1if exist \"\2\" unzip \3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+if exist \"/I! \
               s/^\(^[[:space:]]\+\)if exist \([^\.]*\)\([^ ]*\)\(.*\)/\1if exist \"\2\3\"\4/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+pendingL3I exist \"/I! \
               s/^\(^[[:space:]]\+\)pendingL3I exist \([^\.]*\)\([^ ]*\)\(.*\)/\1pendingL3I exist \"\2\3\"\4/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+if not exist \"/I! \
               s/^\(^[[:space:]]\+\)if not exist \([^\.]*\)\([^ ]*\)\(.*\)/\1if not exist \"\2\3\"\4/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+if not exist \"/I! \
               s/^\(^[[:space:]]\+\)if not exist \([^ ]*\) unzip \(.*\)/\1if not exist \"\2\" unzip \3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+if not exist \"/! \
               s/^\(^[[:space:]]\+\)if not exist \([^\.]*\)\([^ ]*\)\(.*\)/\1if not exist \"\2\3\"\4/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+pendingL3I not exist \"/! \
               s/^\(^[[:space:]]\+\)pendingL3I not exist \([^\.]*\)\([^ ]*\)\(.*\)/\1pendingL3I not exist \"\2\3\"\4/" \
        "$currentScript"

    #fix nested if exist / if not exist statements (structure)
    sed -i -e "/^[[:space:]]\+if exist \"/I \
               s/^\(^[[:space:]]\+\)if exist \"\([^\"]*\)\"\(.*\)/\1[ -e \2 ] \&\&\3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+pendingL3I exist \"/I \
               s/^\(^[[:space:]]\+\)pendingL3I exist \"\([^\"]*\)\"\(.*\)/\1pendingL3I [ -e \2 ] \&\&\3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+if not exist \"/I \
               s/^\(^[[:space:]]\+\)if not exist \"\([^\"]*\)\"\(.*\)/\1[ ! -e \2 ] \&\&\3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+pendingL3I not exist \"/I \
               s/^\(^[[:space:]]\+\)pendingL3I not exist \"\([^\"]*\)\"\(.*\)/\1pendingL3I [ ! -e \2 ] \&\&\3/" \
        "$currentScript"

    #fix nested if numeric comparisons
    sed -i -e "s/^\([[:space:]]\+\)if \(.[^[:space:]]*\) gtr \(.[^[:space:]]*\) \(.*\)/\1[ \2 -gt \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)pendingL3I \(.[^[:space:]]*\) gtr \(.[^[:space:]]*\) \(.*\)/\1pendingL3I [ \2 -gt \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \(.[^[:space:]]*\) lss \(.[^[:space:]]*\) \(.*\)/\1[ \2 -lt \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)pendingL3I \(.[^[:space:]]*\) lss \(.[^[:space:]]*\) \(.*\)/\1pendingL3I [ \2 -lt \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \(.[^[:space:]]*\) equ \(.[^[:space:]]*\) \(.*\)/\1[ \2 -eq \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)pendingL3I \(.[^[:space:]]*\) equ \(.[^[:space:]]*\) \(.*\)/\1pendingL3I [ \2 -eq \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \(.[^[:space:]]*\) neq \(.[^[:space:]]*\) \(.*\)/\1[ \2 -ne \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)pendingL3I \(.[^[:space:]]*\) neq \(.[^[:space:]]*\) \(.*\)/\1pendingL3I [ \2 -ne \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \(.[^[:space:]]*\) leq \(.[^[:space:]]*\) \(.*\)/\1[ \2 -le \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)pendingL3I \(.[^[:space:]]*\) leq \(.[^[:space:]]*\) \(.*\)/\1pendingL3I [ \2 -le \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \(.[^[:space:]]*\) geq \(.[^[:space:]]*\) \(.*\)/\1[ \2 -ge \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)pendingL3I \(.[^[:space:]]*\) geq \(.[^[:space:]]*\) \(.*\)/\1pendingL3I [ \2 -ge \3 ] \&\& \4/I" \
        "$currentScript"
        
    #convert nested if errorlevel statements
    sed -i -e "/^[[:space:]]\+if errorlevel/ \
               s/^\([[:space:]]\+\)if \(errorlevel \)\(.[^[:space:]]*\)\(.*\)/\1[ $\2== \'\3\' ] \&\&\4/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+pendingL3I errorlevel/ \
               s/^\([[:space:]]\+\)pendingL3I \(errorlevel \)\(.[^[:space:]]*\)\(.*\)/\1pendingL3I [ $\2== \'\3\' ] \&\&\4/" \
        "$currentScript"
    
    #convert nested if variable comparison statements
    sed -i -e "s/^\([[:space:]]\+\)if not \"\(.[^[:space:]\"]*\)\"==\"\(.[^[:space:]\"]*\)\" \(.*\)/\1[ \2 != \"\3\" ] \&\& \4/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)pendingL3I not \"\(.[^[:space:]\"]*\)\"==\"\(.[^[:space:]\"]*\)\" \(.*\)/\1pendingL3I [ \2 != \"\3\" ] \&\& \4/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if not \"\(.[^[:space:]\"]*\)\"==\"\" \(.*\)/\1[ \2 != \"\" ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)pendingL3I not \"\(.[^[:space:]\"]*\)\"==\"\" \(.*\)/\1pendingL3I [ \2 != \"\" ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if not \"\(.[^[:space:]\"]*\)\" == \(.[^[:space:]]*\) \(.*\)/\1[ \2 != \3 ] \&\& \4/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)pendingL3I not \"\(.[^[:space:]\"]*\)\" == \(.[^[:space:]]*\) \(.*\)/\1pendingL3I [ \2 != \3 ] \&\& \4/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if not \(.[^[:space:]\"]*\) == \(.[^[:space:]]*\) \(.*\)/\1[ \2 != \3 ] \&\& \4/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)pendingL3I not \(.[^[:space:]\"]*\) == \(.[^[:space:]]*\) \(.*\)/\1pendingL3I [ \2 != \3 ] \&\& \4/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if not \(.[^[:space:]\"]*\)==\(.[^[:space:]]*\) \(.*\)/\1[ \2 != \3 ] \&\& \4/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)pendingL3I not \(.[^[:space:]\"]*\)==\(.[^[:space:]]*\) \(.*\)/\1pendingL3I [ \2 != \3 ] \&\& \4/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \"\(.[^[:space:]\"]*\)\"==\"\(.[^[:space:]\"]*\)\" \(.*\)/\1[ \2 == \"\3\" ] \&\& \4/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)pendingL3I \"\(.[^[:space:]\"]*\)\"==\"\(.[^[:space:]\"]*\)\" \(.*\)/\1pendingL3I [ \2 == \"\3\" ] \&\& \4/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \"\(.[^[:space:]\"]*\)\"==\"\" \(.*\)/\1[ \2 == \"\" ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)pendingL3I \"\(.[^[:space:]\"]*\)\"==\"\" \(.*\)/\1pendingL3I [ \2 == \"\" ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \"\(.[^[:space:]\"]*\)\" == \(.[^[:space:]]*\) \(.*\)/\1[ \2 == \3 ] \&\& \4/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)pendingL3I \"\(.[^[:space:]\"]*\)\" == \(.[^[:space:]]*\) \(.*\)/\1pendingL3I [ \2 == \3 ] \&\& \4/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \(.[^[:space:]\"]*\) == \(.[^[:space:]]*\) \(.*\)/\1[ \2 == \3 ] \&\& \4/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)pendingL3I \(.[^[:space:]\"]*\) == \(.[^[:space:]]*\) \(.*\)/\1pendingL3I [ \2 == \3 ] \&\& \4/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \(.[^[:space:]\"]*\)==\(.[^[:space:]]*\) \(.*\)/\1[ \2 == \3 ] \&\& \4/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)pendingL3I \(.[^[:space:]\"]*\)==\(.[^[:space:]]*\) \(.*\)/\1pendingL3I [ \2 == \3 ] \&\& \4/" \
        "$currentScript"
    
    #convert nested if varible existence checks
    sed -i -e "s/^\(^[[:space:]]\+\)if not defined \"%\(.[^[:space:]%\"]*\)\" /\1if not defined $\{\2\} /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)pendingL3I not defined \"%\(.[^[:space:]%\"]*\)\" /\1pendingL3I not defined $\{\2\} /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)if defined \"%\(.[^[:space:]%\"]*\)\" /\1if defined $\{\1\} /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)pendingL3I defined \"%\(.[^[:space:]%\"]*\)\" /\1pendingL3I defined $\{\1\} /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)if not defined %\(.[^[:space:]%\"]*\) /\1if not defined $\{\2\} /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)pendingL3I not defined %\(.[^[:space:]%\"]*\) /\1pendingL3I not defined $\{\2\} /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)if defined %\(.[^[:space:]%\"]*\) /\1if defined $\{\2\} /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)pendingL3I defined %\(.[^[:space:]%\"]*\) /\1pendingL3I defined $\{\2\} /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)if not defined \(.[^[:space:]]*\) \(.*\)/\1[ \2 = \"\" ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)pendingL3I not defined \(.[^[:space:]]*\) \(.*\)/\1pendingL3I [ \2 = \"\" ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)if defined \(.[^[:space:]]*\) \(.*\)/\1[ \2 != \"\" ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)pendingL3I defined \(.[^[:space:]]*\) \(.*\)/\1pendingL3I [ \2 != \"\" ] \&\& \3/" \
        "$currentScript"
    
    #Fix multi-line if (add beginning if)
    sed -i -e "/^\[.* && (\%$/ s/^/if /" "$currentScript"
    sed -i -e "/^\[.* && ($/ s/^/if /" "$currentScript"
    sed -i -e "/^\[.* && for.*($/ s/^/if /" "$currentScript"
    sed -i -e "/^\[.* && if.*/ s/^/if /" "$currentScript"
    sed -i -e "/^[[:space:]]\+\[.* && (\%$/ s/^\(^[[:space:]]\+\)/\1if /" "$currentScript"
    sed -i -e "/^[[:space:]]\+\[.* && ($/ s/^\(^[[:space:]]\+\)/\1if /" "$currentScript"
    sed -i -e "/^[[:space:]]\+\[.* && for.*($/ s/^\(^[[:space:]]\+\)/\1if /" "$currentScript"
    sed -i -e "/^[[:space:]]\+\[.* && if.*/ s/^\(^[[:space:]]\+\)/\1if /" "$currentScript"
        
    #Fix multi-line if (finish fixing declaration line, add then, phase 1)
    sed -i -e "s/\(^[[:space:]]\+\)\(.*\) && (\%$/\1\2\n\1PENDINGthen/" "$currentScript"
    sed -i -e "s/\(^[[:space:]]\+\)\(.*\) && ($/\1\2\n\1PENDINGthen/" "$currentScript"
    sed -i -e "s/\(^[[:space:]]\+\)\(.*\) && if \(.*\)/\1\2\n\1then\n\1    if \3\n\1fi/" "$currentScript"
    sed -i -e "s/ && (\%$/\nPENDINGthen/" "$currentScript"
    sed -i -e "s/ && ($/\nPENDINGthen/" "$currentScript"
    sed -i -e "s/ && if \(.*\)/\nthen\n    if \1\nfi/" "$currentScript"
    
    #indent if loop body
    sed -i -e '/^[[:space:]]\+PENDINGthen$/,/[[:space:]]\+PENDINGFI/ {
                   s/^\(^[[:space:]]\+\)/\1    /;
                   s/^\(^[[:space:]]\+\)    PENDINGthen/\1then/;
                   s/^\(^[[:space:]]\+\)    PENDINGFI/\1fi/;
               }' "$currentScript"
    sed -i -e '/^PENDINGthen$/,/^PENDINGFI/ {
                   s/^/    /;
                   s/^    PENDINGthen/then/;
                   s/^    PENDINGFI/fi/;
               }' "$currentScript"
    
    #fix else if conditions
    sed -i -e '/^[[:space:]]\+) else ($/,/[[:space:]]\+PENDINGFI/ {
                   s/^\(^[[:space:]]\+\)/\1    /;
                   s/^\(^[[:space:]]\+\)    ) else (/\1else/;
                   s/^\(^[[:space:]]\+\)    PENDINGFI/\1fi/;
               }' "$currentScript"
    sed -i -e '/^) else ($/,/PENDINGFI/ {
                   s/^/    /;
                   s/^    ) else (/else/;
                   s/^    PENDINGFI/fi/;
               }' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]*\)    ) else (/\1else/I' "$currentScript"
    
    sed -i -e "s/TEMPDONECHOICE/done/" "$currentScript"
    
    sed -i -e '/^PENDINGTLDBI/,/^done/ {
                   s/^/    /;
                   s/^    PENDINGTLDBI/do/;
                   s/^    done/done/;
               }' "$currentScript"
               
    #Note: PENDINGtBF is handled later in this script
    
    #add quotes to unhandled if exist / if not exist statements if not present (for consistency)
    sed -i -e "/^[[:space:]]\+if exist \"/I! \
               s/^\(^[[:space:]]\+\)if exist \([^ ]*\) rd \(.*\)/\1if exist \"\2\" rd \3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+if exist \"/I! \
               s/^\(^[[:space:]]\+\)if exist \([^ ]*\) unzip \(.*\)/\1if exist \"\2\" unzip \3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+if exist \"/I! \
               s/^\(^[[:space:]]\+\)if exist \([^\.]*\)\([^ ]*\)\(.*\)/\1if exist \"\2\3\"\4/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+pendingL3I exist \"/I! \
               s/^\(^[[:space:]]\+\)pendingL3I exist \([^\.]*\)\([^ ]*\)\(.*\)/\1pendingL3I exist \"\2\3\"\4/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+if not exist \"/I! \
               s/^\(^[[:space:]]\+\)if not exist \([^ ]*\) rd \(.*\)/\1if not exist \"\2\" rd \3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+if not exist \"/I! \
               s/^\(^[[:space:]]\+\)if not exist \([^ ]*\) unzip \(.*\)/\1if not exist \"\2\" unzip \3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+if not exist \"/! \
               s/^\(^[[:space:]]\+\)if not exist \([^\.]*\)\([^ ]*\)\(.*\)/\1if not exist \"\2\3\"\4/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+pendingL3I not exist \"/! \
               s/^\(^[[:space:]]\+\)pendingL3I not exist \([^\.]*\)\([^ ]*\)\(.*\)/\1pendingL3I not exist \"\2\3\"\4/" \
        "$currentScript"

    #fix unhandled if exist / if not exist statements (structure)
    sed -i -e "/^[[:space:]]\+if exist \"/I \
               s/^\(^[[:space:]]\+\)if exist \"\([^\"]*\)\"\(.*\)/\1[ -e \2 ] \&\&\3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+pendingL3I exist \"/I \
               s/^\(^[[:space:]]\+\)pendingL3I exist \"\([^\"]*\)\"\(.*\)/\1pendingL3I [ -e \2 ] \&\&\3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+if not exist \"/I \
               s/^\(^[[:space:]]\+\)if not exist \"\([^\"]*\)\"\(.*\)/\1[ ! -e \2 ] \&\&\3/" \
        "$currentScript"
    sed -i -e "/^[[:space:]]\+pendingL3I not exist \"/I \
               s/^\(^[[:space:]]\+\)pendingL3I not exist \"\([^\"]*\)\"\(.*\)/\1pendingL3I [ ! -e \2 ] \&\&\3/" \
        "$currentScript"

    #fix unhandled if numeric comparisons
    sed -i -e "s/^\([[:space:]]\+\)if \(.[^[:space:]]*\) gtr \(.[^[:space:]]*\) \(.*\)/\1[ \2 -gt \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \(.[^[:space:]]*\) lss \(.[^[:space:]]*\) \(.*\)/\1[ \2 -lt \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \(.[^[:space:]]*\) equ \(.[^[:space:]]*\) \(.*\)/\1[ \2 -eq \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \(.[^[:space:]]*\) neq \(.[^[:space:]]*\) \(.*\)/\1[ \2 -ne \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \(.[^[:space:]]*\) leq \(.[^[:space:]]*\) \(.*\)/\1[ \2 -le \3 ] \&\& \4/I" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \(.[^[:space:]]*\) geq \(.[^[:space:]]*\) \(.*\)/\1[ \2 -ge \3 ] \&\& \4/I" \
        "$currentScript"
        
    #convert unhandled if errorlevel statements
    sed -i -e "/^[[:space:]]\+if errorlevel/ \
               s/^\([[:space:]]\+\)if \(errorlevel \)\(.[^[:space:]]*\)\(.*\)/\1[ $\2== \'\3\' ] \&\&\4/" \
        "$currentScript"
    
    #convert unhandled if variable comparison statements
    sed -i -e "s/^\([[:space:]]\+\)if not \"\(.[^[:space:]\"]*\)\"==\"\(.[^[:space:]\"]*\)\" \(.*\)/\1[ \2 != \"\3\" ] \&\& \4/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if not \"\(.[^[:space:]\"]*\)\"==\"\" \(.*\)/\1[ \2 != \"\" ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if not \"\(.[^[:space:]\"]*\)\" == \(.[^[:space:]]*\) \(.*\)/\1[ \2 != \3 ] \&\& \4/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if not \(.[^[:space:]\"]*\) == \(.[^[:space:]]*\) \(.*\)/\1[ \2 != \3 ] \&\& \4/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if not \(.[^[:space:]\"]*\)==\(.[^[:space:]]*\) \(.*\)/\1[ \2 != \3 ] \&\& \4/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \"\(.[^[:space:]\"]*\)\"==\"\(.[^[:space:]\"]*\)\" \(.*\)/\1[ \2 == \"\3\" ] \&\& \4/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \"\(.[^[:space:]\"]*\)\"==\"\" \(.*\)/\1[ \2 == \"\" ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \"\(.[^[:space:]\"]*\)\" == \(.[^[:space:]]*\) \(.*\)/\1[ \2 == \3 ] \&\& \4/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \(.[^[:space:]\"]*\) == \(.[^[:space:]]*\) \(.*\)/\1[ \2 == \3 ] \&\& \4/" \
        "$currentScript"
    sed -i -e "s/^\([[:space:]]\+\)if \(.[^[:space:]\"]*\)==\(.[^[:space:]]*\) \(.*\)/\1[ \2 == \3 ] \&\& \4/" \
        "$currentScript"
    
    #convert unhandled if varible existence checks
    sed -i -e "s/^\(^[[:space:]]\+\)if not defined \"%\(.[^[:space:]%\"]*\)\" /\1if not defined $\{\2\} /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)if defined \"%\(.[^[:space:]%\"]*\)\" /\1if defined $\{\1\} /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)if not defined %\(.[^[:space:]%\"]*\) /\1if not defined $\{\2\} /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)if defined %\(.[^[:space:]%\"]*\) /\1if defined $\{\2\} /" "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)if not defined \(.[^[:space:]]*\) \(.*\)/\1[ \2 = \"\" ] \&\& \3/" \
        "$currentScript"
    sed -i -e "s/^\(^[[:space:]]\+\)if defined \(.[^[:space:]]*\) \(.*\)/\1[ \2 != \"\" ] \&\& \3/" \
        "$currentScript"
    
    #change scummvm application directory references
    sed -i -e 's|\${userprofile}/AppData/Roaming/ScummVM|~/.local/share/scummvm|' "$currentScript"
    
    #add current directory to unzip commands lacking a destination
    sed -i -e '/^unzip.*-d$\|^[[:space:]]\+unzip.*-d$\|\&\& unzip.*-d$/s|$| ./|' "$currentScript"
    
    #convert gamedir declaration
    sed -i -e 's|\${\~}nxI|\$\{PWD##*/\}|' "$currentScript"
    
    #convert gamename2 declaration loop
    sed -i -e 's/*\^)/*\\)/' "$currentScript"
    
    #convert gamename declaration
    sed -i -e 's/gamename=\$gamename2.*/gamename=\$\{gamename2%.bsh\}/' "$currentScript"
    
    #fix variable expansion instances
    
    #convert ~0,-[##] declarations
    sed -i -e 's/\(.[^[:space:]\"~=]*\)=\${\(.[^[:space:]\"~=]*\):~0,-\([[:digit:]]\+\)}/\1=\$\{\2::-\3\}/g' "$currentScript"
    sed -i -e 's/"\(.[^[:space:]\"~=]*\)=\(\${.[^[:space:]\"~=]*::-[[:digit:]]\+}\)"/\1=\2/g' "$currentScript"
    
    #convert ~0,-[##] declarations that use delayed expansion
    sed -i -e 's/\(.[^[:space:]\"~=]*\)=\\\!\(.[^[:space:]\"~=]*\):~0,-\([[:digit:]]\+\)\\\!/\1=\$\{\2::-\3\}/g' "$currentScript"
    
    #convert ~0,[##] declarations
    sed -i -e 's/\(.[^[:space:]\"~=]*\)=\${\(.[^[:space:]\"~=]*\):~0,\([[:digit:]]\+\)}/\1=\$\{\2::\3\}/g' "$currentScript"
    sed -i -e 's/"\(.[^[:space:]\"~=]*\)=\(\${.[^[:space:]\"~=]*::[[:digit:]]\+}\)"/\1=\2/g' "$currentScript"
    
    #convert ~0,[##] declarations that use delayed expansion
    sed -i -e 's/\(.[^[:space:]\"~=]*\)=\\\!\(.[^[:space:]\"~=]*\):~0,\([[:digit:]]\+\)\\\!/\1=\$\{\2::\3\}/g' "$currentScript"
    
    #convert :* = declarations
    sed -i -e 's/"\(.[^[:space:]\"~=]*\)=%\(.[^[:space:]\"~=%]*\):\* =%"/\1=\$\{\2#* \}/g' "$currentScript"
    
    #convert :*:= declarations
    sed -i -e 's/\(.[^[:space:]\"~=]*\)=\${\(.[^[:space:]\"~=]*\):\*:=}/\1=\$\{\2#*:\}/g' "$currentScript"
    sed -i -e 's/"\(.[^[:space:]\"~=]*\)=\(\${.[^[:space:]\"~=]*#\*:}\)"/\1=\2/g' "$currentScript"
    
    #convert :*/= declarations
    sed -i -e 's|\(.[^[:space:]\"~=]*\)=\${\(.[^[:space:]\"~=]*\):\*/=}|\1=\$\{\2#*/\}|g' "$currentScript"
    sed -i -e 's|"\(.[^[:space:]\"~=]*\)=\(\${.[^[:space:]\"~=]*#\*/}\)"|\1=\2|g' "$currentScript"
    
    #convert :*:= declarations that use delayed expansion
    sed -i -e 's/\(.[^[:space:]\"~=]*\)=\\\!\(.[^[:space:]\"~=]*\):\*:=\\\!/\1=\$\{\2#*:\}/g' "$currentScript"
    
    #convert :*/= declarations that use delayed expansion
    sed -i -e 's|\(.[^[:space:]\"~=]*\)=\\\!\(.[^[:space:]\"~=]*\):\*/=\\\!|\1=\$\{\2#*/\}|g' "$currentScript"

    #convert ~[##],-[##] declarations
    sed -i -e 's/\(.[^[:space:]\"~=]*\)=\${\(.[^[:space:]\"~=]*\):~\([[:digit:]]\+\),-\([[:digit:]]\+\)}/\1=\$\{\2:\3:-\4\}/g' "$currentScript"
    sed -i -e 's/"\(.[^[:space:]\"~=]*\)=\(\${.[^[:space:]\"~=]*:[[:digit:]]\+:-[[:digit:]]\+}\)"/\1=\2/g' "$currentScript"
    
    #convert ~[##],-[##] declarations that use delayed expansion
    sed -i -e 's/\(.[^[:space:]\"~=]*\)=\\\!\(.[^[:space:]\"~=]*\):~\([[:digit:]]\+\),-\([[:digit:]]\+\)\\\!/\1=\$\{\2:\3:-\4\}/g' "$currentScript"
    
    #convert ~[##],[##] declarations
    sed -i -e 's/\(.[^[:space:]\"~=]*\)=\${\(.[^[:space:]\"~=]*\):~\([[:digit:]]\+\),\([[:digit:]]\+\)}/\1=\$\{\2:\3:\4\}/g' "$currentScript"
    sed -i -e 's/"\(.[^[:space:]\"~=]*\)=\(\${.[^[:space:]\"~=]*:[[:digit:]]\+:[[:digit:]]\+}\)"/\1=\2/g' "$currentScript"
    
    #convert ~[##],[##] declarations that use delayed expansion
    sed -i -e 's/\(.[^[:space:]\"~=]*\)=\\\!\(.[^[:space:]\"~=]*\):~\([[:digit:]]\+\),\([[:digit:]]\+\)\\\!/\1=\$\{\2:\3:\4\}/g' "$currentScript"
    
    #convert ~[##] declarations
    sed -i -e 's/\(.[^[:space:]\"~=]*\)=\${\(.[^[:space:]\"~=]*\):~\([[:digit:]]\+\)}/\1=\$\{\2:\3\}/g' "$currentScript"
    sed -i -e 's/"\(.[^[:space:]\"~=]*\)=\(\${.[^[:space:]\"~=]*:[[:digit:]]\+}\)"/\1=\2/g' "$currentScript"

    #convert ~[##] declarations that use delayed expansion
    sed -i -e 's/\(.[^[:space:]\"~=]*\)=\\\!\(.[^[:space:]\"~=]*\):~\([[:digit:]]\+\)\\\!/\1=\$\{\2:\3\}/g' "$currentScript"
    
    #convert ~-[##] declarations
    sed -i -e 's/\(.[^[:space:]\"~=]*\)=\${\(.[^[:space:]\"~=]*\):~-\([[:digit:]]\+\)}/\1=\$\{\2: -\3\}/g' "$currentScript"
    sed -i -e 's/"\(.[^[:space:]\"~=]*\)=\(\${.[^[:space:]\"~=]*: -[[:digit:]]\+}\)"/\1=\2/g' "$currentScript"

    #convert ~-[##] declarations that use delayed expansion
    sed -i -e 's/\(.[^[:space:]\"~=]*\)=\\\!\(.[^[:space:]\"~=]*\):~-\([[:digit:]]\+\)\\\!/\1=\$\{\2: -\3\}/g' "$currentScript"
    
    sed -i -e "s/\"'\!'\"\([^[:space:]]\+\)\"'\!'\"/DELAYEDVARECHBEG\"\$\{\1\}\"DELAYEDVARECHEND/g" "$currentScript"
    
    #convert quoted substring reference of existing variable with ~0,-[##]
    sed -i -e 's/\"\${\(.[^[:space:]\"~=]*\):~0,-\([[:digit:]]\+\)}\"/\$\{\1::-\2\}/g' "$currentScript"
    
    #convert quoted substring reference of existing variable with ~,[##]
    sed -i -e 's/\"\${\(.[^[:space:]\"~=]*\):~0,\([[:digit:]]\+\)}\"/\$\{\1::\2\}/g' "$currentScript"
    
    #convert quoted substring reference of existing variable with :*:=
    sed -i -e 's/\"\${\(.[^[:space:]\"~=]*\):\*:=}\"/\$\{\1#*:\}/g' "$currentScript"
    
    #convert quoted substring reference of existing variable with ~[##],-[##] declarations
    sed -i -e 's/\"\${\(.[^[:space:]\"~=]*\):~\([[:digit:]]\+\),-\([[:digit:]]\+\)}\"/\$\{\1:\2:-\3\}/g' "$currentScript"
    
    #convert quoted substring reference of existing variable with ~[##],[##] declarations
    sed -i -e 's/\"\${\(.[^[:space:]\"~=]*\):~\([[:digit:]]\+\),\([[:digit:]]\+\)}\"/\$\{\1:\2:\3\}/g' "$currentScript"
    
    #convert quoted substring reference of existing variable with ~[##] declarations
    sed -i -e 's/\"\${\(.[^[:space:]\"~=]*\):~\([[:digit:]]\+\)}\"/\$\{\1:\2\}/g' "$currentScript"
    
    #convert quoted substring reference of existing variable with ~-[##] declarations
    sed -i -e 's/\"\${\(.[^[:space:]\"~=]*\):~-\([[:digit:]]\+\)}\"/\$\{\1: -\2\}/g' "$currentScript"
    
    #finish fixing DelayedExpansion references
    sed -i -e 's/DELAYEDVARBEG\([[:alnum:]_]\+\)DELAYEDVAREND/\$\{\L\1\E\}/Ig' "$currentScript"
    sed -i -e 's/DELAYEDVARECHBEG//g' "$currentScript"
    sed -i -e 's/DELAYEDVARECHEND//g' "$currentScript"
    
    #remove quotes from comparison statements
    sed -i -e "s/\[ \"\([^\"]*\)\" == \(.*\) \]/[ \1 == \2 ]/" "$currentScript"
    sed -i -e "s/\[ \"\([^\"]*\)\" != \(.*\) \]/[ \1 != \2 ]/" "$currentScript"
    sed -i -e "s/\[ \"\([^\"]*\)\" -gt \(.*\) \]/[ \1 -gt \2 ]/" "$currentScript"
    sed -i -e "s/\[ \"\([^\"]*\)\" -lt \(.*\) \]/[ \1 -lt \2 ]/" "$currentScript"
    sed -i -e "s/\[ \"\([^\"]*\)\" -eq \(.*\) \]/[ \1 -eq \2 ]/" "$currentScript"
    sed -i -e "s/\[ \"\([^\"]*\)\" -ne \(.*\) \]/[ \1 -ne \2 ]/" "$currentScript"
    sed -i -e "s/\[ \"\([^\"]*\)\" -le \(.*\) \]/[ \1 -le \2 ]/" "$currentScript"
    sed -i -e "s/\[ \"\([^\"]*\)\" -ge \(.*\) \]/[ \1 -ge \2 ]/" "$currentScript"
    
    #fix variable declarations that trim other variables
    sed -i -e "s|^source set \([[:alnum:]_]\+\)=%%\([[:alnum:]_]\+\):%\([[:alnum:]_]\+\)%=%%|\L\1\E=\"\$(printf \'%s\\\n\' \"\$\{\L\2\E//\$\L\3\E\}\")\"|I" "$currentScript"
    
    #remove $ from for loop declarations
    sed -i -e 's/^for \(.*\) \${\(.*\)} in /for \1 \2 in /' "$currentScript"
    sed -i -e 's/^for \${\(.*\)} in /for \1 in /' "$currentScript"

    sed -i -e 's/^\(^[[:space:]]\+\)for \(.*\) \${\(.*\)} in /\1for \2 \3 in /' "$currentScript"
    sed -i -e 's/^\(^[[:space:]]\+\)for \${\(.*\)} in /\1for \2 in /' "$currentScript"
    
    #make for loop variable lowercase
    sed -i -e '/for \/r/I! s/^for .* in /\L&/' "$currentScript"
    sed -i -e '/for \/r/I! s/^[[:space:]]\+for .* in /\L&/' "$currentScript"
    sed -i -e '/for \/r/I s/%%. in /\L&/' "$currentScript"
    
    #convert size declaration
    sed -i -e 's/size=\${\~}zG/[ -e "\$g" ] \&\& size=`stat -c\%s "\$g"` || size="0"/' "$currentScript"
    
    #convert aria2c process check
    sed -i -e 's/^tasklist.*IMAGENAME.*aria2c.*find.*aria2c.*/[[ "\$\(ps -e | grep aria2c | wc -l\)" -gt 0 ]] \&\& errorlevel=0 || errorlevel=1/' "$currentScript"
    
    #convert generic process check
    sed -i -e 's/PENDINGEXECHECK/\"\$(ps -e | grep \"\$exe\" | wc -l)\"/' "$currentScript"
    
    #fix trim assignment
    sed -i -e "s|^trim=\"Update/|trim=Update|" "$currentScript"
    
#    #add back -o option to all unzip commands
#    sed -i -e 's/unzip /unzip -o /I' "$currentScript"
        
    #remove quotes from unzip commands
    sed -i -e "/unzip -o \"/s/\(unzip -o \)\"\(.[^[:space:]\"]*\)\"\( -d \)\"\(.[^[:space:]\"]*\)\"/\1\2\3\4/" \
        "$currentScript"
    sed -i -e "/unzip -o \"/s/\(unzip -o \)\"\(.[^[:space:]\"]*\)\"\( -d \)\(.[^[:space:]\"]*\)/\1\2\3\4/" \
        "$currentScript"
    sed -i -e "/unzip -o \"/s/\(unzip -o \)\"\(.[^[:space:]\"]*\)\"/\1\2/" \
        "$currentScript"
    sed -i -e "/unzip -o /s/\(unzip -o \)\(.[^[:space:]\"]*\)\( -d \)\"\(.[^[:space:]\"]*\)\"/\1\2\3\4/" \
        "$currentScript"
    sed -i -e "/unzip -n \"/s/\(unzip -n \)\"\(.[^[:space:]\"]*\)\"\( -d \)\"\(.[^[:space:]\"]*\)\"/\1\2\3\4/" \
        "$currentScript"
    sed -i -e "/unzip -n \"/s/\(unzip -n \)\"\(.[^[:space:]\"]*\)\"\( -d \)\(.[^[:space:]\"]*\)/\1\2\3\4/" \
        "$currentScript"
    sed -i -e "/unzip -n \"/s/\(unzip -n \)\"\(.[^[:space:]\"]*\)\"/\1\2/" \
        "$currentScript"
    sed -i -e "/unzip -n /s/\(unzip -n \)\(.[^[:space:]\"]*\)\( -d \)\"\(.[^[:space:]\"]*\)\"/\1\2\3\4/" \
        "$currentScript"
    
    #convert DOSBox variable references
    sed -i -e "s|^dosbox=\"dosbox/dosbox\.exe\"|dosbox=\"flatpak run com.retro_exo.dosbox-074r3-1\"|I" "$currentScript"
    sed -i -e "s|^dosbox=\"dosbox\.exe\"|dosbox=\"flatpak run com.retro_exo.dosbox-074r3-1\"|I" "$currentScript"
    sed -i -e "s|^dosbox=\"dosbox/074r3/dosbox\.exe\"|dosbox=\"flatpak run com.retro_exo.dosbox-074r3-1\"|I" "$currentScript"
    sed -i -e "s|^dosbox=\"dosbox/dosboxsvn\.exe\"|dosbox=\"flatpak run com.retro_exo.dosbox-ece-r4301\"|I" "$currentScript"
    sed -i -e "s|^dosbox=\"DWDdosbox/dosbox\.exe\"|dosbox=\"flatpak run com.retro_exo.dosbox-gridc-4-3-1\"|I" "$currentScript"
    sed -i -e "s|^dosbox=\"dosbox/ece/dosbox\.exe\"|dosbox=\"flatpak run com.retro_exo.dosbox-ece-r4301\"|I" "$currentScript"
    sed -i -e "s|^dosbox=\"ece4230/dosbox\.exe\"|dosbox=\"flatpak run com.retro_exo.dosbox-ece-r4301\"|I" "$currentScript"
    sed -i -e "s|^dosbox=\"dosbox/ece_svn/dosbox\.exe\"|dosbox=\"flatpak run com.retro_exo.dosbox-ece-r4482\"|I" "$currentScript"
    sed -i -e "s|^dosbox=\"ece4460/dosbox\.exe\"|dosbox=\"flatpak run com.retro_exo.dosbox-ece-r4482\"|I" "$currentScript"
    sed -i -e "s|^dosbox=\"ece4481/dosbox\.exe\"|dosbox=\"flatpak run com.retro_exo.dosbox-ece-r4482\"|I" "$currentScript"
    sed -i -e "s|^dosbox=\"dosbox/x/dosbox\.exe\"|dosbox=\"flatpak run com.retro_exo.dosbox-x-08220\"|I" "$currentScript"
    sed -i -e "s|^dosbox=\"dosbox/x/dosbox\.exe\"|dosbox=\"flatpak run com.retro_exo.dosbox-x-08220\"|I" "$currentScript"
    sed -i -e "s|^dosbox=\"x/dosbox\.exe\"|dosbox=\"flatpak run com.retro_exo.dosbox-x-08220\"|I" "$currentScript"
    sed -i -e "s|^dosbox=\"x2/dosbox\.exe\"|dosbox=\"flatpak run com.retro_exo.dosbox-x-20240701\"|I" "$currentScript"
    sed -i -e "s|^dosbox=\"staging0\.82\.0/dosbox\.exe\"|dosbox=\"flatpak run com.retro_exo.dosbox-staging-082-0\"|I" "$currentScript"
    sed -i -e "s|^dosbox=\"staging0\.81\.2/dosbox\.exe\"|dosbox=\"flatpak run com.retro_exo.dosbox-staging-081-2\"|I" "$currentScript"
    sed -i -e "s|^dosbox=\"staging0\.81\.1/dosbox\.exe\"|dosbox=\"flatpak run com.retro_exo.dosbox-staging-081-2\"|I" "$currentScript"
    sed -i -e "s|^dosbox=\"staging0\.81\.0a/dosbox\.exe\"|dosbox=\"flatpak run com.retro_exo.dosbox-staging-081-2\"|I" "$currentScript"
    sed -i -e "s|^dosbox=\"staging0\.80\.1/dosbox\.exe\"|dosbox=\"flatpak run com.retro_exo.dosbox-staging-081-2\"|I" "$currentScript"
    sed -i -e '/dosbox=".*dosbox\.exe"/I {
                   /flatpak run com\.retro_exo\.wine/! s/^dosbox="/dosbox="flatpak run com.retro_exo.wine /I;
                }' "$currentScript"
    # Note: DAUM conversion disabled due to Linux bugs and lack of Direct3D support; Wine used instead
    # Note: alt launcher dosbox variable fix occurs later in this script
    
    #have OpenUHS run through flatpak
    sed -i -e 's|^[\./]*OpenUHS "|flatpak run com.retro_exo.OpenUHS "\$PWD/|I' "$currentScript"
    sed -i -e 's|^[\./]*OpenUHS\.exe "|flatpak run com.retro_exo.OpenUHS "\$PWD/|I' "$currentScript"
    sed -i -e 's|^\([[:space:]]\+\)[\./]*OpenUHS "|flatpak run com.retro_exo.OpenUHS "\$PWD/|I' "$currentScript"
    sed -i -e 's|^\([[:space:]]\+\)[\./]*OpenUHS\.exe "|flatpak run com.retro_exo.OpenUHS "\$PWD/|I' "$currentScript"
    sed -i -e 's|^\([[:space:]]\+\)[\./]*openuhs/OpenUHS "|flatpak run com.retro_exo.OpenUHS "\$PWD/|I' "$currentScript"
    sed -i -e 's|^\([[:space:]]\+\)[\./]*openuhs/OpenUHS\.exe "|flatpak run com.retro_exo.OpenUHS "\$PWD/|I' "$currentScript"
    sed -i -e 's|^\([[:space:]]\+\)[\./]*util/openuhs/OpenUHS "|flatpak run com.retro_exo.OpenUHS "\$PWD/|I' "$currentScript"
    sed -i -e 's|^\([[:space:]]\+\)[\./]*util/openuhs/OpenUHS\.exe "|flatpak run com.retro_exo.OpenUHS "\$PWD/|I' "$currentScript"
    
    #have foobar2000.exe run through Wine
    sed -i -e 's|^\([^[:space:]]\+foobar2000.exe \)|flatpak run com.retro_exo.wine \1|' "$currentScript"
    
    #convert PowerShell download commands
    sed -i -e "s|powershell -command.*DownloadFile('\(.*\)', '\(.*\)').*|wget \"\1\" -O \2|I" "$currentScript"
    
    #convert PowerShell sleep commands
    sed -i -e "s/powershell -command Start-Sleep -s/sleep/I" "$currentScript"
    
    #convert fc to diff
    sed -i -e "s|^fc \(.*\)|diff --strip-trailing-cr \1 > /dev/null\nerrorlevel=\"\$?\"|" "$currentScript"
    sed -i -e "s|\(^[[:space:]]\+\)fc \(.*\)|\1diff --strip-trailing-cr \2 > /dev/null\n\1errorlevel=\"\$?\"|" "$currentScript"
    
    #convert type commands to cat
    sed -i -e "s/^type \(.*\)/cat \1/I" "$currentScript"
    sed -i -e "s/&& type /\&\& cat /I" "$currentScript"
    sed -i -e 's/\(^[[:space:]]\+\)type /\1type /I' "$currentScript"
        
    #fix function calls
    sed -i -e '/^: proces.*$/,/^$/ {
                   s/^/    /;
                   s/^    : \(proces.*\)/function \1\n\{/;
                   s/^    $/\}\n\n/;
               }' "$currentScript"
    sed -i -e '/^: getsize$/,/^$/ {
                   s/^/    /;
                   s/^    : \(getsize\)/function \1\n\{/;
                   s/^    $/\}\n\n/;
               }' "$currentScript"
    sed -i -e '/^: correctbpversion/,/^exit \/b.*$/I {
                   s/^/    /;
                   s/^    : \(correctbpversion\)/function \1\n\{/;
                   s|^\(    exit /b.*\)|\1\n\}\n\n|I;
               }' "$currentScript"
    sed -i -e '/^: compareversions .*/,/^$/ {
                   s/^/    /;
                   s/^    : \(compareversions\) \(.*\)/function \1 #\2\n\{/;
                   s/^    $/\}\n\n/;
               }' "$currentScript"
    sed -i -e '/^: [[:alnum:]]\+ .*/,/^exit \/b.*$/I {
                   s/^/    /;
                   s/^    : \([[:alnum:]]\+\) \(.*\)/function \1 #\2\n\{/;
                   s|^\(    exit /b.*\)|\1\n\}\n\n|I;
               }' "$currentScript"
    sed -i -e '/^function.*$/,/^}$/ {
                   s/parameterone/1/g;
                   s/parametertwo/2/g;
                   s/parameterthree/3/g;
                   s/parameterfour/4/g;
               }' "$currentScript"
    
    #move functions to the beginning of the script if present (this only attempts four functions)
    if grep -q "^function " "$currentScript"
    then
        ed "$currentScript" <<EOF &>/dev/null
\$
?^function .*\$?-1
/^function .*\$/,/^\}\$/m0
\$
?^function .*\$?-1
/^function .*\$/,/^\}\$/m0
\$
?^function .*\$?-1
/^function .*\$/,/^\}\$/m0
\$
?^function .*\$?-1
/^function .*\$/,/^\}\$/m0
\$
?^function .*\$?-1
/^function .*\$/,/^\}\$/m0
\$
?^function .*\$?-1
/^function .*\$/,/^\}\$/m0
wq
EOF
    fi
    
    #fix function returns
    sed -i -e 's|EXIT /B 0|return 0|I' "$currentScript"
    sed -i -e 's|^\([[:space:]]\+\)exit /B \(\${[[:alnum:]_]\+}\)|\1errorlevel=\2\n\1return 0|I' "$currentScript"
    sed -i -e 's|^exit /B \(\${[[:alnum:]_]\+}\)|errorlevel=\1\nreturn 0|I' "$currentScript"
    sed -i -e 's|exit /b$|return|I' "$currentScript"

    #fix start references
    sed -i -e 's|^start /min \(.*\)|flatpak run com.retro_exo.wine \1 \&|I' "$currentScript"
    sed -i -e 's|^start \(.*\)|flatpak run com.retro_exo.wine \1 \&|I' "$currentScript"
    sed -i -e "s/&& start /\&\& flatpak run com.retro_exo.wine /I" "$currentScript"
    sed -i -e 's/\(^[[:space:]]\+\)start /\1start /I' "$currentScript"
    
    #fix cp unzip.exe instances
    sed -i -e 's/cp unzip /cp unzip.exe /' "$currentScript"
    
    #fix double spaced rm -rf command
    sed -i -e 's/rm -rf  /rm -rf /' "$currentScript"
    
    #Make variable declarations after && lowercase and remove 'set '
    sed -i -e 's/\(&& set \)\([^=]*\)\(=\)/\&\& \L\2\E\3/Ig' "$currentScript"
   
    #Make indented variable declarations lowercase and remove 'set '
    sed -i -e 's/\(^[[:space:]]\+\)\(set \)\([^=]*\)\(=\)/\1\L\3\E\4/I' "$currentScript"

    #Remove quotes from rm commands
    sed -i -e '/rm -rf /I{
                   :a;
                   s/\(rm -rf .*\)\"/\1/g;
                   ta;
               }' "$currentScript"
    sed -i -e '/&& rm /I{
                   :a;
                   s/\(&& rm .*\)\"/\1/g;
                   ta;
               }' "$currentScript"
    sed -i -e '/^rm /I{
                   :a;
                   s/^\(^rm .*\)\"/\1/g;
                   ta;
               }' "$currentScript"
    sed -i -e '/^[[:space:]]\+rm /I{
                   :a;
                   s/^\(^[[:space:]]\+rm .*\)\"/\1/g;
                   ta;
               }' "$currentScript"
    
    #fix update_installed.bsh references
    sed -i -e 's/update_installed\.bat/update_installed.bsh/I' "$currentScript"
    
    #fix remaining bat references
    sed -i -e "/sed \|run\.bat/I!s/\.bat/.bsh/Ig" "$currentScript"
    
    #fix ASE kill references
    sed -i -e 's/pidof ASE\.exe/pidof ASE/I' "$currentScript"
    sed -i -e 's/pidof ASE3\.exe/pidof ASE3/I' "$currentScript"
    sed -i -e 's/pidof Ultimapper_5\.exe/pidof Ultimapper_5/I' "$currentScript"
    
    #ensure DOSBox instanced that use Wine through variable assignment do not use Linux configuration
    #sed -i -e '/^dosbox=/{ N; s|^dosbox="wine \(.*\)\nconf=\(.*\)_linux.conf|dosbox="wine \1\nconf=\2.conf|I }' "$currentScript"
    
    #makeshift fix for NSLmode
    sed -i -e '/^conf=.*no_line_linux\.conf/{ N; s|^conf=\(.*\)\ncp \(.*\)|conf=\1\ncp \2\ngoto winstall|I }' "$currentScript"
    sed -i -e '/^goto winstall/{ N; s|^goto winst\(.*\)\ngoto inst\(.*\)|goto winst\1|I }' "$currentScript"
    sed -i -e '/^: install/{ N; s|^: inst\(.*\)\n\$dosbox -conf\(.*\)_linux\(.*\)|: winst\1\n\$dosbox -conf\2\3\ngoto continwin\n\n: inst\1\n\$dosbox -conf\2_linux\3\n: continwin|I }' "$currentScript"
    
    #finish fixing ^> instances
    sed -i -e '/echo /s/RIGHTANGLEBRACKET/>/g' "$currentScript"
    
    #remove quotes from for loop paths
    sed -i -e '/\$(\|findstr/!{/^for /s/\"//g}' "$currentScript"
    
    #add if and remove && PENDINGTRAILTLIBF
    sed -i -e '/PENDINGTRAILTLIBF/ { /^if /! s/^/if / }' "$currentScript"
    sed -i -e 's/ && PENDINGTRAILTLIBF//' "$currentScript"
    
    #indent body of multi-line if statements with for loop inside, and then fix placeholder variable names
    sed -i -e '/^PENDINGtBF/,/^PENDINGTLFI/ {
                   s/^/    /;
                   s/^    PENDINGtBF/then/;
                   s/^    PENDINGTLFI/fi/;
               }' "$currentScript"
    
    #add quotes back to variables
    sed -i -e '/^mv \|^[[:space:]]\+mv \|^cp \|^[[:space:]]\+cp \|^cd \|^[[:space:]]\+cd \|^\. \|^\"\|^wine \|^zip \|zip --dif \|echo \|grep \|sed \|bash \|source \|aria2c \|com.retro_exo.aria2c \|com.retro_exo.vlc \|flatpak \|SumatraPDF\|dynchoice \|read -p \"\|printf /! s/\(\${\)\([^}]*\)\(}\)/\"\1\2\3\"/g' "$currentScript"
    
    sed -i -e "/\[ /{
                   :a;
                   s/\(\[ [^\"]*\)\${\(.*\)}\(.* \] \)/\1\"\$\{\2\}\"\3/g;
                   :ta;
               }" "$currentScript"
    
    sed -i -e '/^cd \|^[[:space:]]\+cd / { /\"/! s/\${\(.*\)}/\"\$\{\1\}\"/g }' "$currentScript"
    
    sed -i -e '/^cp \|^[[:space:]]\+cp / {
                   /cp [^[:space:]]\+ [^[:space:]]\+$/ s/"//g;
                   /cp [^[:space:]]\+ [^[:space:]]\+ PENDINGTONULL$/ s/"//g;
                   /cp [^[:space:]]\+ [^[:space:]]\+$/ s/\(\${[^}]\+}\)/"\1"/g;
                   /cp [^[:space:]]\+ [^[:space:]]\+ PENDINGTONULL$/ s/\(\${[^}]\+}\)/"\1"/g;
               }' "$currentScript"
    
    #ensure there are no double quoted variables
    sed -i -e '/\\""\$/! s/""\(\${[[:alnum:]_]\+}\)"/"\1/g' "$currentScript"
    
    #fix loop looking for all files in current directory that are not zips or shell files
    sed -i -e "s#for f in 'dir /b /a-d \^| findstr /vile \"\.zip \.bsh\".*#find . -maxdepth 1 -not -iname \"*.zip\" -not -iname \"*.bsh\" -not -iname \"*.msh\" -not -iname \"*.bash\" -not -iname \"*.command\" -not -iname \"*.bat\" -type f -print0 | while read -d $'\\\\0' f#" \
        "$currentScript"

    #fix loop looking for directories inside of ./Content/GameData
    sed -i -e "s#for a in 'dir \./Content/GameData /A\:D /B.*#find ./Content/GameData -mindepth 1 -maxdepth 1 -type d -printf \"%P\\\\n\\\\0\" | sort -z | while read -d $'\\\\0' a#I" \
        "$currentScript"
    
    #fix loop for everything in current directory
    sed -i -e "s#for \([[:alnum:]_]\+\) in 'dir . /A /B.*#find . -mindepth 1 -maxdepth 1 -printf \"%P\\\\n\\\\0\" | sort -z | while read -d $'\\\\0' \1#I" "$currentScript"
    sed -i -e "s#for /f delims= \([[:alnum:]_]\+\) in 'dir . /A /B.*#find . -mindepth 1 -maxdepth 1 -printf \"%P\\\\n\\\\0\" | sort -z | while read -d $'\\\\0' \1#I" "$currentScript"
    
    #fix loop for specific files in current directory (without extensions)
    sed -i -e "s#for /f delims= \([[:alnum:]_]\+\) in 'dir /B \([[:alnum:]_.*]\+\)'#find . -mindepth 1 -maxdepth 1 -iname \"\2\" -printf \"%P\\\\n\\\\0\" | sed -e \"s/\\\(.PENDINGAST\\\)\\\..PENDINGAST/\\\1/\" | sort -z | while read -d $'\\\\0' \1#I" "$currentScript"
    
    #stop while loops from executing in a subshell
    sed -i -e '/^find.* | while/,/^done/ {
                   /^\(find.*\) | \(while.*\)/ {
                       h
                       s//done < <(\1)/
                       x
                       s//\2/
                       b
                   }
                   /^done/ x
               }' "$currentScript"
    sed -i -e '/^[[:space:]]\+find.* | while/,/^[[:space:]]\+done/ {
                   /^\([[:space:]]\+\)\(find.*\) | \(while.*\)/ {
                       h
                       s//\1done < <(\2)/
                       x
                       s//\1\3/
                       b
                   }
                   /^[[:space:]]\+done/ x
               }' "$currentScript"
    
    #fix 64-bit check
    sed -i -e "s#systeminfo | findstr /I type:#echo \"x\$(getconf LONG_BIT)\"#" "$currentScript"
    sed -i -e "s#cmd /c \"echo \${processor_architecture}\"#echo \"AMD\$(getconf LONG_BIT)\"#" "$currentScript"
    
    #fix simple searches for fixed strings in files
    sed -i -e "s#'findstr /C\:\(.[^[:space:]\"']*\) \(.[^[:space:]\"']*\)'#\$(grep \"\1\" PATHBEGINPLACEHOLDER\2PATHENDPLACEHOLDER)#I" "$currentScript"
    sed -i -e "s/\(PATHBEGINPLACEHOLD.*\)\\\!\(.*ENDPLACEHOLDER\)/\1\"\\\!\"\2/g" "$currentScript"
    sed -i -e "s/\(PATHBEGINPLACEHOLD.*\)\*\(.*ENDPLACEHOLDER\)/\1\"*\"\2/g" "$currentScript"
    sed -i -e "s/PATHBEGINPLACEHOLDER/\"/" "$currentScript"
    sed -i -e "s/PATHENDPLACEHOLDER/\"/" "$currentScript"
    
    #fix trailing backslashes at the end of echoes
    sed -i -e 's|\(echo.*\)\\\\"$|\1/"|' "$currentScript"
    
    #fix ! for conditional echos
    sed -i -e "/&& \+echo.*\!/ {
                   s/#/##/g;
                   s/\!/\\\!#/g;
                   :a;
                   s/\(&& \)\(echo.*>.*\)\\\!#\(.*\)/\1\2\\\!\3/;
                   ta;
                   s/\\\!#/\"'\!'\"/g;
                   s/##/#/g;
               }" "$currentScript"
    
    #fix bash calls that lack extensions
    sed -i -e '/\.bsh\|\.bat/!s/^\(source \)\(".*\)"$/\1\2.bsh"/' "$currentScript"
    sed -i -e '/\.bsh\|\.bat/!s/^\(source \)\([^"]*\)$/\1\2.bsh/' "$currentScript"
    sed -i -e '/\.bsh\|\.bat/!s/^\(^[[:space:]]\+\)\(source \)\(".*\)"$/\1\2\3.bsh"/' "$currentScript"
    sed -i -e '/\.bsh\|\.bat/!s/^\(^[[:space:]]\+\)\(source \)\([^"]*\)$/\1\2\3.bsh/' "$currentScript"
    sed -i -e '/\.bsh\|\.bat/!s/\(&& source \)\(".*\)"$/\1\2.bsh"/' "$currentScript"
    sed -i -e '/\.bsh\|\.bat/!s/\(&& source \)\([^"]*\)$/\1\2.bsh/' "$currentScript"
    
    #manual pack2 fix to make ! characters disappear as they do in Windows
    sed -i -e 's/pack2="\${f}"/pack2="$( tr -d "\\\!" <<<"$\{f\}" )"/' "$currentScript"
    
    #manual filename3 fix to add escaped quotes
    sed -i -e 's/\(filename3=\"\)\(\${.*}\)\"/\1\\\"\2\\\"\"/' "$currentScript"
    
    #change pendingdq instances to escaped quotes
    sed -i -e 's/pendingdq/\\\"/Ig' "$currentScript"
    
    #fix variables named with other variables
    sed -i -e "/^[[:space:]]*[^[:space:]]*\$[^[:space:]]\+=/ s/^\([[:space:]]*\)/\1declare /" "$currentScript"
    sed -i -e 's/&& \([^[:space:]]*\$[^[:space:]]\+=\)/\&\& declare \1/g' "$currentScript"
    
    #add cat command to set variables from files
    sed -i -e '/PENDINGCAT/ s/PENDINGCAT\(.*\)/"\$(cat \1 | head -n 1)"/' "$currentScript"
    
    #change pendingYYYYMMDD instances to today's value
    sed -i -e "s/pendingYYYYMMDD/\"\$(date +'%Y%m%d')\"/" "$currentScript"
    
    #fix alt launcher dosbox variable
    sed -i -e 's#dosbox="\${folderpath}"dosbox.exe#dosbox="\$(cat ./util/alt_dosbox_linux.txt | head -n 1)"#' "$currentScript"
    sed -i -e 's#dosbox="\${folderpath:19}"dosbox.exe#dosbox="\$(cat ./util/alt_dosbox_linux.txt | head -n 1)"#' "$currentScript"
    
    #assign freespace variable bytes free on current partition
    sed -i -e "s/freespace=DETERMINEBYTESFREE/freespace=\$(df -P -B 1 . | awk 'NR==2 {print \$4}')/" "$currentScript"
    
#    #fix desktop icon creation process
    sed -i -e 's#^echo.* > .*{userprofile}/Desktop/eXoDOS.*#echo "\[Desktop Entry\]" > ~/Desktop/eXoDOS.desktop\
echo "Encoding=UTF-8" >> ~/Desktop/eXoDOS.desktop\
echo "Version=1.0" >> ~/Desktop/eXoDOS.desktop\
echo "Type=Application" >> ~/Desktop/eXoDOS.desktop\
echo "Terminal=false" >> ~/Desktop/eXoDOS.desktop\
echo "Exec=\\"\${scriptDir%/eXo/util}/exogui.command\\"" >> ~/Desktop/eXoDOS.desktop\
echo "Name=eXoDOS" >> ~/Desktop/eXoDOS.desktop\
echo "Icon=\${scriptDir}/exodos.ico" >> ~/Desktop/eXoDOS.desktop#I' "$currentScript"
    
    sed -i -e '/echo.* >> .*{userprofile}\/Desktop\/eXoDOS.*/Id' "$currentScript"
    
    sed -i -e 's#^echo.* > .*{userprofile}/Desktop/eXoDREAMM.*#echo "\[Desktop Entry\]" > ~/Desktop/eXoDREAMM.desktop\
echo "Encoding=UTF-8" >> ~/Desktop/eXoDREAMM.desktop\
echo "Version=1.0" >> ~/Desktop/eXoDREAMM.desktop\
echo "Type=Application" >> ~/Desktop/eXoDREAMM.desktop\
echo "Terminal=false" >> ~/Desktop/eXoDREAMM.desktop\
echo "Exec=\\"\${scriptDir%/eXo/util}/exogui.command\\"" >> ~/Desktop/eXoDREAMM.desktop\
echo "Name=eXoDREAMM" >> ~/Desktop/eXoDREAMM.desktop\
echo "Icon=\${scriptDir}/exodreamm.png" >> ~/Desktop/eXoDREAMM.desktop#I' "$currentScript"
    
    sed -i -e '/echo.* >> .*{userprofile}\/Desktop\/eXoDREAM.*/Id' "$currentScript"
    
    sed -i -e 's#^echo.* > .*{userprofile}/Desktop/eXo\${name}.*#echo "\[Desktop Entry\]" > ~/Desktop/eXo\${name}.desktop\
echo "Encoding=UTF-8" >> ~/Desktop/eXo\${name}.desktop\
echo "Version=1.0" >> ~/Desktop/eXo\${name}.desktop\
echo "Type=Application" >> ~/Desktop/eXo\${name}.desktop\
echo "Terminal=false" >> ~/Desktop/eXo\${name}.desktop\
echo "Exec=\\"\${scriptDir%/eXo/util}/exogui.command\\"" >> ~/Desktop/eXo\${name}.desktop\
echo "Name=eXo\${name}" >> ~/Desktop/eXo\${name}.desktop\
echo "Icon=\${scriptDir}/exodos.ico" >> ~/Desktop/eXo\${name}.desktop#I' "$currentScript"
    
    sed -i -e '/echo.* >> .*{userprofile}\/Desktop\/eXo\${name}.*/Id' "$currentScript"
    
    #change userprofile references to ~
    sed -i -e 's/${userprofile}/~/g' "$currentScript"

    #fix lines where shell scripts are called by variables
    sed -i -e "/^\"\${execute}\"\|^[[:space:]]\+\"\${execute}\"/I s/\(\"\${execute}\"\)/source \1/I" "$currentScript"
    sed -i -e "/\&\& \"\${execute}\"/I s/\(\&\&\) \(\"\${execute}\"\)/\1 source \2/I" "$currentScript"
    
    #fix lines where commands are called by variables
    sed -i -e "/^\"\${/ s/^\(\"\${\)/eval \1/" "$currentScript"
    sed -i -e "/^[[:space:]]\+\"\${/ s/^\([[:space:]]\+\)\"\${/\1 eval \"\${/" "$currentScript"
    sed -i -e "/\&\& \"\${/ s/\(\&\&\) \"\${/\1 eval \"\${/" "$currentScript"
    sed -i -e '/eval /{
                   :a;
                   s/\(eval .*\)\"/\1pendingdq/g;
                   ta;
               }' "$currentScript"
    sed -i -e 's/eval pendingdq\(\${[^}]*}\)pendingdq/eval \"\1\"/' "$currentScript"
    sed -i -e 's/pendingdq/\\\"/Ig' "$currentScript"
    
    #add lines that correct scriptDir value after returning from sourced bash scripts
    sed -i -e '/^source \|^[[:space:]]\+source \|&& source /i\
scriptDirStack["${#scriptDirStack[@]}"]="$scriptDir"' "$currentScript"
    sed -i -e '/^source \|^[[:space:]]\+source \|&& source /a scriptDir="${scriptDirStack["${#scriptDirStack[@]}"-1]}"\
unset scriptDirStack["${#scriptDirStack[@]}"-1]\
function goto\
{\
    shortcutName=$1\
    newPosition=$(sed -n -e "/: $shortcutName$/{:a;n;p;ba};" "$scriptDir/$(basename -- "$BASH_SOURCE")" )\
    eval "$newPosition"\
    exit\
}' "$currentScript"
    
    #fix bash calls that should exit after execution
    sed -i -e 's|^\([\./]*[[:alnum:]_/\"}{\$\!]\+\.bsh.*\)|source \1 \&\& exit 0|' "$currentScript"
    
    #make source commands use eval to prevent issues with quoted paths
    sed -i -e '/^source \|^[[:space:]]\+source / s/source/eval source/' "$currentScript"
    sed -i -e 's/&& source /\&\& eval source /' "$currentScript"
    
    #finish fixing true / false tests
    sed -i -e '/^PENDINGTLTRU$/,/^PENDINGTLEOC/ {
                   s/^/    /;
                   s/^    PENDINGTLTRU/if [ \$? -eq 0 ]\nthen/;
                   s/^    PENDINGTLFAL/else/;
                   s/^    PENDINGTLEOC/fi/;
               }' "$currentScript"
               

    sed -i -e '/^\([[:space:]]\+\)PENDINGNSTRU$/,/^\([[:space:]]\+\)PENDINGNSEOC/ {
                   s/^/    /;
                   s/^\([[:space:]]\+\)    PENDINGNSTRU/\1if [ \$? -eq 0 ]\n\1then/;
                   s/^\([[:space:]]\+\)    PENDINGNSFAL/\1else/;
                   s/^\([[:space:]]\+\)    PENDINGNSEOC/\1fi/;
               }' "$currentScript"
    
    #fix redirects to /dev/null
    sed -i -e 's|PENDINGTONULL|\&>/dev/null|' "$currentScript"
    
    #ensure there are no quoted instances of \! or * in paths
    sed -i -e '/mv \|echo \|foobar2000\.exe /! {
                   :a;
                   s/ "\([^[:space:]"]\+\)\\\!\([^[:space:]"]\+\)"/ "\1PENDINGUQB\2"/g;
                   s/ "\([^[:space:]"]\+\)\*\([^[:space:]"]\+\)"/ "\1PENDINGUQW\2"/g;
                   :ta;
                   s/PENDINGUQB/"\\\!"/g;
                   s/PENDINGUQW/"\*"/g;
               }' "$currentScript"
    sed -i -e '/mv / {
                   :a;
                   s/mv "\([^"]\+\)\\\!\([^"]\+\)" "\([^"]\+\)"$/mv "\1PENDINGUQB\2" "\3"/g;
                   s/mv "\([^"]\+\)\*\([^"]\+\)" "\([^"]\+\)"$/mv "\1PENDINGUQW\2" "\3"/g;
                   s/mv "\([^"]\+\)" "\([^"]\+\)\\\!\([^"]\+\)"$/mv "\1" "\2PENDINGUQB\3"/g;
                   s/mv "\([^"]\+\)" "\([^"]\+\)\*\([^"]\+\)"$/mv "\1" "\2PENDINGUQW\3"/g;
                   :ta;
                   s/PENDINGUQB/"\\\!"/g;
                   s/PENDINGUQW/"\*"/g;
               }' "$currentScript"
    sed -i -e '/^[^"]*foobar2000\.exe "[^"]\+"$/ s/\\\!/PENDINGUQB/g' "$currentScript"
    sed -i -e '/^[^"]*foobar2000\.exe "[^"]\+"$/ s/\*/PENDINGUQW/g' "$currentScript"
    sed -i -e 's/PENDINGUQB/"\\\!"/g' "$currentScript"
    sed -i -e 's/PENDINGUQW/"\*"/g' "$currentScript"
    
    #ensure remaining executable calls use wine
    sed -i -e 's/^\([^[:space:]\"~=]*\)\.exe/flatpak run com.retro_exo.wine \1.exe/I' "$currentScript"
    
    #remove quotes from declarations that contain variables with spaces
    sed -i -e '/^[[:space:]_]*[[:alnum:]_]\+=/{
                   /sed \|printf \|\$(/b; /[&<>\'\''`|]/{
                       h;
                       s/[&<>\'\''`|].*//;
                       /^[[:space:]_]*[[:alnum:]_]\+=.*[[:space:]]./{
                           s/"//g;
                           x;
                           s/^[^&<>\'\''`|]*//;
                           H;
                           x;
                           s/\n//;
                       };
                       /^[[:space:]_]*[[:alnum:]_]\+=.*[[:space:]]./!g;
                   };
                   /[&<>\'\''`|]/!{
                       /^[[:space:]_]*[[:alnum:]_]\+=.*[[:space:]]/s/"//g;
                   };
               }' "$currentScript"
    
    #Fix variables with spaces
    sed -i -e 's/^\([[:alnum:]_]\+\)=\([^"&]\+ [^"&]\+\) && /\1="\2" \&\& /' "$currentScript"
    sed -i -e 's/^\([[:space:]_]\+[[:alnum:]_]\+\)=\([^"&]\+ [^"&]\+\) && /\1="\2" \&\& /' "$currentScript"
    sed -i -e 's/\( && [[:alnum:]_]\+\)=\([^"&]\+ [^"&]\+\) && /\1="\2" \&\& /' "$currentScript"
    sed -i -e 's/\( && [[:alnum:]_]\+\)="\([^"&][^&]\+ && \)/\1=\2/' "$currentScript"
    sed -i -e '/ && [[:alnum:]_]\+=[^&]\+ && /{
                   :a;
                   s|\( && [[:alnum:]_]\+=[^"&]\+\)"\(.* && \)|\1\2|;
                   ta;
               }' "$currentScript"
    sed -i -e 's/\( && [[:alnum:]_]\+\)=\([^"&]\+\) && /\1="\2" \&\& /' "$currentScript"
    sed -i -e '/pendingIFS='"'"'/! s/^\([[:alnum:]_]\+\)=\([^"]\+ [^"]\+\)$/\1="\2"/' "$currentScript"
    sed -i -e '/pendingIFS='"'"'/! s/^\([[:space:]_]\+[[:alnum:]_]\+\)=\([^"]\+ [^"]\+\)$/\1="\2"/' "$currentScript"
    sed -i -e 's/\( && [[:alnum:]_]\+\)=\([^"]\+ [^"]\+\)$/\1="\2"/' "$currentScript"
    sed -i -e '/=["]\?${/ {
                   :a;
                   s/\([[:alnum:]_]\+="[^"]*\)"\([[:space:]]\+[^"=&]\+=\)"\([^"]*\)"/\1\2\3"/;
                   ta;
                   s/\([[:alnum:]_]\+="[^"]*\)"\([[:space:]]\+-[^"=&]\+\)/\1\2"/;
                   ta;
               }' "$currentScript"
    sed -i -e 's/^\([[:alnum:]_]\+\)=\([^"&(`'"'"'\\]\+\)"/\1="\2/' "$currentScript"
    sed -i -e 's/^\([[:space:]_]\+[[:alnum:]_]\+\)=\([^"&(`'"'"'\\]\+\)"/\1="\2/' "$currentScript"
    
    #fix sequence loops
    sed -i -e 's|for /l \([[:alnum:]_]\+\) in \([[:digit:]]\+\),\([[:digit:]]\+\),\([^[:space:]]\+\)|for \1 in `seq \2 \3 \4`|I' "$currentScript"
    
    #fix delayed expansion in the contents of variables being set
    sed -i -e '/[[:alnum:]_]\+=\\\!.*{.*\\\!/ s/&& \([[:alnum:]_]\+\)=\\\!\(.*\)\\\!/\&\& eval \1=\\"\\\$\2\\"/' "$currentScript"
    
    #fix delim loop variable assignment
    sed -i -e 's|"\([[:alnum:]_]\+\)="&for /f "delims=\([[:alnum:]_]\+\)" \${\([[:alnum:]_]\+\)} in ("\${\([[:alnum:]_]\+\)}") do set \1=\${\3}|[[ "\2" \!= *"\$\4"* ]] \&\& \1="\$\4"|I' "$currentScript"
    #sed -i -e 's|"\([[:alnum:]_]\+\)="&for /f "delims=\([[:alnum:]_]\+\)" \${\([[:alnum:]_]\+\)} in ("\${\([[:alnum:]_]\+\)}") do set \1=\${\3}|delims="\2"; for (( \3=0; \3<\${#delims}; \3++ )); do [ "\$\4" -eq "\${delims:\$\3:1}" ] \&\& \1="\${delims:\$\3:1}"; done; unset delims|' "$currentScript"
    
    #fix recursive file loops (note this is not a flawless substitution, but one that works with the way eXo uses them)
    sed -i -e 's|for /r \([^[:space:]"]\+\) \([[:alpha:]]\) in \([^[:space:]"]\+\)|for \2 in $(find "\1" -type f -name "\3" -printf "%f\\n")|I' "$currentScript"
    sed -i -e 's|\${\~}"n\([[:alpha:]]\)|\$\{\L\1\E}"|' "$currentScript"
    sed -i -e 's|\${\~}n\([[:alpha:]]\)|\$\{\L\1\E}|' "$currentScript"
    
    #escape wildcards in unzip commands
    sed -i -e '/unzip -/ {
                   :a;
                   s/\(unzip -.*\)\*/\1pendingWILDescape/g;
                   ta;
                   s/pendingWILDescape/\\*/g
               }' "$currentScript"
    
    #fix exist test instances with wildcards
    sed -i -e '/\[ -e [^]]*\*.*]/ s#\[ -e \([^]]*\) \]#[[ "\$(ls -1 \1 2>/dev/null | wc -l)" -gt 0 ]]#' "$currentScript"
    sed -i -e '/\[ ! -e [^]]*\*.*]/ s#\[ ! -e \([^]]*\) \]#[[ "\$(ls -1 \1 2>/dev/null | wc -l)" -eq 0 ]]#' "$currentScript"
    
    #add conditional return to goto statements to destack after execution succeeds on called scripts
    sed -i -e '/^goto \|^[[:space:]]\+goto \|&& goto/ s/$/ \&\& [[ \$0 \!= $BASH_SOURCE ]] \&\& return/' "$currentScript"
    
    #add conditional return to the end of scripts to return after execution completes
    sed -i -e '$a\
[[ $0 \!= $BASH_SOURCE ]] && return' "$currentScript"
    
    #pull just the final matching line and strip out carriage returns for grep based variable assignments
    sed -i -e "s/\(=\`grep [^\`]*\)\`/\1 | tail -1 | tr -d \"\\\r\"\`/Ig" "$currentScript"
    
    #fix greps for comment lines
    sed -i -e "/grep.[-i ]*\"REM\" /I {
                   s/\"REM\"/\"^# \"/;
                   s/tr -d \"\\\r\"\`/tr -d \"\\\r\" | sed -e \"s\/#\/REM\/\"\`/I;
                }" "$currentScript"
    
    #prepare extra \ escapes for extended echos, excluding lines with eval
    sed -i -e '/eval /b' -e '/echo / s/\\\\\([abcefnrtv0x]\)/\\\\\\\1/g' "$currentScript"
    
    #escape $ characters from variables in eval execution lines
    sed -i -e '/eval.*\${[[:alnum:]_]\+}/I{
                   :a;
                   s|\(eval.*\)\${\([[:alnum:]_]\+\)}\(.*\)|\1PENDINGsub{\2}\3|;
                   ta;
               }' "$currentScript"
    sed -i -e '/eval / s#PENDINGsub{\([[:alnum:]_]\+\)}#$(echo \"${\1}\" | sed -e "s/\\\\$/\\\\\\\\$/g")#g' "$currentScript"
    
    #fix space issue for unit in combinedsize declarations
    sed -i -e '/combinedsize=/ s/" "/ /' "$currentScript"
    
    #fix variable assignments that remove a specific character from another variable
    sed -i -e 's|declare \(.[^[:space:]\"~=]*\)="\${\(.[^[:space:]\"~=]*\):\(.\)=}"|\1="\$\{\2//\3\}"|' "$currentScript"
    
    #fix quoted variable assignments
    sed -i -e 's/^"\([[:alnum:]_]\+\)=\([^[:space:]\"~=]\)/\1="\2/' "$currentScript"
    
    #fix quotes for wad variable declarations
    sed -i -e '/^wad[[:digit:]]\?=/I s/"//g' "$currentScript"
    sed -i -e 's/^\(wad[[:digit:]]\?\)=\(.*\)/\1="\2"/I' "$currentScript"
    
    #escape spaces in unquoted file existence tests
    sed -i -e '/^\[ -e [^"]* \]\|^\[ ! -e [^"]* \]\|^[[:space:]]\+\[ -e [^"]* \]\|^[[:space:]]\+\[ ! -e [^"]* \]/ {
                   s|SPACE#|incrediblyunlikelytmpspace#|g;
                   :a;
                   s|^\(.[^]]*\] &&.*\) |\1SPACE#|g;
                   s| \([^[:space:][]*\[ \)|SPACE#\1|g;
                   ta;
                   s|\[ -e |\[SPACE#-eSPACE#|;
                   s|\[ ! -e |\[SPACE#!SPACE#-eSPACE#|;
                   s| \] |SPACE#\]SPACE#|;
                   s| |\\ |g;
                   s|SPACE#| |g;
                   s|incrediblyunlikelytmpspace#|SPACE#|g;
                }' "$currentScript"
                
    #requote directory paths for ScummVM collection
    sed -i -e 's#)/\([^[:space:]\%\${}"=]\+ [^\%\${}"=]\+\)\(\\" [^\%\${}"=]\+\)$#)/"\1"\2#' "$currentScript"
    
    #hardcoded fix for looping through a variable with a list of directories
    sed -i -e 's/\(for [[:alnum:]] in \)\("${[[:alnum:]]\+folders}"\)/\1\$(echo \2)/I' "$currentScript"
    
    #fix recursive cp commands (relies on ${d} variable being used for both source and destination)
    sed -i -e 's|cp \([^[:space:]]\+/"\${d}"\) \([^[:space:]]\+/"\${d}"\)|cp -r \1/* \2|' "$currentScript"
    
    #fix variable for current script basename without extension
    sed -i -e 's/PENDINGBASENOEXT/\$(basename "\${0\%.*}")/' "$currentScript"
    
    #fix parameter size variables
    sed -i -e 's/\%~z\([[:digit:]]\)/\$(du -b "\$\1" | cut -f1)/Ig' "$currentScript"
    
    #ensure carriage returns are present after writing to BBS CHAIN.TXT files
    sed -i -e "s|> \(CHAIN\.TXT\)$|> \1 \&\& sed -i -e '/\\\r/\! s/$/\\\r/' \1|I" "$currentScript"
    
    #ensure carriage returns are present after writing to BBS DOOR.SYS files
    sed -i -e "s|> \(DOOR\.SYS\)$|> \1 \&\& sed -i -e '/\\\r/\! s/$/\\\r/' \1|I" "$currentScript"
    
    sed -i -e '/^rm / { /"\|^rm -rf\|\\(\|\\)\|\\ /! {
                   s/ /\\ /g;
                   s/^rm\\ /rm /;
                   s/(/\\(/g;
                   s/)/\\)/g;
                   s/\(\.[[:alnum:]_][[:alnum:]_][[:alnum:]_]\)\\ /\1 /g;
               } }' "$currentScript"
    
    #add carriage returns to files modified by restore.py
    sed -i -e "s|^\(python3 \./eXo/Update/restore\.py\)$|\1\nsed -i -e '/\\\r/\! s/$/\\\r/' \"\$PWD\"/Data/Platforms/MS-DOS.xml|" "$currentScript"
    sed -i -e "s|^\(python3 \./eXo/Update/restore\.py \)\(\".*\"\)|\1\2\nsed -i -e '/\\\r/\! s/$/\\\r/' \2/Data/Platforms/MS-DOS.xml|" "$currentScript"
    sed -i -e "s|^\(python3 \./eXo/util/restore\.py\)$|\1\nsed -i -e '/\\\r/\! s/$/\\\r/' \"\$PWD\"/Data/Platforms/MS-DOS.xml|" "$currentScript"
    sed -i -e "s|^\(python3 \./eXo/util/restore\.py \)\(\".*\"\)|\1\2\nsed -i -e '/\\\r/\! s/$/\\\r/' \2/Data/Platforms/MS-DOS.xml|" "$currentScript"
    sed -i -e "s|\(\&\& python3 \./eXo/Update/restore\.py\)$|\1 \&\& sed -i -e '/\\\r/\! s/$/\\\r/' \"\$PWD\"/Data/Platforms/MS-DOS.xml|" "$currentScript"
    sed -i -e "s|\(\&\& python3 \./eXo/Update/restore\.py \)\(\".*\"\)|\1\2 \&\& sed -i -e '/\\\r/\! s/$/\\\r/' \2/Data/Platforms/MS-DOS.xml|" "$currentScript"
    sed -i -e "s|\(\&\& python3 \./eXo/util/restore\.py\)$|\1 \&\& sed -i -e '/\\\r/\! s/$/\\\r/' \"\$PWD\"/Data/Platforms/MS-DOS.xml|" "$currentScript"
    sed -i -e "s|\(\&\& python3 \./eXo/util/restore\.py \)\(\".*\"\)|\1\2 \&\& sed -i -e '/\\\r/\! s/$/\\\r/' \2/Data/Platforms/MS-DOS.xml|" "$currentScript"
    
    #fix PENDINGAST
    sed -i -e "s/PENDINGAST/*/g" "$currentScript"
    
    #fix pendingL3I
    sed -i -e 's/^\([[:space:]]\+\)\(.*\) \&\& pendingL3then/\1\2\n\1then/' "$currentScript"
    sed -i -e "s/pendingL3I /if /" "$currentScript"
    sed -i -e "s/pendingL3FI/fi/" "$currentScript"
    
    #fix PENDINGBACKTICK
    sed -i -e 's/PENDINGBACKTICK/\\`/g' "$currentScript"
    
    #fix pendingIFS
    sed -i -e 's/pendingIFS/IFS/g' "$currentScript"
    
    #add quotes to text format declarations
    sed -i -e '/echo \".*=\x1b.* >/ {
                   s/=\x1b/=pendingdq\x1b/;
                   s/" >/mpendingdq" >/I;
               }' "$currentScript"
    sed -i -e '/=\x1b/ {
                   s/$/"/;
                   s/=\x1b/="\x1b/;
               }' "$currentScript"
    sed -i -e 's/pendingdq/\\\"/Ig' "$currentScript"
               
    #fix escape characters for text formatting
    sed -i -e 's/\x1b/\\e/g' "$currentScript"
    
    #ensure comment lines are written in bash format
    sed -i -e 's/echo "rem /echo "# /' "$currentScript"
    
    #make all echos without redirects extended
    sed -i -e '/eval \|=.* >/b' -e 's/echo "/echo -e "/' "$currentScript"
    
    #set variable value to define directory selection dialog commands (pscommand)
    sed -i -e '/"[[:alnum:]_]\+="(new-object -COM '\''Shell\.Application'\'')\^/I {
                   N
                   s/^\([[:blank:]]*\)"\([[:alnum:]_]\+\)="(new-object -COM '\''Shell\.Application'\'')\^\n[[:blank:]]*\.BrowseForFolder(0,'\''\(.*\)'\'',0,0)\.self\.path""/\1\L\2\E="flatpak run com.retro_exo.zenity --file-selection --directory --title=\\"\3\\""/I
               }' "$currentScript"
    
    #set variables called through converted PowerShell commands
    sed -i -e '/for \/f usebackq delims=.*powershell.*/ {
                   N;N;N;
                   s/^\([[:blank:]]*\)for \/f usebackq delims= \([[:alnum:]_]\+\) in `powershell \("${[[:alnum:]_]\+}"\)`\n[[:blank:]]*do\n[[:blank:]]*"\([[:alnum:]_]\+\)="${\2}""\n[[:blank:]]*done/\1unset \L\4\E\n\1while [ -z "${\L\4\E}" ]\n\1do\n\1    \L\4\E="$(eval \L\3\E)"\n\1done/
               }' "$currentScript"
    
    #add bash header line, goto function and alias
    sed -i -e '1i\
#!/usr/bin/env bash\
if [[ "$LD_PRELOAD" =~ "gameoverlayrenderer" ]]\
then\
    LD_PRELOAD=""\
fi\
[[ $0 == $BASH_SOURCE ]] && cd "$( dirname "$0")"\
scriptDir="$(cd "$( dirname "$BASH_SOURCE")" && pwd)"\
[ $# -gt 0 ] && parameterone="$1"\
[ $# -gt 1 ] && parametertwo="$2"\
[ $# -gt 2 ] && parameterthree="$3"\
[ $# -gt 3 ] && parameterfour="$4"\
\
if [ "${BASH_VERSINFO:-0}" -lt 5 ]\
then\
    printf "\\n\\e[1;31;47mThe version of bash currently running is too old.\\e[0m\\n\\n"\
    printf "Please run the \\e[1;33;40minstall_dependencies.command\\e[0m script.\\n"\
    printf "Then, follow the instructions to install the required dependencies.\\n"\
    read -s -n 1 -p "Press any key to abort."\
    printf "\\n\\n"\
    exit 0\
fi\
\
function goto\
{\
    shortcutName=$1\
    newPosition=$(sed -n -e "/: $shortcutName$/{:a;n;p;ba};" "$scriptDir/$(basename -- "$BASH_SOURCE")" )\
    eval "$newPosition"\
    exit\
}\
alias :="goto"\
\
function dynchoice\
{\
    local choices="$1"\
    local textpmt="$2"\
    local numofchoices="${#choices}"\
    local choicesu="${choices^^}"\
    local choicesl="${choices,,}"\
    if [ "$numofchoices" -eq 10 ]\
    then\
        while true\
        do\
            read -p "$textpmt " choice\
            case $choice in\
                [${choicesu:0:1}${choicesl:0:1}]* ) errorlevel=1\
                        break;;\
                [${choicesu:1:1}${choicesl:1:1}]* ) errorlevel=2\
                        break;;\
                [${choicesu:2:1}${choicesl:2:1}]* ) errorlevel=3\
                        break;;\
                [${choicesu:3:1}${choicesl:3:1}]* ) errorlevel=4\
                        break;;\
                [${choicesu:4:1}${choicesl:4:1}]* ) errorlevel=5\
                        break;;\
                [${choicesu:5:1}${choicesl:5:1}]* ) errorlevel=6\
                        break;;\
                [${choicesu:6:1}${choicesl:6:1}]* ) errorlevel=7\
                        break;;\
                [${choicesu:7:1}${choicesl:7:1}]* ) errorlevel=8\
                        break;;\
                [${choicesu:8:1}${choicesl:8:1}]* ) errorlevel=9\
                        break;;\
                [${choicesu:9:1}${choicesl:9:1}]* ) errorlevel=10\
                        break;;\
                *     ) printf "Invalid input.\\n";;\
            esac\
        done\
    elif [ "$numofchoices" -eq 9 ]\
    then\
        while true\
        do\
            read -p "$textpmt " choice\
            case $choice in\
                [${choicesu:0:1}${choicesl:0:1}]* ) errorlevel=1\
                        break;;\
                [${choicesu:1:1}${choicesl:1:1}]* ) errorlevel=2\
                        break;;\
                [${choicesu:2:1}${choicesl:2:1}]* ) errorlevel=3\
                        break;;\
                [${choicesu:3:1}${choicesl:3:1}]* ) errorlevel=4\
                        break;;\
                [${choicesu:4:1}${choicesl:4:1}]* ) errorlevel=5\
                        break;;\
                [${choicesu:5:1}${choicesl:5:1}]* ) errorlevel=6\
                        break;;\
                [${choicesu:6:1}${choicesl:6:1}]* ) errorlevel=7\
                        break;;\
                [${choicesu:7:1}${choicesl:7:1}]* ) errorlevel=8\
                        break;;\
                [${choicesu:8:1}${choicesl:8:1}]* ) errorlevel=9\
                        break;;\
                *     ) printf "Invalid input.\\n";;\
            esac\
        done\
    elif [ "$numofchoices" -eq 8 ]\
    then\
        while true\
        do\
            read -p "$textpmt " choice\
            case $choice in\
                [${choicesu:0:1}${choicesl:0:1}]* ) errorlevel=1\
                        break;;\
                [${choicesu:1:1}${choicesl:1:1}]* ) errorlevel=2\
                        break;;\
                [${choicesu:2:1}${choicesl:2:1}]* ) errorlevel=3\
                        break;;\
                [${choicesu:3:1}${choicesl:3:1}]* ) errorlevel=4\
                        break;;\
                [${choicesu:4:1}${choicesl:4:1}]* ) errorlevel=5\
                        break;;\
                [${choicesu:5:1}${choicesl:5:1}]* ) errorlevel=6\
                        break;;\
                [${choicesu:6:1}${choicesl:6:1}]* ) errorlevel=7\
                        break;;\
                [${choicesu:7:1}${choicesl:7:1}]* ) errorlevel=8\
                        break;;\
                *     ) printf "Invalid input.\\n";;\
            esac\
        done\
    elif [ "$numofchoices" -eq 7 ]\
    then\
        while true\
        do\
            read -p "$textpmt " choice\
            case $choice in\
                [${choicesu:0:1}${choicesl:0:1}]* ) errorlevel=1\
                        break;;\
                [${choicesu:1:1}${choicesl:1:1}]* ) errorlevel=2\
                        break;;\
                [${choicesu:2:1}${choicesl:2:1}]* ) errorlevel=3\
                        break;;\
                [${choicesu:3:1}${choicesl:3:1}]* ) errorlevel=4\
                        break;;\
                [${choicesu:4:1}${choicesl:4:1}]* ) errorlevel=5\
                        break;;\
                [${choicesu:5:1}${choicesl:5:1}]* ) errorlevel=6\
                        break;;\
                [${choicesu:6:1}${choicesl:6:1}]* ) errorlevel=7\
                        break;;\
                *     ) printf "Invalid input.\\n";;\
            esac\
        done\
    elif [ "$numofchoices" -eq 6 ]\
    then\
        while true\
        do\
            read -p "$textpmt " choice\
            case $choice in\
                [${choicesu:0:1}${choicesl:0:1}]* ) errorlevel=1\
                        break;;\
                [${choicesu:1:1}${choicesl:1:1}]* ) errorlevel=2\
                        break;;\
                [${choicesu:2:1}${choicesl:2:1}]* ) errorlevel=3\
                        break;;\
                [${choicesu:3:1}${choicesl:3:1}]* ) errorlevel=4\
                        break;;\
                [${choicesu:4:1}${choicesl:4:1}]* ) errorlevel=5\
                        break;;\
                [${choicesu:5:1}${choicesl:5:1}]* ) errorlevel=6\
                        break;;\
                *     ) printf "Invalid input.\\n";;\
            esac\
        done\
    elif [ "$numofchoices" -eq 5 ]\
    then\
        while true\
        do\
            read -p "$textpmt " choice\
            case $choice in\
                [${choicesu:0:1}${choicesl:0:1}]* ) errorlevel=1\
                        break;;\
                [${choicesu:1:1}${choicesl:1:1}]* ) errorlevel=2\
                        break;;\
                [${choicesu:2:1}${choicesl:2:1}]* ) errorlevel=3\
                        break;;\
                [${choicesu:3:1}${choicesl:3:1}]* ) errorlevel=4\
                        break;;\
                [${choicesu:4:1}${choicesl:4:1}]* ) errorlevel=5\
                        break;;\
                *     ) printf "Invalid input.\\n";;\
            esac\
        done\
    elif [ "$numofchoices" -eq 4 ]\
    then\
        while true\
        do\
            read -p "$textpmt " choice\
            case $choice in\
                [${choicesu:0:1}${choicesl:0:1}]* ) errorlevel=1\
                        break;;\
                [${choicesu:1:1}${choicesl:1:1}]* ) errorlevel=2\
                        break;;\
                [${choicesu:2:1}${choicesl:2:1}]* ) errorlevel=3\
                        break;;\
                [${choicesu:3:1}${choicesl:3:1}]* ) errorlevel=4\
                        break;;\
                *     ) printf "Invalid input.\\n";;\
            esac\
        done\
    elif [ "$numofchoices" -eq 3 ]\
    then\
        while true\
        do\
            read -p "$textpmt " choice\
            case $choice in\
                [${choicesu:0:1}${choicesl:0:1}]* ) errorlevel=1\
                        break;;\
                [${choicesu:1:1}${choicesl:1:1}]* ) errorlevel=2\
                        break;;\
                [${choicesu:2:1}${choicesl:2:1}]* ) errorlevel=3\
                        break;;\
                *     ) printf "Invalid input.\\n";;\
            esac\
        done\
    elif [ "$numofchoices" -eq 2 ]\
    then\
        while true\
        do\
            read -p "$textpmt " choice\
            case $choice in\
                [${choicesu:0:1}${choicesl:0:1}]* ) errorlevel=1\
                        break;;\
                [${choicesu:1:1}${choicesl:1:1}]* ) errorlevel=2\
                        break;;\
                *     ) printf "Invalid input.\\n";;\
            esac\
        done\
    else\
        printf "\\n\\e[1;31;47mError in dynamic case statement\\041\\041\\041\\e[0m"\
        printf "\\n\\e[1;31;47mPlease report this to the team.\\e[0m\\n\\n"\
        read -s -n 1 -p "Press any key to abort."\
        printf "\\n\\n"\
        exit 0\
    fi\
    return\
}\
\
depcheck=flatpak\
missingDependencies=no\
if [ $depcheck == "flatpak" ]\
then\
    ! [[ `which flatpak` ]] && missingDependencies=yes\
    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\\.aria2c"` ]] && missingDependencies=yes\
    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\\.dosbox-074r3-1"` ]] && missingDependencies=yes\
    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\\.dosbox-ece-r4301"` ]] && missingDependencies=yes\
    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\\.dosbox-ece-r4358"` ]] && missingDependencies=yes\
    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\\.dosbox-ece-r4482"` ]] && missingDependencies=yes\
    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\\.dosbox-gridc-4-3-1"` ]] && missingDependencies=yes\
    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\\.dosbox-staging-082-0"` ]] && missingDependencies=yes\
    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\\.dosbox-staging-081-2"` ]] && missingDependencies=yes\
    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\\.dosbox-x-08220"` ]] && missingDependencies=yes\
    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\\.dosbox-x-20240701"` ]] && missingDependencies=yes\
    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\\.gzdoom-4-11-3"` ]] && missingDependencies=yes\
    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\\.scummvm-2-2-0"` ]] && missingDependencies=yes\
    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\\.scummvm-2-3-0-git15811-gf97bfb7ce1"` ]] && missingDependencies=yes\
    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\\.vlc"` ]] && missingDependencies=yes\
    ! [[ `flatpak list 2>/dev/null | grep "retro_exo\\.wine"` ]] && missingDependencies=yes\
elif [ $depcheck == "native" ]\
then\
    ! [[ `which dosbox-074r3-1` ]] && missingDependencies=yes\
    ! [[ `which dosbox-ece-r4301` ]] && missingDependencies=yes\
    ! [[ `which dosbox-ece-r4358` ]] && missingDependencies=yes\
    ! [[ `which dosbox-ece-r4482` ]] && missingDependencies=yes\
    ! [[ `which dosbox-gridc-4-3-1` ]] && missingDependencies=yes\
    ! [[ `which dosbox-staging-082-0` ]] && missingDependencies=yes\
    ! [[ `which dosbox-staging-081-2` ]] && missingDependencies=yes\
    ! [[ `which dosbox-x-08220` ]] && missingDependencies=yes\
    ! [[ `which dosbox-x-20240701` ]] && missingDependencies=yes\
    ! [[ `which gzdoom-4-11-3` ]] && missingDependencies=yes\
    ! [[ `which scummvm-2-2-0` ]] && missingDependencies=yes\
    ! [[ `which scummvm-2-3-0-git15811-gf97bfb7ce1` ]] && missingDependencies=yes\
    ! [[ `which aria2c` ]] && missingDependencies=yes\
    ! [[ `which vlc` ]] && missingDependencies=yes\
    ! [[ `which wine` ]] && missingDependencies=yes\
else\
    missingDependencies=yes\
fi\
! [[ `which curl` ]] && missingDependencies=yes\
! [[ `which python3` ]] && missingDependencies=yes\
! [[ `which sed` ]] && missingDependencies=yes\
! [[ `which unzip` ]] && missingDependencies=yes\
! [[ `which wget` ]] && missingDependencies=yes\
\
if [ $missingDependencies == "yes" ]\
then\
    printf "\\n\\e[1;31;47mOne or more dependencies are missing.\\e[0m\\n\\n"\
    printf "Please run the \\e[1;33;40minstall_dependencies.command\\e[0m script.\\n"\
    printf "Then, follow the instructions to install the required dependencies.\\n"\
    read -s -n 1 -p "Press any key to abort."\
    printf "\\n\\n"\
    exit 0\
fi\
if [ -n "$HYPRLAND_INSTANCE_SIGNATURE" ]\
then\
    flatpak list --app --columns=application | grep "^com.retro_exo." | xargs -I {} flatpak override --user --env=SDL_VIDEODRIVER=x11 {}\
    flatpak list --app --columns=application | grep "^com.retro_exo." | xargs -I {} flatpak override --user --env=SDL_AUDIODRIVER=alsa {}\
fi\
' "$currentScript"
    
}

#print out an error message if this file is executed directly
if [[ $hideMessage != 'true' ]]
then
    printf "\n\e[1;31;47mThis file is a dependency that should %s\e[0m\n\n" \
           "not be executed directly."
    read -s -n 1 -p "Press any key to close."
    printf "\n\n"
    exit 0
fi
