import argparse
import os, subprocess
import tempfile
import shutil
import yaml


def initWorkspace():
    path = tempfile.mkdtemp()
    subprocess.run(
        ["git", "clone", "https://github.com/mendersoftware/integration.git", path],
        capture_output=True,
        check=True,
    )
    return path


def generate(integration_repo, trigger_from_repo, version_to_publish, filename):
    release_tool = os.path.join(integration_repo, "extra", "release_tool.py")
    integration_versions = subprocess.run(
        [
            release_tool,
            "--integration-versions-including",
            trigger_from_repo,
            "--version",
            version_to_publish,
        ],
        capture_output=True,
        check=True,
    )

    stage_name = "trigger"
    document = {
        "stages": [stage_name],
        "trigger:mender-qa": {
            "stage": stage_name,
            "trigger": {
                "project": "Northern.tech/Mender/mender-qa",
                "branch": "master",
                "strategy": "depend",
            },
            "variables": {
                "PUBLISH_DOCKER_CLIENT_IMAGES": "true",
                "BUILD_CLIENT": "true",
                "BUILD_SERVERS": "false",
                "BUILD_QEMUX86_64_UEFI_GRUB": "false",
                "TEST_QEMUX86_64_UEFI_GRUB": "false",
                "BUILD_QEMUX86_64_BIOS_GRUB": "false",
                "TEST_QEMUX86_64_BIOS_GRUB": "false",
                "BUILD_QEMUX86_64_BIOS_GRUB_GPT": "false",
                "TEST_QEMUX86_64_BIOS_GRUB_GPT": "false",
                "BUILD_VEXPRESS_QEMU_UBOOT_UEFI_GRUB": "false",
                "TEST_VEXPRESS_QEMU_UBOOT_UEFI_GRUB": "false",
                "BUILD_VEXPRESS_QEMU": "false",
                "TEST_VEXPRESS_QEMU": "false",
                "BUILD_VEXPRESS_QEMU_FLASH": "false",
                "TEST_VEXPRESS_QEMU_FLASH": "false",
                "BUILD_BEAGLEBONEBLACK": "false",
                "TEST_BEAGLEBONEBLACK": "false",
                "BUILD_RASPBERRYPI3": "false",
                "TEST_RASPBERRYPI3": "false",
                "RUN_INTEGRATION_TESTS": "false",
            },
        },
    }

    repos = {}
    for integ_version in integration_versions.stdout.decode("utf-8").splitlines():
        all_repos = subprocess.run(
            [release_tool, "--list", "git"], capture_output=True, check=True
        )
        for repo in all_repos.stdout.decode("utf-8").splitlines():
            repo_version = subprocess.run(
                [
                    release_tool,
                    "--version-of",
                    repo,
                    "--in-integration-version",
                    integ_version,
                    "|",
                    "cut",
                    "-d/",
                    "-f2",
                ],
                capture_output=True,
            )
            repos[repo.replace("-", "_").upper()] = (
                repo_version.stdout.decode("utf-8") or "master"
            )

        for repo, version in repos.items():
            document["trigger:mender-qa"]["variables"][f"{repo}_REV"] = version

    with open(filename, "w") as f:
        yaml.dump(document, f)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--trigger")
    parser.add_argument("--version", default="master")
    parser.add_argument("--filename", default="gitlab-ci-client-qemu-publish-job.yml")
    args = parser.parse_args()
    integration_repo = initWorkspace()
    generate(integration_repo, args.trigger, args.version, args.filename)
    shutil.rmtree(integration_repo)
