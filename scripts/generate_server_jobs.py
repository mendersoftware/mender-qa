import argparse
import os, subprocess
import yaml

WORKSPACE = os.environ.get("WORKSPACE")
if WORKSPACE is None:
    raise RuntimeError("provide the WORKSPACE variable!")

repo_whitelist = [
    "api-gateway",
    "auditlogs",
    "create-artifact-worker",
    "deployments-enterprise",
    "deployments",
    "deviceauth",
    "deviceconfig",
    "deviceconnect",
    "devicemonitor",
    "email-sender",
    "gui",
    "inventory-enterprise",
    "inventory",
    "mender-conductor",
    "mender-conductor-enterprise",
    "mtls-ambassador",
    "org-welcome-email-preparer",
    "tenantadm",
    "useradm-enterprise",
    "useradm",
    "workflows-enterprise-worker",
    "workflows-enterprise",
    "workflows-worker",
    "workflows",
]


def generate(branch):
    stage_name = "build"
    document = {"stages": [stage_name]}
    release_tool = os.path.join(WORKSPACE, "integration", "extra", "release_tool.py")
    docker_repos = subprocess.run(
        [
            release_tool,
            "--list",
            "docker",
        ],
        capture_output=True,
    )

    repos = []
    for docker in docker_repos.stdout.decode("utf-8").splitlines():
        git = subprocess.run(
            [release_tool, "--map-name", "docker", docker, "git"], capture_output=True
        )
        git_repo = git.stdout.decode("utf-8").strip()
        if git_repo in repo_whitelist:
            repos.append(git_repo)

        for repo in sorted(set(repos)):
            document[f"build:{repo}"] = {
                "stage": stage_name,
                "trigger": {
                    "project": f"Northern.tech/Mender/{repo}",
                    "branch": branch,
                    "strategy": "depend",
                },
            }

    with open("gitlab-ci-server-build-jobs.yml", "w") as f:
        yaml.dump(document, f)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--branch")
    args = parser.parse_args()
    generate(args.branch)
