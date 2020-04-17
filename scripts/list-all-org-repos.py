#!/usr/bin/python3

import argparse
import json
import re
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument(
    "--token",
    help="Github Personal Access token, get it from https://github.com/settings/tokens.",
)
parser.add_argument(
    "--org",
    default="mendersoftware",
    help="Organization to get repositories for. Defaults to mendersoftware",
)
args = parser.parse_args()


def process_response(body):
    # Cut headers.
    body = body[body.find("\r\n\r\n") + 4 :]

    repos = json.loads(body)
    for repo in repos:
        print(repo["ssh_url"])


base_curl_args = [
    "curl",
    "-si",
    "-H",
    "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
    "--compressed",
]
if args.token:
    base_curl_args += ["-H", "Authorization: bearer %s" % args.token]
else:
    sys.stderr.write(
        "Warning: Running without token, private repositories will not be listed.\n"
    )

url = "https://api.github.com/orgs/%s/repos" % args.org
output = None
try:
    while True:
        output = subprocess.check_output(base_curl_args + [url]).decode()
        process_response(output)

        # Example header (typically the one you are requesting is not present):
        # Link: <https://api.github.com/organizations/15040539/repos?page=1>; rel="prev", <https://api.github.com/organizations/15040539/repos?page=3>; rel="next", <https://api.github.com/organizations/15040539/repos?page=3>; rel="last", <https://api.github.com/organizations/15040539/repos?page=1>; rel="first"
        link_header = re.search(
            r'^link:.*<([^>]*)>\s*;\s*rel="next"\s*,\s*<([^>]*)>\s*;\s*rel="last"',
            output,
            flags=re.MULTILINE | re.IGNORECASE,
        )
        if link_header is None or url == link_header.group(2):
            break
        url = link_header.group(1)
except:
    print("Got exception, last response was:")
    print(output)
    raise
