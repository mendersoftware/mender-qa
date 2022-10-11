#!/bin/bash
# We cannot allow any commands to fail and break the configuration.
set -e
# Script for checking and updating the KVM-enabled Ubuntu image used for
# provisioning build slaves with upstream from ubuntu-os-cloud.

# How many images do we want to keep record of (including the one we're using)
# -- it might be a good idea to keep at least one backup
IMAGES_TO_KEEP=2

# Get current and newest available ubuntu-2204-lts image
CUR_IMAGES=$(gcloud compute images list --filter="name~'nested-virt.*'" \
                --sort-by="~creationTimestamp" --format="value(name)" | \
             cut -f1)
CUR_IMAGE=$(echo $CUR_IMAGES | awk '{print $1}')
IMAGE=$(gcloud compute images list --filter="family~'ubuntu-2204-lts' AND architecture=X86_64" \
        --sort-by="~creationTimestamp" --format="value(name)" --limit 1 | \
             cut -f1)

if [ ! -z "${CUR_IMAGE}" ] && [ "${CUR_IMAGE}" != "nested-virt-${IMAGE}" ]
then
    echo "Updating image..."
    # Create new image with vmx enabled
    gcloud compute images create nested-virt-$IMAGE \
        --source-image-project=ubuntu-os-cloud \
        --source-image=$IMAGE \
        --licenses="https://www.googleapis.com/compute/v1/projects/vm-options/global/licenses/enable-vmx"

    # Get url to new image and update gitlab-runner config
    NEW_IMAGE_URL=$(gcloud compute images list --uri \
	            --filter="name~'nested-virt-$IMAGE'" | \
                    awk 'FNR==1{print $0}')
    echo $NEW_IMAGE_URL
    sed -i "s|\(\"google-machine-image=\).*\"|\1${NEW_IMAGE_URL}\"|" /etc/gitlab-runner/config.toml
    echo "Image successfully updated from '${CUR_IMAGE}' to 'nested-virt-${IMAGE}'"
    # Delete all the older images we don't want to keep
    while [ $(echo $CUR_IMAGES | wc -w) -gt $IMAGES_TO_KEEP ]
    do
        sleep 1
        yes Y | gcloud compute images delete $(echo $CUR_IMAGES | awk '{print $NF}')
        CUR_IMAGES=$(echo $CUR_IMAGES | awk '{$NF=""; print $0}')
    done
else
    echo "Image '${IMAGE}' is already up to date"
fi
