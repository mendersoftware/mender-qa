How to debug a build slave
==========================

In order to debug a build slave, your key needs to be listed in
`initialize-build-host.sh`. Just log in to that build slave and create a file,
`stop_slave` in the home directory of the build user. This will stop the build
and keep it online until the file is removed.

The user and IP are printed near the top of the build log.
