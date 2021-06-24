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


def generate(integration_repo, args):
    release_tool = os.path.join(integration_repo, "extra", "release_tool.py")
    release_tool_args = [
        release_tool,
        "--integration-versions-including",
        args.trigger,
        "--version",
        args.version,
    ]
    if args.feature_branches:
        release_tool_args.append("--feature-branches")
    integration_versions = subprocess.run(
        release_tool_args, capture_output=True, check=True,
    )

    # Filter out saas-* versions
    # Historically, there have been some saas- releases using "master" of independent components
    # (namely: mender-connect), but we certainly don't wont these versions in the generated jobs
    integration_versions_list = [
        ver
        for ver in integration_versions.stdout.decode("utf-8").splitlines()
        if not ver.startswith("saas-")
    ]

    stage_name = "trigger"
    document = {
        "stages": [stage_name],
    }

    for integ_version in integration_versions_list:

        subprocess.run(
            ["git", "checkout", integ_version],
            capture_output=True,
            check=True,
            cwd=integration_repo,
        )

        all_repos = subprocess.run(
            [release_tool, "--list", "git"], capture_output=True, check=True
        )

        job_key = "trigger:mender-qa:" + integ_version.split("/")[1]
        document[job_key] = {
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
        }

        repos = {}
        for repo in all_repos.stdout.decode("utf-8").splitlines():
            repo_version = subprocess.run(
                [
                    release_tool,
                    "--version-of",
                    repo,
                    "--in-integration-version",
                    integ_version,
                ],
                capture_output=True,
                check=True,
            )

            # For origin/master, the tool returns origin/master, but for
            # releases like origin/2.7.x, the tool returns 2.7.x (?)
            repo_version = repo_version.stdout.decode("utf-8").rstrip()
            if len(repo_version.split("/")) > 1:
                repo_version = repo_version.split("/")[1]

            repos[repo.replace("-", "_").upper()] = repo_version

        repos["META_MENDER"] = args.meta_mender_version

        for repo, version in repos.items():
            document[job_key]["variables"][f"{repo}_REV"] = version

    with open(args.filename, "w") as f:
        yaml.dump(document, f)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--trigger", required=True)
    parser.add_argument("--workspace", default=None)
    parser.add_argument("--version", default="master")
    parser.add_argument("--meta-mender-version", default="master")
    parser.add_argument("--feature-branches", action="store_true")
    parser.add_argument("--filename", default="gitlab-ci-client-qemu-publish-job.yml")
    args = parser.parse_args()
    if args.workspace:
        generate(args.workspace, args)
    else:
        integration_repo = initWorkspace()
        generate(integration_repo, args)
        shutil.rmtree(integration_repo)
