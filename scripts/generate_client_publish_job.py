#!/usr/bin/python3
# Copyright 2022 Northern.tech AS
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

import argparse
import os, subprocess
import re
import tempfile
import shutil
import yaml
import urllib.request


def initWorkspace():
    path = tempfile.mkdtemp()
    subprocess.check_call(
        ["git", "clone", "https://github.com/mendersoftware/integration.git", path],
    )
    return path


def getStableMetaMender():
    with urllib.request.urlopen(
        "https://raw.githubusercontent.com/mendersoftware/mender-qa/master/.gitlab-ci.yml"
    ) as stream:
        return yaml.safe_load(stream)["variables"]["POKY_REV"]["value"]


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
    integration_versions = subprocess.check_output(release_tool_args)

    # Filter out saas-* versions
    # Historically, there have been some saas- releases using "master" of independent components
    # (namely: mender-connect), but we certainly don't wont these versions in the generated jobs
    integration_versions_list = [
        ver
        for ver in integration_versions.decode("utf-8").splitlines()
        if not ver.startswith("saas-")
    ]

    stage_name = "trigger"
    document = {
        "stages": [stage_name],
    }

    for integ_version in integration_versions_list:

        subprocess.check_output(
            ["git", "checkout", integ_version], cwd=integration_repo,
        )

        all_repos = subprocess.check_output([release_tool, "--list", "git"])

        job_key = "trigger:mender-qa:" + integ_version.split("/")[1]

        repos = {}
        any_tag = False
        for repo in all_repos.decode("utf-8").splitlines():
            repo_version = subprocess.check_output(
                [
                    release_tool,
                    "--version-of",
                    repo,
                    "--in-integration-version",
                    integ_version,
                ],
            )

            # For origin/master, the tool returns origin/master, but for
            # releases like origin/2.7.x, the tool returns 2.7.x (?)
            repo_version = repo_version.decode("utf-8").rstrip()
            if len(repo_version.split("/")) > 1:
                repo_version = repo_version.split("/")[1]

            repos[repo.replace("-", "_").upper()] = repo_version

            # Do not allow any job which will push build or final tags. These
            # should never be done outside of manual releases.
            if (
                re.match("^[0-9]+\.[0-9]+\.[0-9]+(-build[0-9]+)?$", repo_version)
                is not None
            ):
                any_tag = True
                break

        if any_tag:
            continue

        repos["META_MENDER"] = args.meta_mender_version

        document[job_key] = {
            "stage": stage_name,
            "inherit": {
                "variables": False,
            },
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
                "RUN_BACKEND_INTEGRATION_TESTS": "false",
                "RUN_INTEGRATION_TESTS": "false",
            },
        }
        for repo, version in repos.items():
            document[job_key]["variables"][f"{repo}_REV"] = version

    with open(args.filename, "w") as f:
        yaml.dump(document, f)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--trigger", required=True)
    parser.add_argument("--workspace", default=None)
    parser.add_argument("--version", default="master")
    parser.add_argument("--meta-mender-version", default=None)
    parser.add_argument("--feature-branches", action="store_true")
    parser.add_argument("--filename", default="gitlab-ci-client-qemu-publish-job.yml")
    args = parser.parse_args()

    if not args.meta_mender_version:
        args.meta_mender_version = getStableMetaMender()

    if args.workspace:
        generate(args.workspace, args)
    else:
        integration_repo = initWorkspace()
        generate(integration_repo, args)
        shutil.rmtree(integration_repo)
