#!/bin/bash

# Copyright (C) 2011, 2012, 2013, 2014, 2016 Joerg Jaspert <joerg@debian.org>
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# .
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# .
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
# NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# Always exit on errors
set -e
# Undefined variables, we don't like you
set -u
# ERR traps are inherited by shell functions, command substitutions and
# commands executed in a subshell environment.
set -E

########################################################################
# The following variables can be overwritten outside the script.
#

# We want a useful tmpdir, so set one if it isn't already.  Thats the
# place where tmux puts its socket, so you want to ensure it doesn't
# change under your feet - like for those with a daily-changing tmpdir
# in their home...
declare -r TMPDIR=${TMPDIR:-"/tmp"}

# Do you want me to sort the arguments when opening an ssh/multi-ssh session?
# The only use of the sorted list is for the session name, to allow you to
# get the same session again no matter how you order the hosts on commandline.
declare -r TMSORT=${TMSORT:-"true"}

# Want some extra options given to tmux? Define TMOPTS in your environment.
# Note, this is only used in the final tmux call where we actually
# attach to the session!
TMOPTS=${TMOPTS:-"-2"}

# The following directory can hold session config for us, so you can use them
# as a shortcut.
declare -r TMDIR=${TMDIR:-"${HOME}/.tmux.d"}

# Should we prepend the hostname to autogenerated session names?
# Example: Call tm ms host1 host2.
# TMSESSHOST=true  -> session name is HOSTNAME_host1_host2
# TMSESSHOST=false -> session name is host1_host2
declare -r TMSESSHOST=${TMSESSHOST:-"true"}

# Allow to globally define a custom ssh command line.
TMSSHCMD=${TMSSHCMD:-"ssh"}

# Debug output
declare -r DEBUG=${DEBUG:-"false"}

# Save the last argument, it may be used (traditional style) for
# replacing
args=$#
TMREPARG=${!args}

# Where does your tmux starts numbering its windows? Mine does at 1,
# default for tmux is 0. We try to find it out, but if we fail, (as we
# only check $HOME/.tmux.conf you can set this variable to whatever it
# is for your environment.
if [[ -f ${HOME}/.tmux.conf ]]; then
    bindex=$(grep ' base-index ' ${HOME}/.tmux.conf || echo 0 )
    bindex=${bindex//* }
else
    bindex=0
fi
declare TMWIN=${TMWIN:-$bindex}
unset bindex

########################################################################
# Nothing below here to configure

# Should we open another session, even if we already have one with
# this name? (Ie. second multisession to the same set of hosts)
# This is either set by the getopts option -n or by having -n
# as very first parameter after the tm command
if [[ $# -ge 1 ]] && [[ "${1}" = "-n" ]]; then
    DOUBLENAME=true
    # And now get rid of it. getopts won't see it, as it was first and
    # we remove it - but it doesn't matter, we set it already.
    # getopts is only used if it appears somewhere else in the
    # commandline
    shift
else
    DOUBLENAME=false
fi

# Store the first commandline parameter
cmdline=${1:-""}

# Get the tmux version and split it in major/minor
TMUXVERS=$(tmux -V 2>/dev/null || echo "tmux 1.3")
declare -r TMUXVERS=${TMUXVERS##* }
declare -r TMUXMAJOR=${TMUXVERS%%.*}
declare -r TMUXMINOR=${TMUXVERS##*.}

# Save IFS
declare -r OLDIFS=${IFS}

# To save session file data
TMDATA=""

# Freeform .cfg file or other session file?
TMSESCFG=""

########################################################################
function usage() {
    echo "tmux helper by Joerg Jaspert <joerg@ganneff.de>"
    echo "There are two ways to call it. Traditional and \"getopts\" style."
    echo "Traditional call as: $0 CMD [host]...[host]"
    echo "Getopts call as: $0 [-s host] [-m hostlist] [-k name] [-l] [-n] [-h] [-c config] [-e]"
    echo ""
    echo "Traditional:"
    echo "CMD is one of"
    echo " ls          List running sessions"
    echo " s           Open ssh session to host"
    echo " ms          Open multi ssh sessions to hosts, synchronizing input"
    echo "             To open a second session to the same set of hosts put a"
    echo "             -n in front of ms"
    echo " k           Kill a session. Note that this needs the exact session name"
    echo "             as shown by tm ls"
    echo " \$anything   Either plain tmux session with name of \$anything or"
    echo "             session according to TMDIR file"
    echo ""
    echo "Getopts style:"
    echo "-l           List running sessions"
    echo "-s host      Open ssh session to host"
    echo "-m hostlist  Open multi ssh sessions to hosts, synchronizing input"
    echo "             Due to the way getopts works, hostlist must be enclosed in \"\""
    echo "-n           Open a second session to the same set of hosts"
    echo "-k name      Kill a session. Note that this needs the exact session name"
    echo "             as shown by tm ls"
    echo "-c config    Setup session according to TMDIR file"
    echo "-e SESSION   Use existion session named SESSION"
    echo "-r REPLACE   Value to use for replacing in session files"
    echo ""
    echo "TMDIR file:"
    echo "Each file in \$TMDIR defines a tmux session. There are two types of files,"
    echo "those without an extension and those with the extension \".cfg\" (no \"\")."
    echo "The filename corresponds to the commandline \$anything (or -c)."
    echo ""
    echo "Content of extensionless files is defined as:"
    echo "  First line: Session name"
    echo "  Second line: extra tmux commandline options"
    echo "  Any following line: A hostname to open a shell with in the normal"
    echo "                      ssh syntax. (ie [user@]hostname)"
    echo ""
    echo "Content of .cfg files is defined as:"
    echo "  First line: Session name"
    echo "  Second line: extra tmux commandline options"
    echo "  Third line: The new-session command to use. Place NONE here if you want plain"
    echo "              defaults, though that may mean just a shell. Otherwise put the full"
    echo "              new-session command with all options you want here."
    echo "  Any following line: Any tmux command you can find in the tmux manpage."
    echo "              You should ensure that commands arrive at the right tmux session / window."
    echo "              To help you with this, there are some variables available which you"
    echo "              can use, they are replaced with values right before commands are executed:"
    echo "              SESSION - replaced with the session name"
    echo "              TMWIN   - see below for explanation of TMWIN Environment variable"
    echo ""
    echo "NOTE: Both types of files accept external listings of hostnames."
    echo "      That is, the output of any shell command given will be used as a list"
    echo "      of hostnames to connect to (or a set of tmux commands to run)."
    echo ""
    echo "NOTE: Session files can include the Token ++TMREPLACETM++ at any point. This"
    echo "      will be replaced by the value of the -r option (if you use getopts style) or"
    echo "      by the LAST argument on the line if you use traditional calling."
    echo "      Note that with traditional calling, the argument will also be tried as a hostname,"
    echo "      so it may not make much sense there, unless using a session file that contains"
    echo "      solely of LIST commands."
    echo ""
    echo "NOTE: Session files can include any existing environment variable at any point (but"
    echo "      only one per line). Those get replaced during tm execution time with the actual"
    echo "      value of the environment variable. Common usage is $HOME, but any existing var"
    echo "      works fine."
    echo ""
    echo "Environment variables recognized by this script:"
    echo "TMPDIR     - Where tmux stores its session information"
    echo "             DEFAULT: If unset: /tmp"
    echo "TMSORT     - Should ms sort the hostnames, so it always opens the same"
    echo "             session, no matter in which order hostnames are presented"
    echo "             DEFAULT: true"
    echo "TMOPTS     - Extra options to give to the tmux call"
    echo "             Note that this ONLY affects the final tmux call to attach"
    echo "             to the session, not to the earlier ones creating it"
    echo "             DEFAULT: -2"
    echo "TMDIR      - Where are session information files stored"
    echo "             DEFAULT: ${HOME}/.tmux.d"
    echo "TMWIN      - Where does your tmux starts numbering its windows?"
    echo "             This script tries to find the information in your config,"
    echo "             but as it only checks $HOME/.tmux.conf it might fail".
    echo "             So if your window numbers start at anything different to 0,"
    echo "             like mine do at 1, then you can set TMWIN to 1"
    echo "TMSESSHOST - Should the hostname appear in session names?"
    echo "             DEFAULT: true"
    echo "TMSSHCMD   - Allow to globally define a custom ssh command line."
    echo "             This can be just the command or any option one wishes to have"
    echo "             everywhere."
    echo "             DEFAULT: ssh"
    echo "DEBUG      - Show debug output (remember to redirect it to a file)"
    echo ""
    exit 42
}

# Simple "cleanup" of a variable, removing space and dots as we don't
# want them in our tmux session name
function clean_session() {
    local toclean=${*:-""}

    # Neither space nor dot nor : or " are friends in the SESSION name
    toclean=${toclean// /_}
    toclean=${toclean//:/_}
    toclean=${toclean//\"/}
    echo ${toclean//./_}
}

# Merge the commandline parameters (hosts) into a usable session name
# for tmux
function ssh_sessname() {
    if [[ ${TMSORT} = true ]]; then
        local one=$1
        # get rid of first argument (s|ms), we don't want to sort this
        shift
        local sess=$(for i in $*; do echo $i; done | sort | tr '\n' ' ')
        sess="${one} ${sess% *}"
    else
        # no sorting wanted
        local sess="${*}"
    fi
    clean_session ${sess}
}

# Setup functions for all tmux commands
function setup_command_aliases() {
    local command
    local SESNAME
    SESNAME="tmlscm$$"
    # Debian Bug #718777 - tmux needs a session to have lscm work
    tmux new-session -d -s ${SESNAME} -n "check" "sleep 3"
    for command in $(tmux list-commands|awk '{print $1}'); do
        eval "$(echo "tm_$command() { tmux $command \"\$@\" >/dev/null; }")"
    done
    tmux kill-session -t ${SESNAME} || true
}

# Run a command (function) after replacing variables
function do_cmd() {
    local cmd=$@
    cmd1=${cmd%% *}
    if [[ ${cmd1} =~ ^# ]]; then
        return
    elif  [[ ${cmd1} =~ new-window ]]; then
        TMWIN=$(( TMWIN + 1 ))
    fi

    cmd=${cmd//SESSION/$SESSION}
    cmd=${cmd//TMWIN/$TMWIN}
    cmd=${cmd/$cmd1 /}
    debug tm_$cmd1 $cmd
    eval tm_$cmd1 $cmd
}

# Use a configuration file to setup the tmux parameters/session
function own_config() {
    if [[ ${1} =~ .cfg$ ]]; then
        TMSESCFG="free"
    fi
    # Set IFS to be NEWLINE only, not also space/tab, as our input files
    # are \n seperated (one entry per line) and lines may well have spaces.
    local IFS="
"
    # Fill an array with our config
    TMDATA=( $(cat "${TMDIR}/$1" | sed -e "s/++TMREPLACETM++/${TMREPARG}/g") )
    # Restore IFS
    IFS=${OLDIFS}

    SESSION=$(clean_session ${TMDATA[0]})

    if [ "${TMDATA[1]}" != "NONE" ]; then
        TMOPTS=${TMDATA[1]}
    fi

    # Seperate the lines we work with
    local IFS=""
    local -a workdata=(${TMDATA[@]:2})
    IFS=${OLDIFS}

    # Lines (starting with line 3) may start with LIST, then we get
    # the list of hosts from elsewhere. So if one does, we exec the
    # command given, then append the output to TMDATA - while deleting
    # the actual line with LIST in.
    local TMPDATA=$(mktemp -u -p ${TMPDIR} .tmux_tm_XXXXXXXXXX)
    trap "rm -f ${TMPDATA}" EXIT ERR HUP INT QUIT TERM
    local index=0
    while [[ ${index} -lt ${#workdata[@]} ]]; do
        if [[ "${workdata[${index}]}" =~ ^LIST\ (.*)$ ]]; then
            # printf -- 'workdata: %s\n' "${workdata[@]}"
            local cmd=${BASH_REMATCH[1]}
            if [[ ${cmd} =~ \$\{([0-9a-zA-Z_]+)\} ]]; then
                repvar=${BASH_REMATCH[1]}
                reptext=${!repvar}
                cmd=${cmd//\$\{$repvar\}/$reptext}
            fi
            echo "Line ${index}: Fetching hostnames using provided shell command '${cmd}', please stand by..."

            $( ${cmd} >| "${TMPDATA}" )
            # Set IFS to be NEWLINE only, not also space/tab, the list may have ssh options
            # and what not, so \n is our seperator, not more.
            IFS="
"
            out=( $(cat "${TMPDATA}" | tr -d '\r' ) )

            # Restore IFS
            IFS=${OLDIFS}

            workdata+=( "${out[@]}" )
            unset workdata[${index}]
            unset out
            # printf -- 'workdata: %s\n' "${workdata[@]}"
        elif [[ "${workdata[${index}]}" =~ ^SSHCMD\ (.*)$ ]]; then
            TMSSHCMD=${BASH_REMATCH[1]}
        fi
        index=$(( index + 1 ))
    done
    rm -f "${TMPDATA}"
    trap - EXIT ERR HUP INT QUIT TERM
    TMDATA=( "${TMDATA[@]:0:2}" "${workdata[@]}"  )
}

# Simple overview of running sessions
function list_sessions() {
    local IFS=""
    if output=$(tmux list-sessions 2>/dev/null); then
        echo $output
    else
        echo "No tmux sessions available"
    fi
}

# We either have a debug function that shows output, or one that
# plainly returns
if [[ ${DEBUG} == true ]]; then
        eval "$(echo "debug() { echo \"\$@\" ; }")"
else
        eval "$(echo "debug() { :; }")"
fi

setup_command_aliases

########################################################################
# MAIN work follows here
# Check the first cmdline parameter, we might want to prepare something
case ${cmdline} in
    ls)
        list_sessions
        exit 0
        ;;
    s|ms|k)
        # Yay, we want ssh to a remote host - or even a multi session setup - or kill one
        # So we have to prepare our session name to fit in what tmux (and shell)
        # allow us to have. And so that we can reopen an existing session, if called
        # with the same hosts again.
        SESSION=$(ssh_sessname $@)
        declare -r cmdline
        shift
        ;;
    -*)
        while getopts "lnhs:m:c:e:r:k:" OPTION; do
            case ${OPTION} in
                l) # ls
                    list_sessions
                    exit 0
                    ;;
                s) # ssh
                    SESSION=$(ssh_sessname s ${OPTARG})
                    declare -r cmdline=s
                    shift
                    ;;
                k) # kill session
                    SESSION=$(ssh_sessname s ${OPTARG})
                    declare -r cmdline=k
                    shift
                    ;;
                m) # ms (needs hostnames in "")
                    SESSION=$(ssh_sessname ms ${OPTARG})
                    declare -r cmdline=ms
                    shift
                    ;;
                c) # pre-defined config
                    own_config ${OPTARG}
                    ;;
                e) # existing session name
                    SESSION=$(clean_session ${OPTARG})
                    ;;
                n) # new session even if same name one already exists
                    DOUBLENAME=true
                    ;;
                r) # replacement arg
                    TMREPARG=${OPTARG}
                    ;;
                h)
                    usage
                    ;;
            esac
        done
        ;;
    *)
        # Nothing special (or something in our tmux.d)
        if [ $# -lt 1 ]; then
            SESSION=${SESSION:-""}
            if [[ -n "${SESSION}" ]]; then
                # Environment has SESSION set, wherever from. So lets
                # see if its an actual tmux session
                if ! tmux has-session -t "${SESSION}" 2>/dev/null; then
                    # It is not. And no argument. Show usage
                    usage
                fi
            else
                usage
            fi
        elif [ -r "${TMDIR}/${cmdline}" ]; then
            own_config $1
        else
            # Not a config file, so just session name.
            SESSION=${cmdline}
        fi
        ;;
esac

# And now check if we would end up with a doubled session name.
# If so add something "random" to the new name, like our pid.
if [[ ${DOUBLENAME} == true ]] && tmux has-session -t ${SESSION} 2>/dev/null; then
    # Session exist but we are asked to open another one,
    # so adjust our session name
    if [[ ${#TMDATA} -eq 0 ]] && [[ ${SESSION} =~ ([ms]+)_(.*) ]]; then
        SESSION="${BASH_REMATCH[1]}_$$_${BASH_REMATCH[2]}"
    else
        SESSION="$$_${SESSION}"
    fi
fi

if [[ ${TMSESSHOST} = true ]]; then
    declare -r SESSION="$(uname -n|cut -d. -f1)_${SESSION}"
else
    declare -r SESSION
fi

# We only do special work if the SESSION does not already exist.
if [[ ${cmdline} != k ]] && ! tmux has-session -t ${SESSION} 2>/dev/null; then
    # In case we want some extra things...
    # Check stupid users
    if [ $# -lt 1 ]; then
        usage
    fi
    tm_pane_error="create pane failed: pane too small"
    case ${cmdline} in
        s)
            # The user wants to open ssh to one or more hosts
            do_cmd new-session -d -s ${SESSION} -n "${1}" "${TMSSHCMD} ${1}"
            # We disable any automated renaming, as that lets tmux set
            # the pane title to the process running in the pane. Which
            # means you can end up with tons of "bash". With this
            # disabled you will have panes named after the host.
            do_cmd set-window-option -t ${SESSION} automatic-rename off >/dev/null
            # If we have at least tmux 1.7, allow-rename works, such also disabling
            # any rename based on shell escape codes.
            if [ ${TMUXMINOR//[!0-9]/} -ge 7 ] || [ ${TMUXMAJOR//[!0-9]/} -gt 1 ]; then
                do_cmd set-window-option -t ${SESSION} allow-rename off >/dev/null
            fi
            shift
            count=2
            while [ $# -gt 0 ]; do
                do_cmd new-window -d -t ${SESSION}:${count} -n "${1}" "${TMSSHCMD} ${1}"
                do_cmd set-window-option -t ${SESSION}:${count} automatic-rename off >/dev/null
                # If we have at least tmux 1.7, allow-rename works, such also disabling
                # any rename based on shell escape codes.
                if [ ${TMUXMINOR//[!0-9]/} -ge 7 ] || [ ${TMUXMAJOR//[!0-9]/} -gt 1 ]; then
                    do_cmd set-window-option -t ${SESSION}:${count} allow-rename off >/dev/null
                fi
                count=$(( count + 1 ))
                shift
            done
            ;;
        ms)
            # We open a multisession window. That is, we tile the window as many times
            # as we have hosts, display them all and have the user input send to all
            # of them at once.
            do_cmd new-session -d -s ${SESSION} -n "Multisession" "${TMSSHCMD} ${1}"
            shift
            while [ $# -gt 0 ]; do
                set +e
                output=$(do_cmd split-window -d -t ${SESSION}:${TMWIN} "${TMSSHCMD} ${1}" 2>&1)
                ret=$?
                set -e
                if [[ ${ret} -ne 0 ]] && [[ ${output} == ${tm_pane_error} ]]; then
                    # No more space -> have tmux redo the
                    # layout, so all windows are evenly sized.
                    do_cmd select-layout -t ${SESSION}:${TMWIN} main-horizontal >/dev/null
                    # And dont shift parameter away
                    continue
                fi
                shift
            done
            # Now synchronize them
            do_cmd set-window-option -t ${SESSION}:${TMWIN} synchronize-pane >/dev/null
            # And set a final layout which ensures they all have about the same size
            do_cmd select-layout -t ${SESSION}:${TMWIN} tiled >/dev/null
            ;;
        *)
            # Whatever string, so either a plain session or something from our tmux.d
            if [ -z "${TMDATA}" ]; then
                # the easy case, just a plain session name
                do_cmd new-session -d -s ${SESSION}
            else
                # data in our data array, the user wants his own config
                if [[ ${TMSESCFG} = free ]]; then
                    if [[ ${TMDATA[2]} = NONE ]]; then
                        # We have a free form config where we get the actual tmux commands
                        # supplied by the user, so just issue them after creating the session.
                        do_cmd new-session -d -s ${SESSION} -n "${TMDATA[0]}"
                    else
                        do_cmd ${TMDATA[2]}
                    fi
                    tmcount=${#TMDATA[@]}
                    index=3
                    while [ ${index} -lt ${tmcount} ]; do
                        do_cmd ${TMDATA[$index]}
                        (( index++ ))
                    done
                else
                    # So lets start with the "first" line, before dropping into a loop
                    do_cmd new-session -d -s ${SESSION} -n "${TMDATA[0]}" "${TMSSHCMD} ${TMDATA[2]}"

                    tmcount=${#TMDATA[@]}
                    index=3
                    while [ ${index} -lt ${tmcount} ]; do
                        # List of hostnames, open a new connection per line
                        set +e
                        output=$(do_cmd split-window -d -t ${SESSION}:${TMWIN} "${TMSSHCMD} ${TMDATA[$index]}" 2>&1)
                        set -e
                        if [[ ${output} == ${tm_pane_error} ]]; then
                            # No more space -> have tmux redo the
                            # layout, so all windows are evenly sized.
                            do_cmd select-layout -t ${SESSION}:${TMWIN} main-horizontal >/dev/null
                            # And again, don't increase index
                            continue
                        fi
                        (( index++ ))
                    done
                    # Now synchronize them
                    do_cmd set-window-option -t ${SESSION}:${TMWIN} synchronize-pane >/dev/null
                    # And set a final layout which ensures they all have about the same size
                    do_cmd select-layout -t ${SESSION}:${TMWIN} tiled >/dev/null
                fi
            fi
            ;;
    esac
    # Build up new session, ensure we start in the first window
    do_cmd select-window -t ${SESSION}:${TMWIN}
elif [[ ${cmdline} == k ]]; then
    # So we are asked to kill a session
    tokill=${SESSION//k_/}
    do_cmd kill-session -t ${tokill}
    exit 0
fi

# And last, but not least, attach to it
tmux ${TMOPTS} attach -t ${SESSION}
