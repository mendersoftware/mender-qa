# Setup Jenkins with Google Compute Engine using JClouds

This document describes how to configure Jenkins with Google Cloud's Compute Engine using JClouds plugin. 

The following is a summary of [this guide](https://cloud.google.com/solutions/using-jenkins-for-distributed-builds-on-compute-engine#configure_jclouds) excluding some unnecessary steps (assuming a jenkins master is already up and running), and adding some observations regarding the packer tool. 

## First things first
Before you begin, you need to:

1. [Create](https://console.cloud.google.com/cloud-resource-manager?_ga=2.124208399.-404043170.1519032864) a project
2. [Enable](https://support.google.com/cloud/answer/6293499#enable-billing) billing for the project
3. [Enable](https://console.cloud.google.com/flows/enableapi?apiid=compute_component&_ga=2.27798201.-404043170.1519032864) Google Compute Engine API

## Setting up your environment
Open [Cloud Shell](https://console.cloud.google.com/?cloudshell=true).

### Configure Identity and Access Management (IAM)
Create a Cloud IAM service account to delegate permissions to Jenkins. To this service account you need to associate permissions to use Compute Engine and optionally Cloud Storage. 
#### Create a service account
1.  Create a service account called jenkins:
```
gcloud iam service-accounts create jenkins --display-name jenkins
```
2.  Store the service account email address and your current project ID in environment variables for use in later commands:
```
export SA_EMAIL=$(gcloud iam service-accounts list \
    --filter="displayName:jenkins" --format='value(email)')
export PROJECT=$(gcloud info --format='value(config.project)')
```
3.  Bind the following roles to your service account:
```
gcloud projects add-iam-policy-binding $PROJECT \
    --role roles/storage.admin --member serviceAccount:$SA_EMAIL
gcloud projects add-iam-policy-binding $PROJECT --role roles/compute.instanceAdmin.v1 \
    --member serviceAccount:$SA_EMAIL
gcloud projects add-iam-policy-binding $PROJECT --role roles/compute.networkAdmin \
    --member serviceAccount:$SA_EMAIL
gcloud projects add-iam-policy-binding $PROJECT --role roles/compute.securityAdmin \
    --member serviceAccount:$SA_EMAIL
```
### Download the service account keys
Now that you've created a service account with the appropriate permissions, you need to create and download the key. This key (json) -file will later be used as credentials to the JClouds plugin to authenticate with the Compute Engine API. 

1.  Create the key file:
```
gcloud iam service-accounts keys create jenkins-sa.json --iam-account $SA_EMAIL
```
2.  In Cloud Shell, click the icon with the three dots in the upper left corner, and select "Download file" and specify the path to the "jenkins-sa.json" file, and hit Download. 

## Create a Jenkins agent image
This section explain in some greater detail how to create a reusable Compute Engine image using packer; that in addition to the base image runs the user-data and init-script since these for some reason is not included in the JClouds plugin wrt gce target. 

### Create an SSH key for Cloud Shell
Later you will need to use [Packer](https://www.packer.io/) which `ssh` to communicate with your build instances. 
1.  Create a SSH key pair. If one already exists, this command uses that key pair; otherwise, it creates a new one:
```
ls ~/.ssh/id_rsa.pub || ssh-keygen -N ""
```
2.  Add the Cloud Shell public SSH key to your project's metadata:
```
gcloud compute project-info describe \
    --format=json | jq -r '.commonInstanceMetadata.items[] | select(.key == "sshKeys") | .value' > sshKeys.pub
echo "$USER:$(cat ~/.ssh/id_rsa.pub)" >> sshKeys.pub
gcloud compute project-info add-metadata --metadata-from-file sshKeys=sshKeys.pub
```

### Create the baseline image
In this step we create a baseline VM image for build agents. The most basic Jenkins image only requires Java to be installed. You will have to customize this image by providing additional `provisioners` if you want to add user-data/init-scripts. 

1.  In Cloud Shell, download and unpack Packer: 
```
wget https://releases.hashicorp.com/packer/1.2.2/packer_1.2.2_linux_amd64.zip
unzip packer_1.2.2_linux_amd64.zip
```

2.  Create the configuration file for your Packer image builds for example: 
```
export PROJECT=$(gcloud info --format='value(config.project)')
cat > jenkins-agent.json <<EOF
{
    "builders": [
        {
            "type": "googlecompute",
            "project_id": "$PROJECT",
            "source_image_family": "ubuntu-1604-lts",
            "source_image_project_id": "ubuntu-os-cloud",
            "zone": "europe-west2-b",
            "disk_size": "20",
            "image_name": "jenkins-agent-{{timestamp}}",
            "image_family": "jenkins-agent",
            "ssh_username": "ubuntu"
            "image_licenses": ["projects/vm-options/global/licenses/enable-vmx"]
        }
    ],
    "provisioners": [
        {
            "type": "shell",
            "inline": [
                "sudo apt-get update",
                "sudo apt-get install -y default-jdk"
            ]
        }
    ]
}
EOF
```
*However*; since you are not able to provide `user-data` and `init-script` with Jenkins at a later stage, this is where you'll need to add these scripts. To do this we will need to add additional [provisioners](https://www.packer.io/docs/provisioners/index.html). In short, there are two types of provisioners of interest: [shell](https://www.packer.io/docs/provisioners/shell.html) which runs the specified script(s) (can also be inline) **once** when packer builds the script. This is where you want to place your `user-data` script. The other provisioner you'll need is [file](https://www.packer.io/docs/provisioners/file.html), which adds a file from your local file system to the image, typically you have to add the file to some destination, and use shell to move it to where you want it if it requires sudo. 

Now, typically you will want (part of) your `init-script` to run when the agent boots. *(You should put as much of your scripts as possible in the init script which runs at boot to avoid having to make a new packer image every time there is a change in it.)* To make this happen, you will have to make a little work-around. One way to do this, is to provide your *script* as a *file*, and add it to `/etc/init.d/`, and finally use a *shell* provisioner to make it execute in `rc.local`. For example:
```
export PROJECT=$(gcloud info --format='value(config.project)')
cat > jenkins-agent.json <<EOF
{
    "builders": [
        {
            "type": "googlecompute",
            "project_id": "jenkins-195709",
            "source_image_family": "ubuntu-1604-lts",
            "source_image_project_id": "ubuntu-os-cloud",
            "zone": "europe-west2-b",
            "disk_size": "10",
            "image_name": "jenkins-agent-{{timestamp}}",
            "image_family": "jenkins-agent",
            "ssh_username": "ubuntu"
            "image_licenses": ["projects/vm-options/global/licenses/enable-vmx"]
        }
    ],
    "provisioners": [
        {
            "type": "shell",
            "execute_command": "echo 'packer' | sudo -S sh -c '{{ .Vars }} {{ .Path }}'",
            "scripts": [
                "/path/to/user_data.sh",
                "/path/to/non-init/init_script.sh"
            ]
        },
        {
                "type": "file",
                "source": "/path/to/init/init-script.sh",
                "destination": "/tmp/init-script.sh"
        },
        {
                "type": "shell",
                "inline": [
                    "sudo chmod 755 /tmp/init-script.sh",
                    "sudo mv /tmp/init-script.sh /etc/init.d/",
                    "sudo sed -i /etc/rc.local -e'\$s:^exit 0:/etc/init.d/init-script.sh\\\\nexit 0:'"
                ]
        }
    ]
}
EOF
```
*Replace /path/to/(...)/ with your local paths.* You might want to further modify your packer image by adding additional providers, or selecting another distro etc. but the above solution at least give you a setup for `user-data`/`init-scripts`.

**Example files of the json and the init script and user data files are in the Google Storage bucket "mender-jenkins".**

3.  Build the image by running Packer
```
./packer build jenkins-agent.json
```

### <a name="create-an-ssh-key-for-cloud-shell"></a>Create an SSH key pair for your Jenkins agents
In this section, you create and upload an SSH key pair. The Jenkins master uses this key pair to bootstrap the Jenkins agent it provisions. 

1.  In Cloud Shell, create an SSh key pair: 
```
ssh-keygen -f jenkins-agent-ssh -N ""
```
2.  Add the Jenkins public SSH key to your project metadata:
```
gcloud compute project-info describe \
    --format=json | jq -r '.commonInstanceMetadata.items[] | select(.key == "sshKeys") | .value' > sshKeys.pub
echo "jenkins:$(cat jenkins-agent-ssh.pub)" >> sshKeys.pub
gcloud compute project-info add-metadata --metadata-from-file sshKeys=sshKeys.pub
```
3.  Copy the private key `jenkins-agent-ssh` to your machine as we did for `jenkins-agent.json` above. You will needd this when configuring the Jenkins server later. 

## Configuring Jenkins
### Install plugins
1.  JClouds Plugin
2.  Google Cloud Storage plugin
3.  Restart Jenkins

### Create plugin credentials
You need to create two credentials for your new plugins: `JClouds Credentials` and `Google Credentials`. 
1. Open the Jenkins home page.
2. In the left-hand menu, click *Credentials*.
3. In the left-hand menu, click *System*.
4. In the main pane of the UI, click *Global credentials (unrestricted)*.
5. Create the JClouds credentials:
    1. In the left-hand menu, click *Add Credentials*.
    2. Set *Kind* to *JClouds Username with key*.
    3. Click *Choose file*
    4. Select the `jenkins-sa.json` file that you downloaded from Cloud Shell. 
    5. In the *Description* text field, enter `gce-jclouds`, and then click *OK*.
6. Create the Google Credentials: 
    1. In the left-hand menu, click *Add Credentials*.
    2. Set *Kind* to *Google Service Account from private key*.
    3. In the *Project Name* field, enter your **project ID**.
    4. Click *Choose file*.
    5. Select the `jenkins-sa.json` file. 
    6. Click **OK**.

### Configure JClouds
Configure JClouds plugin with the credentials it uses to providsion your agent instances. 

1. In the leftmost menu of the Jenkins UI, select *Manage Jenkins*.
2. Click *Configure System*.
3. Scroll to the bottom of the page and click *Add a new Cloud*.
4. Click *Cloud (JClouds)*.

5. Set the following settings:

>**Profile**: gce

>**Provider Name**: google-compute-engine

>**Max. No. of Instances**: 8

6. Choose the service account from the *Credentials* dropdown. It appears as an email with the format: `jenkins@[PROJECT].iam.gserviceaccount.com`

7. From the dropdown beside *Cloud RSA key*, select the service account.

8. Click the *Test Connection* button to ensure that JClouds is configured properly. If the connection fails, check your credential configuration from the previous steps.

### Configure Jenkins agent templates
1. Under the JClouds configuration in the *Configure System* page, click *Add template*.

2. Enter the following settings, substituting your Project ID for `[PROJECT]`:

>**Name**: ubuntu-1604

>**Labels**: ubuntu-1604

>**Number of Executors**: 1

>**Hardware Id dropdown**: https://www.googleapis.com/compute/v1/projects/[PROJECT]/zones/europe-west2-b/machineTypes/f1-micro

3. Click *Check Hardware Id*.
4. Click the *Specify Image ID* radio box.
5. In Cloud Shell, run the following command to get the base image's self-link URL:
```
gcloud compute images describe-from-family jenkins-agent --format='value(selfLink)'
```
6. In the Jenkins settings, enter the self-link URL in the *Image Id* field.
7. Verify your settings by clicking *Check Image Id*. If the verification fails, ensure that the URL is correct.
8. Click *Advanced*.
9. Next to *Jenkins Credentials*, click *Add*.
10. Click *Jenkins*.
11. Set *Kind* to *SSH Username with private key*.
12. Enter the following settings:

>**Username**: jenkins

>**Private Key**: Enter directly

>**Key**: Copy the from [jenkins-agent-ssh](#create-an-ssh-key-for-cloud-shell) file that you saved above.

>**Description**: jenkins-ssh

Click *Add*.

13. In the *Jenkins Credentials* dropdown, select the *jenkins-ssh* key pair, and then click *Save*.

Now you can go ahead and create a test project. 

## Note on Google Cloud firewall settings.
By default, Google Cloud has only opened port 22 in the firewall settings. If you want to use additional ports you will have to make an exception in the [Firewall Rules](https://console.cloud.google.com/networking/firewalls/list) settings. Please refer to https://cloud.google.com/vpc/docs/firewalls for additional information. 