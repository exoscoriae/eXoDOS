#!/usr/bin/env bash

usage="$(basename "$0") [-h] -- detects if it's running inside a known terminal emulator or finds a known binary

where:
    -h  show this help text

output:
    - exits with code 0 and no output if it's already running inside a terminal emulator
    - exits with code other that 0 and outputs a path to the binary followed by parameters needed for a specific emulator
"
while getopts ':h' option; do
  case "$option" in
    h) echo "$usage"
       exit
       ;;
    *) ;;
  esac
done
shift $((OPTIND - 1))

# add new emulators by using: terminal_emulators[binary_name]="parameters lookup_name"
# "binary_name" is the executable that should be run.
# "parameters" is a string that will be put between the executable and the common command
# "lookup_name" is used when the parent process of this script does not have the same name as the executable
declare -A terminal_emulators
terminal_emulators[konsole]="-e"
terminal_emulators[gnome-terminal]="--"
terminal_emulators[xfce4-terminal]="-x"
terminal_emulators[kgx]="-e"
terminal_emulators[xterm]="-e"
terminal_emulators[Eterm]="-e"
terminal_emulators[x-terminal-emulator]="-e"
terminal_emulators[mate-terminal]="-e"
terminal_emulators[terminator]="-x"
terminal_emulators[urxvt]="-e"
terminal_emulators[rxvt]="-e"
terminal_emulators[termit]="-e"
terminal_emulators[lxterm]="-e"
terminal_emulators[terminology]="-e"
terminal_emulators[tilix]="-e"
terminal_emulators[kitty]="-e"
terminal_emulators[aterm]="-e"
terminal_emulators[ptyxis]="-x ptyxis-agent"

function get_parent_binary
{
    ps -o sid= -p "$$" | xargs ps -o ppid= -p | xargs ps -o comm= -p
}

function get_lookup_name
{
    local binary_name=$1
    parameters_str=${terminal_emulators[$binary_name]}
    IFS=" " read -ra parameters <<< "$parameters_str"
    lookup_name_param=${parameters[1]}

    if [[ $lookup_name_param ]]
    then
        local lookup_name="$lookup_name_param"
    else
        local lookup_name="$binary_name"
    fi

    echo "$lookup_name"
}

function get_launch_parameter
{
    local binary_name=$1
    parameters_str=${terminal_emulators[$binary_name]}
    IFS=" " read -ra parameters <<< "$parameters_str"
    echo "${parameters[0]}"
}

function get_emulators_regex
{
    local lookup_names=()
    for binary_name in "${!terminal_emulators[@]}"
    do
        lookup_name=$(get_lookup_name "$binary_name")
        lookup_names+=("$lookup_name")
    done

    IFS="|" ; echo "^(${lookup_names[*]})"
}

function find_known_binary
{
    local binary_data
    for binary_name in "${!terminal_emulators[@]}"
    do
        binary_path=$(which "$binary_name" 2>/dev/null)
        if [[ $binary_path ]]
        then
            binary_data="$binary_name $binary_path"
        fi
    done

    echo "$binary_data"
}

parent_binary=$(get_parent_binary)

emulators_regex=$(get_emulators_regex)
if [[ "$parent_binary" =~ $emulators_regex ]]
then
    # If we are already in a terminal emulator, we don't need to spawn a new window
    exit 0
else
    # If we are started from desktop, or are not running in a familiar terminal emulator, 
    # start looking for existing binaries
    binary_data_str=$(find_known_binary)
    if [[ $binary_data_str ]]
    then
        IFS=" " read -ra binary_data <<< "$binary_data_str"
        binary_name="${binary_data[0]}"
        binary_path="${binary_data[1]}"
        launch_parameter=$(get_launch_parameter "$binary_name")
        echo "$binary_name $binary_path $launch_parameter"
        exit 0
    else
        echo "Weird system achievement unlocked: None of the 18 supported terminal emulators are installed."
        exit 1
    fi
fi
