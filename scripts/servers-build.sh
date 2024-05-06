#!/bin/bash

set -e -x -E


echo "WORKSPACE=$WORKSPACE"

get_mender_binary_delta_version() {
    local recipe
    if [ -z "$MENDER_BINARY_DELTA_VERSION" -o "$MENDER_BINARY_DELTA_VERSION" = "latest" ]; then
        recipe=$(ls $WORKSPACE/meta-mender/meta-mender-commercial/recipes-mender/mender-binary-delta/*.bb | sort -V | tail -n1)
    else
        recipe=$(ls $WORKSPACE/meta-mender/meta-mender-commercial/recipes-mender/mender-binary-delta/*$MENDER_BINARY_DELTA_VERSION*.bb)
    fi
    echo $recipe | egrep -o '[0-9]+\.[0-9]+\.[0-9b]+(-build[0-9]+)?'
}

build_servers_repositories() {
    # Use release tool to query for available docker names.
    for docker in $($WORKSPACE/integration/extra/release_tool.py --list docker); do

        git=$($WORKSPACE/integration/extra/release_tool.py --map-name docker $docker git)
        docker_url=$($WORKSPACE/integration/extra/release_tool.py --map-name docker $docker docker_url)

        for repo in $git; do (

            cd go/src/github.com/mendersoftware/$repo

            case "$docker" in
                iot-manager|deployments|deployments-enterprise|deviceauth|deviceauth-enterprise|inventory|inventory-enterprise|tenantadm|useradm|useradm-enterprise|workflows|workflows-enterprise|create-artifact-worker|auditlogs|mtls-ambassador|deviceconnect|deviceconfig|devicemonitor|reporting|mender-ci-tools|mender-gateway)
                    docker build -t $docker_url:pr .
                    $WORKSPACE/integration/extra/release_tool.py --set-version-of $docker --version pr
                    ;;

                generate-delta-worker)
                    local version=$(get_mender_binary_delta_version)
                    aws s3 cp s3://mender-binaries/mender-binary-delta/${version}/mender-binary-delta-${version}.tar.xz .
                    xz -cd mender-binary-delta-${version}.tar.xz | tar xvf -
                    cp mender-binary-delta-${version}/x86_64/mender-binary-delta-generator mender-binary-delta-generator-amd64
                    cp mender-binary-delta-${version}/aarch64/mender-binary-delta-generator mender-binary-delta-generator-arm64
                    docker build -t $docker_url:pr .
                    $WORKSPACE/integration/extra/release_tool.py --set-version-of $docker --version pr
                    ;;

                workflows-worker|workflows-enterprise-worker)
                    docker build -t $docker_url:pr -f Dockerfile.worker .
                    $WORKSPACE/integration/extra/release_tool.py --set-version-of $docker --version pr
                    ;;

                gui)
                    # GIT_REF + GIT_COMMIT for 2.3 or older, GIT_COMMIT_TAG for newer
                    docker build \
                           -t $docker_url:pr \
                           --build-arg GIT_REF=$(git describe) \
                           --build-arg GIT_COMMIT=$(git rev-parse --short HEAD) \
                           --build-arg GIT_COMMIT_TAG="$(git describe)" \
                           .
                    $WORKSPACE/integration/extra/release_tool.py --set-version-of $docker --version pr
                    ;;

                mender-client-docker*)
                    # Built directly on an independent pipeline job
                    :
                    ;;

                mender-client-qemu*)
                    # Built in yocto-build-and-test.sh::build_and_test_client
                    :
                    ;;

                mender-monitor-qemu-commercial|mender-gateway-qemu-commercial|mender-qemu-rofs-commercial)
                    # Built in yocto-build-and-test.sh::build_and_test_client
                    :
                    ;;

                api-gateway)
                    docker build -t $docker_url:pr .
                    $WORKSPACE/integration/extra/release_tool.py --set-version-of $docker --version pr
                    ;;

                mender-conductor|mender-conductor-enterprise)
                    docker build --build-arg REVISION=pr -t $docker_url:pr ./server
                    $WORKSPACE/integration/extra/release_tool.py --set-version-of $docker --version pr
                    ;;

                email-sender)
                    docker build -t $docker_url:pr ./workers/send_email
                    $WORKSPACE/integration/extra/release_tool.py --set-version-of $docker --version pr
                    ;;

                org-welcome-email-preparer)
                    docker build --build-arg REVISION=pr -t $docker_url:pr ./workers/prepare_org_welcome_email
                    $WORKSPACE/integration/extra/release_tool.py --set-version-of $docker --version pr
                    ;;

                *)
                    echo "Don't know how to build docker image $docker"
                    exit 1
                    ;;
            esac
        ); done
    done
}

build_servers_repositories
