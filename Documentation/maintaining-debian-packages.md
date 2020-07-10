# How to update official Debian packages

This guide describe how to update the official Debian packages following a Mender
release. Not to be confused with our own provided packages, which are built at
`mender-dist-packages` repository.

It is recommended to get familiar with Debian policy:
https://www.debian.org/doc/debian-policy/

## Dependencies

You need a Debian based OS and `git-buildpackage` tool, which can be installed with:

```
sudo apt install git-buildpackage
```

## Source code

The repositories hosting the recipes for the official Debian packages are:

* https://salsa.debian.org/go-team/packages/mender-client
* https://salsa.debian.org/go-team/packages/golang-github-mendersoftware-mender-artifact
* https://salsa.debian.org/go-team/packages/mender-cli

The following ones are soon to be deprecated:
* https://salsa.debian.org/go-team/packages/golang-github-mendersoftware-log
* https://salsa.debian.org/go-team/packages/golang-github-mendersoftware-scopestack
* https://salsa.debian.org/go-team/packages/golang-github-mendersoftware-mendertesting

## First time setup

* Create a guest account in https://salsa.debian.org/ and fork the repo(s).
* Clone the repo(s).
* Fetch and checkout branches `master`, `upstream` and `pristine-tar`.

## Update Debian package

Make use you are up to date with latest upstream

```
git fetch --all --tags
```

Scan corresponding GitHub repo and import the new tag (N.A. for betas) following
the tool prompts.

```
gbp import-orig --uscan
```

Check if there is any patch we can drop. If so, see section below.

```
ls debian/patches
```

Test the package build, see section below.

Update `debian/control` if necessary and commit the changes.

Finally, update changelog and commit

```
gbp dch --auto && dch -r -D unstable
git commit -s -m "Update debian/changelog" debian/changelog
```

When done,

* If you are part of Debian Go Packaging team, tag and push:

```
gbp tag --sign-tags
gbp push
```

* If not, launch a Merge Request for the package(s) and ping Lluís, Fabio, or
  Andreas.

## Working with patches

There is a convenient way `gbp` to recreate the upstream patch queue and remove,
modify or add patches.

Run `gbp pq import` to create a patch branch, where you can see upstream code
and the debian patches in your git history (see `git log`). Remove, fix, add
whatever needed, and when done use `gbp pq export` to convert back the git
history into Debian patches. If the patches are modified, commit the changes.

To start from stratch, use `gbp pq drop`.

## Testing the package builds

Lluís has a very customized process for this. See his repo for more information:
https://gitlab.com/lluiscampos/debian-salsa-builder

If you have a better way to do this, please let him know :)

# The end!
