Component versioning
====================

We are using [Semantic Versioning](https://semver.org/) in our components, and
we are following more or less exactly the definition of Major, Minor and Patch
versions defined there. However, since Semantic Versioning was primarily written
for libraries, there are some key differences in what we call an API in Mender's
context.

### Count towards new major version

* Removing or changing command line options

* Removing or changing existing REST API

* Edge case: Changing default behavior, with the old behavior still
  available. An example is changing the default artifact format version in
  `mender-artifact`. We have opted for upgrading the major version in this case,
  but this could also go into a minor release

### Count towards new minor version

* Adding command line options

* Adding new REST API, or adding fields to responses of existing REST API

* Doing a database migration that is incompatible with the old schema (downgrade
  usually not possible without restoring a backup)

### Count towards new patch version

* Any change to our Golang API. For example, the `mender-artifact` library has
  an API, which is used by some other components, but this API is not considered
  public

* It should always be possible to freely upgrade and downgrade between patch
  versions in the same minor series
