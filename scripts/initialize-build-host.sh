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
#    on_slave(), depending on which of those is true (both must be defined prior
#    to sourcing this script). Any remaining script commands before this script
#    was sourced are also run, but only on the slave, not on the proxy. Note
#    that commands that were executed *before* this script was sourced will run
#    on both hosts, so make sure this is sourced early.
#
# The script is expected to be sourced early in the init-script phase after
# provisioning.

# Make sure error detection and verbose output is on, if they aren't already.
set -x -e

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
if [ "$(id -u)" = 0 ]
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
    rsync -czte "ssh -o BatchMode=yes -o StrictHostKeyChecking=no" "$0" $login:commands.sh

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
    rsync -czte "ssh -o BatchMode=yes -o StrictHostKeyChecking=no" env.sh $login:.

    # And the helper tools, including this script.
    # Note that only provisioned hosts will have this in HOME, since they use
    # the repository in provisioning. Permanent hosts don't keep it in HOME,
    # in order to avoid it getting stale, and will have it in the WORKSPACE
    # instead, synced separately below.
    if [ -d $HOME/mender-qa ]
    then
        rsync --delete -czrlpte "ssh -o BatchMode=yes -o StrictHostKeyChecking=no" $HOME/mender-qa $login:.
    fi

    # Copy the workspace. If there is no workspace defined, we are not in the
    # job section yet.
    if [ -n "$WORKSPACE" ]
    then
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no $login mkdir -p "$WORKSPACE_REMOTE"
        rsync --delete -czrlpte "ssh -o BatchMode=yes -o StrictHostKeyChecking=no" "$WORKSPACE"/ $login:"$WORKSPACE_REMOTE"/
    fi

    # Copy the build cache.
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no $login mkdir -p .cache
    rsync --delete -czrlpte "ssh -o BatchMode=yes -o StrictHostKeyChecking=no" $HOME/.cache/cfengine-buildscripts-distfiles/ $login:.cache/cfengine-buildscripts-distfiles/
    # Only copy packages if this node has a known label.
    if [ -n "$NODE_LABELS" ]
    then
        # There can be multiple labels, pick the first one.
        # The last one is usually the node name.
        label=${NODE_LABELS%% *}

        mkdir -p $HOME/.cache/cfengine-buildscripts-pkgs/$label
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no $login mkdir -p .cache/cfengine-buildscripts-pkgs/$label
        rsync --delete -czrlpte "ssh -o BatchMode=yes -o StrictHostKeyChecking=no" $HOME/.cache/cfengine-buildscripts-pkgs/$label/ $login:.cache/cfengine-buildscripts-pkgs/$label/
    fi

    # --------------------------------------------------------------------------
    # Run the actual job.
    # --------------------------------------------------------------------------
    ret=0
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no $login '. env.sh && cd $WORKSPACE && $HOME/commands.sh' "$@" || ret=$?

    # --------------------------------------------------------------------------
    # Collect artifacts and cleanup.
    # --------------------------------------------------------------------------
    # Copy the workspace back after job has ended.
    if [ -n "$WORKSPACE" ]
    then
        rsync --delete -czrlpte "ssh -o BatchMode=yes -o StrictHostKeyChecking=no" $login:"$WORKSPACE_REMOTE"/ "$WORKSPACE"/
    fi

    # Copy the build cache back in order to be preserved.
    rsync --delete -czrlpte "ssh -o BatchMode=yes -o StrictHostKeyChecking=no" $login:.cache/cfengine-buildscripts-distfiles/ $HOME/.cache/cfengine-buildscripts-distfiles/
    if [ -n "$NODE_LABELS" ]
    then
        label=${NODE_LABELS%% *}
        rsync --delete -czrlpte "ssh -o BatchMode=yes -o StrictHostKeyChecking=no" $login:.cache/cfengine-buildscripts-pkgs/$label/ $HOME/.cache/cfengine-buildscripts-pkgs/$label/
    fi

    # Return the error code from the job.
    exit $ret
else
    ret=0
    on_slave || ret=$?
    # Failure to find a function returns 127, so check for that specifically,
    # otherwise there was an error inside the function.
    if [ $ret -ne 0 -a $ret -ne 127 ]
    then
        exit $ret
    fi
    # Else continue.
fi
