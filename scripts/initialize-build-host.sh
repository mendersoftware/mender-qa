#!/bin/false

# This file should be sourced, not run.

# When sourced, this script will do several things:
#
# 1. Will wait for the cloud-init service to finish running, in order to enforce
#    serial execution of initialization steps. It will post the output when
#    finished, if any.
#
# 2. If $HOME/proxy-target.txt exists, it means this is a proxy host, and the
#    real build machine is on the host specified by the login details inside
#    that file. If the file does not exist, we are on the build slave itself.
#    After figuring that stuff out, this script will run either on_proxy() or
#    the rest of the original script that sourced this file, depending on
#    whether we are on the proxy or build host, respectively. Note that commands
#    that are specified *before* this script is sourced will run on both hosts,
#    so make sure this is sourced early, but after on_proxy() is defined.
#
# The script is expected to be sourced early in the init-script phase after
# provisioning.


# Keys that you can use to log in to the build slaves.
SSH_KEYS='
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCz3yWxbpXj49IYZgxtwjRNiF+wuu58Kq1QoiRH8Q9UPK4kA7gQf53GFvZj4W2QhzJvrKUwo67Aw/ywxWHxzBiNZCcRweB21E6WOK0DJe6+t/lXzzVl7eTmctfh5zsZLMbSSd4TM+05fMh/qjPN18Khb1zsvWP4rYfZcnhPWu2MoMOjbydwN4OlT8AxMVWZC+0rNqR7ghUlPHgGAY0dW/iGGodX6+wvoq5D2hNSeqxwKAW4/WEMHO0Vzl6DZIYtHB3h6U0KuGmPkZjj60oJvjWsJjWMZzdxvZNB373q8z9wgp+QdZYHiTKldi/mitWQT3c8nNFhFEE/8tNx7wMmdy5H lex@flower
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC6D4Pz1bR67BzEiPkEO0bTQ6aQU+U3fxOc9BDGhLgCIc5BzYIwe0DR+vEHcP92gIicnOs+k+noRcwbU11p2xcmi4SmjZdluKi2RVee8S0utiHB49oTEoPVe6C+1d/OmCYtao5mnarsJGOLMuAo7nQLUBkoeduYjqFdpILg3JjiD/RgYYJpu850SHJgIbpLHTABqPRG/fPaetJTrqAeKchm9y87EXWnC5eXl1+Lgqg3Lkbp1c+89bSQmjNdMlT9uPJJppqnzDtS71xJOp+AJIb3QqW2ZiOo9gKHv5Z8CfBREgv8wLHU/5cuXnHYrXAaoEAvZM1xZV0Tbwo+TpAknQgBERXIYsE/+ifNQ47hPPM9pBMoUod7SpdMH1Z+pdnodHswnYFUhQE40DmwFpqyEiUU9Q45KjOCLwneAxJvlfafqYmDLjei39EVconZufFo3K0uZ0P8Is1NDpYuqqAS3D9LM/kRkdX9+tO+oXudkWrFbdhL+YRikajucbWzp1pioJXDXgpKRs/FRfAVehqAVeE5PX9YrUZt+ANxH3K8Cia4TdWrwN1oSNLwehhPp/48MqxCRzYXQ4v1SayXIUf9EIai1N4q5q6x1yrrkOSrhJXmYOOFyeGqeGY+PPp55At22KY4SX8VqNZokEMs/3sZpEeDRGvEoAnGUgRc9EQIbSTfiw== greg@greg-ws
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDtfMHZ+GXw/10nSCuCZAYvMS7LElvjMGUd0wjTzQ7m4XaVmDY6SMpeW2ZHk2YXHmQDw5oUTWZ+pBQVk9J/iXrQfghtGS+akvnqDKy/OrNb2pXWToxGu9vaBkIp9VHgXsZAzCMs7vOZyXJSQgiMrL0oj9smcNsVr1+9+yFzuRgRgRRQ67JZWhb7J2A2DL8SAFfJUXpAdx1Sdzhx3C0tZ8Ptgz0bd0CoWVXBDva4z6MJq3jD4zM6MTmWfm0HGz1IOtVeUlEt7T30j8yIcSzxIlKT3Bs7EavlK2JJbU/7rb7sG/O2ih/Ovr23pgPsq0D7CGaWe01+Z9ivk0Ycp+cFGDZV dimitrios.apostolou@cfengine.com
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDDmlwzo9m1ypsusAp9cVj+XgmDBsZMPdZzIt15pM7Ay2Ie4dl0TtVpj/H9S5O5NsHkQ/fPEaWCpZGgbRrOsrb3wgMg0qM6pA5fvbmCBKxvdvCwp03FyATY0yC+OnvmnWtLOshdZX1gZjzQwiEG/UFyl0N5p/wu8cJv+ODWJ+EOLWs0yTie8oCV2XXFiRsby9qCwDCQIvXrbp1amZJOYNW49GNPKEoJgq6D9fZ5mYE/ozoUdW2ecIOWRWDMI+4AKv48JYPN/wtYJnUs/JmRHUc4HTZ7P9wsXLSc8F+9eVEWzGIZL8WuCS3L8V1n3tPJIxZhQKe3R8DcjER07M+0J9HP a10040@cflu-10040
ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAy6vrcU1d/80WMFqzumFHG/dllkhakswezvKfX7KupQwpc55JyyUNpnjxLy76leuJnlTTZTaxq1CcW3lIH9CjG/rJVQLN/PLjQPLZgfvzHqS8HuVCtKynwp0Sgw9tRmrN1KcXRiQMWs3plVDJwB4HFQpb7NsC0f5fskpgxr2KRNPn058oe6VYx183Err/0Uawy64aFSiowRgvHgXgelhSDWUVkOoviKR1zB11EZ8Xr5d4s/yXDE9ehlgv2EBFdhZrqsMmhs7KdPPNDD6/El2dID7V7LKHblbtVO009VS/dlq1XUGE0IUl153ZaVm/dt4+2+NriGpI7COAU4cLxhpj9w== cmdln@tp
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC/NLV9UQu5eXr/CE9NfnC6IsvLx+vvVDxpbIfOVNhBjpLHoXqLDVedAT4dn+82x+OulBXdYzZkEGoKlkBkbmxjsXBF6gX1oWFnSmdlZNEe+GqTcfRHL4+fF09oUh6tCdCBFaMLbkdA1M+UvYtJc8BZoNUXCVG/Sn0saVLDOFfmUG9ICfmVFzwcVW+X6+qfyauBC6lGtW/Bnqj6GY6VaSo94cYyLUFeUI1GbJ5sDmkFKBXn/p/1ks6eWlejcs2Q/mqqaH5sseek+0MP8qHss9HSZzbn9Iq4n1uUW43NBu242KISE/fDDqZtJs54zJmt97cDOgr+p0wglwFUT8x6Grl5 kristian@kristian-mender
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC5MGowxEkIXVweJId1Fmxp+EL+0e19xH8OPdwfc9daepPaT8SmYqVNq+YA6/PJUUr39oGgTdX6iK2dk5JW4OqgtcwotECspW7mVfF7izLapw/bpFOWryhJmVlYXKnwg61tcmZHMtVf+cSPcljyjAH+gULA+mzivikfKl9YHoHZI1BbxcqNUz5uJxw/WiZr9BLd+ZRw7D53HpNPGlfyHZOi+DzjZmmfdk9MqA/fiEoxw2nSXBE10n9bC/dxplvOvKvNXjVPFs/UpUpanY4AGsFCWM1+7z2c8LxpWanBLHYSVLH0Ung+uJVu6gtnSK4jKwWfPuHGJ6Qi7ZQo4Uyw90rN buildmaster@buildmaster
ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA3Jo+DWnGMqK2SoU9ZqBS/yFsrOy6GAKcMeKFV79Bp3nRCjSzgOhRI5lmTU9tSg5IHkBqiv0qjkEyaxjrV/rX5JGRrFfpJT0uuNcNvPTlhNuWnkdmv/Xy5zwU27AMdz2/kRsEPEdYWwch5wd7VV1xgxiJG0yGMCVeRpLYrUJpILt1LHMz+HYYjiz6dHxfCgcywCs7aaFS4Z//Idwm0XOnzpDpBb3tBCtQjiOY88N4xfGwUpx8A1+bq4Wg2pQ0RJxabvtLp9oJ1s5h9Be0ZUKwChAiqOlG6ATsYk/09Uwj3ypdPMjFYZ1HWuoKH1KkLmhwpw6K9Mg21loy0TEBGYIOSQ== root@buildmaster
'

#
# Detect and replace non-POSIX shell
#
try_exec() {
    type "$1" > /dev/null 2>&1 && exec "$@"
}

broken_posix_shell()
{
    unset foo
    local foo=1 || true
    test "$foo" != "1" || return $?
    return 0
}

if broken_posix_shell >/dev/null 2>&1; then
    try_exec /usr/xpg4/bin/sh "$0" "$@"
    echo "No compatible shell script interpreter found."
    echo "Please find a POSIX shell for your system."
    exit 42
fi

# Make sure error detection and verbose output is on, if they aren't already.
set -x -e


echo "Current user: $USER"
echo "IP information:"
/sbin/ifconfig -a || true
/sbin/ip addr || true


RSYNC="rsync --delete -czrlpt -T /tmp"
RSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no"

# Support launching scripts that were initially launched under bash.
if [ -n "$BASH_VERSION" ]
then
    SUBSHELL=bash
else
    SUBSHELL=sh
fi

# In the "user-data" script, i.e. the one that runs on VM boot by
# cloud-init process, there are a bunch of commands running even *after*
# the 222 port has been opened. Wait for it to complete.
while pgrep cloud-init >/dev/null 2>&1
do
    echo "Waiting 10 seconds until the cloud-init stage is done..."
    sleep 10
done

echo '========================================= PRINTING CLOUD-INIT LOG ==================================================='
sed 's/^.*/>>> &/' /var/log/cloud-init-output.log || true
echo '======================================= DONE PRINTING CLOUD-INIT LOG ================================================'

echo '=========================================== CURRENT ENVIRONMENT ====================================================='
export
echo '========================================= CURRENT ENVIRONMENT END ==================================================='

# Disable TTY requirement. This normally happens in initialize-user-data.sh, but
# for hosts that do not support cloud user data, it may not have happened
# yet. These hosts are always using root as login, since they cannot create any
# new users without the user data section. We still need to disable the TTY
# requirement, since even root will use sudo inside the scripts. If we are not
# root, we cannot do anything.
if [ "$(id -u)" = 0 ] && [ -f /etc/sudoers ]
then
    sed -i -e 's/^\( *Defaults *requiretty *\)$/# \1/' /etc/sudoers
fi

apt_get() {
    # Work around apt-get not waiting for a lock if it's taken. We want to wait
    # for it instead of bailing out. No good return code to check unfortunately,
    # so we just have to look inside the log.

    pid=$$
    # Maximum five minute wait (30 * 10 seconds)
    attempts=30

    while true
    do
        ( /usr/bin/apt-get "$@" 2>&1 ; echo $? > /tmp/apt-get-return-code.$pid.txt ) | tee /tmp/apt-get.$pid.log
        if [ $attempts -gt 0 ] && \
               [ "$(cat /tmp/apt-get-return-code.$pid.txt)" -ne 0 ] && \
               fgrep "Could not get lock" /tmp/apt-get.$pid.log > /dev/null
        then
            attempts=`expr $attempts - 1`
            sleep 10
        else
            break
        fi
    done

    rm -f /tmp/apt-get-return-code.$pid.txt /tmp/apt-get.$pid.log

    return "$(cat /tmp/apt-get-return-code.$pid.txt)"
}
alias apt=apt_get
alias apt-get=apt_get

if [ -f $HOME/proxy-target.txt ]
then
    ret=0
    on_proxy || ret=$?
    # Failure to find a function returns 127, so check for that specifically,
    # otherwise there was an error inside the function.
    if [ $ret -ne 0 -a $ret -ne 127 ]
    then
        exit $ret
    fi

    # --------------------------------------------------------------------------
    # Populate build host.
    # --------------------------------------------------------------------------

    login="$(cat $HOME/proxy-target.txt)"

    # Put our currently executing script on the proxy target.
    $RSYNC -e "$RSH"   "$0"  $login:commands-from-proxy.sh

    # And the important parts of the environment.
    for var in \
        BUILD_CAUSE \
        BUILD_CAUSE_UPSTREAMTRIGGER \
        BUILD_DISPLAY_NAME \
        BUILD_ID \
        BUILD_NUMBER \
        BUILD_TAG \
        BUILD_URL \
        EXECUTOR_NUMBER \
        HUDSON_COOKIE \
        HUDSON_HOME \
        HUDSON_SERVER_COOKIE \
        HUDSON_URL \
        JENKINS_HOME \
        JENKINS_SERVER_COOKIE \
        JENKINS_URL \
        JOB_BASE_NAME \
        JOB_NAME \
        JOB_URL \
        LOGNAME \
        NODE_LABELS \
        NODE_NAME \
        ROOT_BUILD_CAUSE \
        ROOT_BUILD_CAUSE_MANUALTRIGGER \
        WORKSPACE \
        label
    do
        case "$var" in
            WORKSPACE)
                # Special handling for WORKSPACE, because local and remote home
                # directory might not be the same.
                WORKSPACE_REMOTE="$(echo "$WORKSPACE" | sed -e "s,^$HOME/*,,")"
                echo "WORKSPACE=\"\$HOME/$WORKSPACE_REMOTE\""
                echo "export WORKSPACE"
                ;;
            *)
                eval "echo $var=\\\"\$$var\\\""
                echo "export $var"
                ;;
        esac
    done > env.sh
    $RSYNC -e "$RSH"    env.sh  $login:.

    # And the helper tools, including this script.
    # Note that only provisioned hosts will have this in HOME, since they use
    # the repository in provisioning. Permanent hosts don't keep it in HOME,
    # in order to avoid it getting stale, and will have it in the WORKSPACE
    # instead, synced separately below.
    if [ -d $HOME/mender-qa ]
    then
        $RSYNC -e "$RSH"    $HOME/mender-qa  $login:.
    fi

    # Copy the workspace. If there is no workspace defined, we are not in the
    # job section yet.
    if [ -n "$WORKSPACE" ]
    then
        $RSH  $login  mkdir -p "$WORKSPACE_REMOTE"
        $RSYNC -e "$RSH"    "$WORKSPACE"/  $login:"$WORKSPACE_REMOTE"/
    fi

    # * In multi-matrix jobs, "label" is the label of the node because we
    #   selected to set that variable in the configuration matrix.
    #
    # * In other jobs, label is unset so we set it to the first label
    #   that the node provides in NODE_LABELS, which might not be the
    #   one that we build now (!)

    if [ x"$label" = x ]  &&  [ x"$NODE_LABELS" != x ]
    then
        # There can be multiple labels in NODE_LABELS, pick the first one.
        # The last one is usually the node name.
        label=${NODE_LABELS%% *}
    fi

    # Copy the build cache, if there is one, and only if the node has a known
    # label.
    if [ x"$label" != x ]
    then

        # Clean up spurious garbage
        find $HOME/.cache/*/ -type f -size 0  |  xargs rm -f

        if [ -d $HOME/.cache/cfengine-buildscripts-distfiles ]
        then
            $RSH  $login  mkdir -p .cache
            $RSYNC -e "$RSH"                                        \
                   $HOME/.cache/cfengine-buildscripts-distfiles/    \
                  $login:.cache/cfengine-buildscripts-distfiles/
        fi

        if [ -d $HOME/.cache/cfengine-buildscripts-pkgs ]
        then
            mkdir -p $HOME/.cache/cfengine-buildscripts-pkgs/$label
            $RSH  $login  mkdir -p .cache/cfengine-buildscripts-pkgs/$label
            $RSYNC -e "$RSH"                                          \
                   $HOME/.cache/cfengine-buildscripts-pkgs/$label/    \
                  $login:.cache/cfengine-buildscripts-pkgs/$label/
        fi
    fi

    # --------------------------------------------------------------------------
    # Run the actual job.
    # --------------------------------------------------------------------------
    echo "Entering proxy target $login"
    ret=0
    $RSH  $login \
        ". ./env.sh && cd \$WORKSPACE && $SUBSHELL \$HOME/commands-from-proxy.sh" "$@" \
        || ret=$?
    echo "Leaving proxy target $login"

    # --------------------------------------------------------------------------
    # Collect artifacts and cleanup.
    # --------------------------------------------------------------------------
    # Copy the workspace back after job has ended.
    if [ -n "$WORKSPACE" ]
    then
        $RSYNC -e "$RSH"    $login:"$WORKSPACE_REMOTE"/  "$WORKSPACE"/
    fi

    # Copy the build cache back in order to be preserved.
    if [ x"$label" != x ]
    then

        # Clean up spurious garbage
        $RSH $login \
             "find .cache/*/ -type f -size 0  |  xargs rm -f"

        if [ -d $HOME/.cache/cfengine-buildscripts-distfiles ]
        then
            $RSYNC -e "$RSH"                                       \
                   $login:.cache/cfengine-buildscripts-distfiles/  \
                    $HOME/.cache/cfengine-buildscripts-distfiles/
        fi

        if [ -d $HOME/.cache/cfengine-buildscripts-pkgs ]
        then
            $RSYNC -e "$RSH"                                         \
                   $login:.cache/cfengine-buildscripts-pkgs/$label/  \
                    $HOME/.cache/cfengine-buildscripts-pkgs/$label/
        fi
    fi

    # Return the error code from the job.
    exit $ret
elif [ -z "$INIT_BUILD_HOST_SUB_INVOKATION" ]
then
    (
        # Switch to newline as token separator.
        IFS='
'
        # Add key, but avoid adding it more than once (important for always-on
        # build slaves).
        for key in $SSH_KEYS
        do
            if ! fgrep "$key" ~/.ssh/authorized_keys > /dev/null
            then
                echo "$key" >> ~/.ssh/authorized_keys
            fi
        done
    )

    # Add build-artifacts-cache to known hosts
    KNOWN_HOSTS_FILE=/home/jenkins/.ssh/known_hosts
    # if fgrep build-artifacts-cache.cloud.cfengine.com $KNOWN_HOSTS_FILE  2>/dev/null
    # then
    #     :
    # else
        echo "build-artifacts-cache.cloud.cfengine.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC6qcxCQgtubv9WEhrAyMEFFMLLEjirk0p0Ru+vATioEIyw7gBFfOWOp/dBfsF6fuiY1vt3IsBx4u1DkS4j8x7DjB8X2dIcBia2jt2D3sBdDFb/nc7ZnWfFf/E7dWoiF0WKvxZ62RwjyZuyz9TmL1d3jlIyuRimkhgwnuRAMyymJ5YbxvvfTH01OuGS/0pkqkLAxomRyJTv6qcGr1rOPd5FuySwOO5M/tGkajJppKC+8u/RCyWfgu1khrBmi6PevXTaoJ/lQyexexZK0HVsA5G1U/+ipO18DqaCCAnHvZ/AKt+yYmoe9RtLfx0T7DHinEV1yj4ynUj7EqudCrLOorg5 root@yoctobuild-sstate-cache"  > $KNOWN_HOSTS_FILE
    # fi

    # Reexecute script in order to be able to collect the return code, and
    # potentially stop the slave.
    rsync -czt "$0" $HOME/commands.sh
    ret=0
    env INIT_BUILD_HOST_SUB_INVOKATION=1 $SUBSHELL $HOME/commands.sh || ret=$?

    if [ -f "$HOME/stop_slave" ]
    then
        echo "Stopping slave due to $HOME/stop_slave."
        echo "Will keep it stopped until the file is removed."
        while [ -f "$HOME/stop_slave" ]
        do
            sleep 10
        done
    fi

    exit $ret
fi

# Else continue executing rest of calling script.
