# Helper bash functions for Jenkins/GitLab

github_pull_request_status() {
    (
        # Disable command echoing in here, it's quite verbose and not very
        # helpful, since these aren't strictly build steps.
        set +x

        TEST_TRACKER[$4]=$1
        if [ -z "$JENKINS_URL" ]; then
            local request_body=$(cat <<EOF
    {
      "state": "$1",
      "description": "$2",
      "target_url": "$CI_JOB_URL",
      "context": "GitLab_$4"
    }
EOF
            )
        else
            local request_body=$(cat <<EOF
    {
      "state": "$1",
      "description": "$2",
      "target_url": "$3",
      "context": "$4"
    }
EOF
            )
        fi

        # Split on newlines
        local IFS='
'
        for decl in $(env); do
            set +x
            local key=${decl%%=*}
            if ! eval echo \$$key | egrep -q "^pull/[0-9]+/head$"; then
                # Not a pull request, skip.
                continue
            fi
            if echo $key | egrep -q "^DOCKER_ENV_"; then
                # Skip GitLab/Docker duplicated environment vars, i.e. MENDER_REV has a DOCKER_ENV_MENDER_REV
                continue
            fi

            set -x
            local repo=$(tr '[A-Z_]' '[a-z-]' <<<${key%_REV})
            if [ -n "$(eval echo \$${key}_GIT_SHA)" ]; then
                # GitLab script defines env variables with _GIT_SHA suffix for the PR commit under test
                local git_commit="$(eval echo \$${key}_GIT_SHA)"
            else
                # Fallback to classic method of relying on locally cloned repos
                case "$key" in
                    META_MENDER_REV)
                        local location=$WORKSPACE/meta-mender
                        ;;
                    *_REV)
                        if ! $WORKSPACE/integration/extra/release_tool.py --version-of $repo; then
                            # If the release tool doesn't recognize the repository, don't use it.
                            continue
                        fi
                        local location=
                        if [ -d "$WORKSPACE/$repo" ]; then
                            location="$WORKSPACE/$repo"
                        elif [ -d "$WORKSPACE/go/src/github.com/mendersoftware/$repo" ]; then
                            location="$WORKSPACE/go/src/github.com/mendersoftware/$repo"
                        else
                            echo "github_pull_request_status: Unable to find repository location: $repo"
                            return 1
                        fi
                        ;;
                    *)
                        # Not a revision, go to next entry.
                        continue
                        ;;
                esac
                local git_commit=$(cd "$location" && git rev-parse HEAD)
            fi
            local pr_status_endpoint=https://api.github.com/repos/mendersoftware/$repo/statuses/$git_commit

            curl -iv --user "$GITHUB_BOT_USER:$GITHUB_BOT_PASSWORD" \
                 -d "$request_body" \
                 "$pr_status_endpoint"
        done
    )
}

s3cmd_put() {
    if [ -z "$JENKINS_URL" ]; then return; fi
    local local_path=$1
    local remote_url=$2
    shift 2
    local cmd_options=$@
    s3cmd $cmd_options put $local_path $remote_url
}

s3cmd_put_public() {
    if [ -z "$JENKINS_URL" ]; then return; fi
    s3cmd_put $@
    local remote_url=$2
    s3cmd setacl $remote_url --acl-public
}
