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
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDXzoc7eDTKoxfuz2Q0syRh7Z7J/N1YN7kA/J8HmpAmsKCUxrgFpL0eUSk92Ki6yGop3zhO+oEXsmKZAxCk9NAF9Pm4cf8eCn0hTRgz60RHS7rGSDSt7ceCLqimrTj/BWRC2JH1NSgD1L5g2zIJ6kYfBBLw0yOIBUz1ZESbOC3s3yAMfXzYqf0qL75ajqOuzdnynWc5FeJc8dJheQAh7ANDiXJ6XjPJJh0dvuMszmLMfacbILacfoGzz4UnIco1iI1kmNzuHs6XcJgXWzC1LBJwlDBWV75+f23NIynOtCyXRFxlC1K3Nj1X18ddGUdXCIVApr0HZWhMZXMZlRDbmMeRbyykzsm5ZDDerczQyfGPa/CANqxExrmun0peCeMSDj4HeDhpZWyI76w5sDAbv+aw5LlicOOKk8k/cox+vxpsXqUrdxRbKF376lX270ptzJHQ+AZfS3q4ZZiGTnOX7nTd4b29Yr3DTsJOZDW1maOjmCO0TYvndh1bNWVxXod7tJFFI1xZ7Zc4HJXy7QE2SIZG5BOOuyMN6LKJM1fpeIb3auLGMV+w4JDcd0JWeaJIVcimAhd8EEQehWLUDKuhRQkjG/XJHWxKL42ymNp/6waH3i7EkyNRzEisza60Px1SPXCy8TG+ERUL6sIirlg6rc0ChyxYvW1CFrPyE2xQg5sfVw== sub@krutt.org
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC6D4Pz1bR67BzEiPkEO0bTQ6aQU+U3fxOc9BDGhLgCIc5BzYIwe0DR+vEHcP92gIicnOs+k+noRcwbU11p2xcmi4SmjZdluKi2RVee8S0utiHB49oTEoPVe6C+1d/OmCYtao5mnarsJGOLMuAo7nQLUBkoeduYjqFdpILg3JjiD/RgYYJpu850SHJgIbpLHTABqPRG/fPaetJTrqAeKchm9y87EXWnC5eXl1+Lgqg3Lkbp1c+89bSQmjNdMlT9uPJJppqnzDtS71xJOp+AJIb3QqW2ZiOo9gKHv5Z8CfBREgv8wLHU/5cuXnHYrXAaoEAvZM1xZV0Tbwo+TpAknQgBERXIYsE/+ifNQ47hPPM9pBMoUod7SpdMH1Z+pdnodHswnYFUhQE40DmwFpqyEiUU9Q45KjOCLwneAxJvlfafqYmDLjei39EVconZufFo3K0uZ0P8Is1NDpYuqqAS3D9LM/kRkdX9+tO+oXudkWrFbdhL+YRikajucbWzp1pioJXDXgpKRs/FRfAVehqAVeE5PX9YrUZt+ANxH3K8Cia4TdWrwN1oSNLwehhPp/48MqxCRzYXQ4v1SayXIUf9EIai1N4q5q6x1yrrkOSrhJXmYOOFyeGqeGY+PPp55At22KY4SX8VqNZokEMs/3sZpEeDRGvEoAnGUgRc9EQIbSTfiw== greg@greg-ws
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDtfMHZ+GXw/10nSCuCZAYvMS7LElvjMGUd0wjTzQ7m4XaVmDY6SMpeW2ZHk2YXHmQDw5oUTWZ+pBQVk9J/iXrQfghtGS+akvnqDKy/OrNb2pXWToxGu9vaBkIp9VHgXsZAzCMs7vOZyXJSQgiMrL0oj9smcNsVr1+9+yFzuRgRgRRQ67JZWhb7J2A2DL8SAFfJUXpAdx1Sdzhx3C0tZ8Ptgz0bd0CoWVXBDva4z6MJq3jD4zM6MTmWfm0HGz1IOtVeUlEt7T30j8yIcSzxIlKT3Bs7EavlK2JJbU/7rb7sG/O2ih/Ovr23pgPsq0D7CGaWe01+Z9ivk0Ycp+cFGDZV dimitrios.apostolou@cfengine.com
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDDmlwzo9m1ypsusAp9cVj+XgmDBsZMPdZzIt15pM7Ay2Ie4dl0TtVpj/H9S5O5NsHkQ/fPEaWCpZGgbRrOsrb3wgMg0qM6pA5fvbmCBKxvdvCwp03FyATY0yC+OnvmnWtLOshdZX1gZjzQwiEG/UFyl0N5p/wu8cJv+ODWJ+EOLWs0yTie8oCV2XXFiRsby9qCwDCQIvXrbp1amZJOYNW49GNPKEoJgq6D9fZ5mYE/ozoUdW2ecIOWRWDMI+4AKv48JYPN/wtYJnUs/JmRHUc4HTZ7P9wsXLSc8F+9eVEWzGIZL8WuCS3L8V1n3tPJIxZhQKe3R8DcjER07M+0J9HP a10040@cflu-10040
ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAy6vrcU1d/80WMFqzumFHG/dllkhakswezvKfX7KupQwpc55JyyUNpnjxLy76leuJnlTTZTaxq1CcW3lIH9CjG/rJVQLN/PLjQPLZgfvzHqS8HuVCtKynwp0Sgw9tRmrN1KcXRiQMWs3plVDJwB4HFQpb7NsC0f5fskpgxr2KRNPn058oe6VYx183Err/0Uawy64aFSiowRgvHgXgelhSDWUVkOoviKR1zB11EZ8Xr5d4s/yXDE9ehlgv2EBFdhZrqsMmhs7KdPPNDD6/El2dID7V7LKHblbtVO009VS/dlq1XUGE0IUl153ZaVm/dt4+2+NriGpI7COAU4cLxhpj9w== cmdln@tp
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


RSYNC="rsync --delete -czrlpte 'ssh -o BatchMode=yes -o StrictHostKeyChecking=no'"


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
    $RSYNC   "$0"  $login:commands-from-proxy.sh

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
    $RSYNC    env.sh  $login:.

    # And the helper tools, including this script.
    # Note that only provisioned hosts will have this in HOME, since they use
    # the repository in provisioning. Permanent hosts don't keep it in HOME,
    # in order to avoid it getting stale, and will have it in the WORKSPACE
    # instead, synced separately below.
    if [ -d $HOME/mender-qa ]
    then
        $RSYNC    $HOME/mender-qa  $login:.
    fi

    # Copy the workspace. If there is no workspace defined, we are not in the
    # job section yet.
    if [ -n "$WORKSPACE" ]
    then
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no $login mkdir -p "$WORKSPACE_REMOTE"
        $RSYNC    "$WORKSPACE"/  $login:"$WORKSPACE_REMOTE"/
    fi

    # Copy the build cache, if there is one, and only if the node has a known
    # label.
    if [ -n "$NODE_LABELS" ]
    then
        if [ -d $HOME/.cache/cfengine-buildscripts-distfiles ]
        then
            ssh -o BatchMode=yes -o StrictHostKeyChecking=no $login mkdir -p .cache
            $RSYNC   $HOME/.cache/cfengine-buildscripts-distfiles/  $login:.cache/cfengine-buildscripts-distfiles/
        fi

        if [ -d $HOME/.cache/cfengine-buildscripts-pkgs ]
        then
            # There can be multiple labels, pick the first one.
            # The last one is usually the node name.
            label=${NODE_LABELS%% *}

            mkdir -p $HOME/.cache/cfengine-buildscripts-pkgs/$label
            ssh -o BatchMode=yes -o StrictHostKeyChecking=no $login mkdir -p .cache/cfengine-buildscripts-pkgs/$label
            $RSYNC    $HOME/.cache/cfengine-buildscripts-pkgs/$label/  $login:.cache/cfengine-buildscripts-pkgs/$label/
        fi
    fi

    # --------------------------------------------------------------------------
    # Run the actual job.
    # --------------------------------------------------------------------------
    ret=0
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no  $login \
        '. ./env.sh && cd $WORKSPACE && sh $HOME/commands-from-proxy.sh' "$@" \
        || ret=$?

    # --------------------------------------------------------------------------
    # Collect artifacts and cleanup.
    # --------------------------------------------------------------------------
    # Copy the workspace back after job has ended.
    if [ -n "$WORKSPACE" ]
    then
        $RSYNC    $login:"$WORKSPACE_REMOTE"/  "$WORKSPACE"/
    fi

    # Copy the build cache back in order to be preserved.
    if [ -n "$NODE_LABELS" ]
    then
        if [ -d $HOME/.cache/cfengine-buildscripts-distfiles ]
        then
            $RSYNC    $login:.cache/cfengine-buildscripts-distfiles/  $HOME/.cache/cfengine-buildscripts-distfiles/
        fi

        if [ -d $HOME/.cache/cfengine-buildscripts-pkgs ]
        then
            label=${NODE_LABELS%% *}
            $RSYNC    $login:.cache/cfengine-buildscripts-pkgs/$label/  $HOME/.cache/cfengine-buildscripts-pkgs/$label/
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

    # Reexecute script in order to be able to collect the return code, and
    # potentially stop the slave.
    rsync -czt "$0" $HOME/commands.sh
    ret=0
    env INIT_BUILD_HOST_SUB_INVOKATION=1 sh $HOME/commands.sh || ret=$?

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
