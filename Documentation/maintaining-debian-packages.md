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

### Typical session with patches

A typical session with gbp can look as follows. Lets assume you have the code and
you are in the repo root directory. Furthermore, lets assume that you want to 
change something and rebuild and that you have just cloned (the tree is clean).

1. run:

```bash
gbp pq import
```
It will switch to `patch-queue/debian/sid` branch.

2. do make your changes

3. commit them

4. run:

```bash
gbp pq export
```

It will will export all the patches to `debian/patches` where you can see them.

5. run:

```bash
gbp buildpackage --git-pbuilder --git-pbuilder-options=--source-only-changes -us -uc --git-ignore-new
```

to rebuild.

6. when you want to add more changes, run:

```bash
gbp pq switch
```

The main idea is to swtich to _patch-queue/..._, which you can also
do with _git checkout patch-queue/..._. The `gbp pq switch` switches
back-and forth between _patch-queue/..._ and the main git branch.
(For instance, the two branches can be: `patch-queue/debian/sid`
and `debian/sid`)

8. goto 2.


_Note_: anytime you can start from scratch with: `gbp pq drop`


## Testing the package builds

Lluís has a very customized process for this. See his repo for more information:
https://gitlab.com/lluiscampos/debian-salsa-builder

If you have a better way to do this, please let him know :)

# The end!
