Build slave setup
=================

This document describes the technical details of how we build Mender products in
Jenkins.

There are three main ways we launch VMs:

1. VMs able to use user data (CloudInit service)
2. VMs not able to use user data (no CloudInit service)
3. VMs that host older VMs inside them (nested VMs)


VMs with user data
------------------

This is the most common, and the most desirable, setup, since it requires the
least effort while still working the way we want. Works for most new platforms.

Here is a diagram displaying how the sequence of launching a VM with user data
works:

```
 Jenkins master                                  Cloud VM machine
    machine                                             |
       |                                                |
/===============\ /=============================================================================\
                 #
                 #
+--------------+ #
|Jenkins master| #
+--------------+ #
       |         #
       |Provision   +--------+
       +----------->|Cloud VM|
       |         #  +--------+
       | Login jenkins  |
       | port 222 [1]   |
       +--------------->|
       | Port           |
       | closed         |
       |<---------------+
       |         #      |
       v         #      v
     sleep       # Boot finished
       .         #      |
       .         #      |        +----------------+
       .         #      +------->|User data script|
       .         #      .        +----------------+
       .         #      .                |
       .         #      .                v
       .         #      .           Install Git
       .         #      .                |
       .         #      .                v
       .         #      .        git clone mender-qa
       .         #      .                |
       .         #      .                | Source     +-----------------------+
       .         #      .                +----------->|initialize-user-data.sh|
       .         #      .                .            +-----------------------+
       .         #      .                .                        |
       .         #      .                .                        v
       .         #      .                .               Create jenkins user
       .         #      .                .                        |
       .         #      .                .                        v
       .         #      .                .                   Prepare sudo
       .         #      .                .                        |
       .         #      .                .                        v
       .         #      .                .                   Open port 222
       .         #      .                .                        |
       . Login jenkins  .                |<-----------------------'
       . port 222       .                |
       +--------------->|                |
       .         #      | Call         .---.          +-----------+
       .         #      +--------------' | `--------->|Init script|
       .         #      .                |            +-----------+
       .         #      .                |                  |
       .         #      .                |                  v
       .         #      .                |            Wait for user
       .         #      .                |             data script
       .         #      .                |              to finish
       .         #      .                |                  .
       .         #      .                |                  .
       .         #      |<---------------'                  .
       .         #      .                                   .
       .         #      .                                   |Source +------------------------+
       .         #      .                                   +------>|initialize-build-host.sh|
       .         #      .                                   .       +------------------------+
       .         #      .                                   .                   |
       .         #      .                                   .                   v
       .         #      .                                   .      Run remaining script commands
       .         #      .                                   .        (usually package installs)
       .         #      .                                   .                   |
       .         #      .                                   |<------------------'
       .         #      .                                   |
       .         #      |<----------------------------------'
       .         #      |
       |<---------------'
       |         #      .
       | Build   #      .
       | recipe  #      .
       +--------------->|
       .         #      | Source                                    +------------------------+
       .         #      +------------------------------------------>|initialize-build-host.sh|
       .         #      .                                           +------------------------+
       .         #      .                                                       |
       .         #      .                                                       v
       .         #      .                                                Build and test
       .         #      .                                                   CFEngine
       .         #      .                                                       |
       .         #      |<------------------------------------------------------'
       .         #      |
       . Transfer       |
       . artifacts      |
       |<---------------'
       |         #      .
       v         #      .
  Kill slave     #      _
       |         #
       v         #
    Finished     #
                 #
```


VMs without user data
---------------------

VMs without user data are similar to those with user data, but because the
platform does not provide a user data script, we cannot do any initialization
there.

The biggest effect of this is that we have to build as root, since it is the
only user it is possible to log in as. Even if we, in the init script section,
were to create another user, Jenkins does not allow logging in to the same host
again without provisioning the VM from scratch, leaving us back at square one.

Here is a diagram displaying how the sequence of launching a VM without user
data works:

```
 Jenkins master                                  Cloud VM machine
    machine                                             |
       |                                                |
/===============\ /=============================================================================\
                 #
                 #
+--------------+ #
|Jenkins master| #
+--------------+ #
       |         #
       |Provision   +--------+
       +----------->|Cloud VM|
       |         #  +--------+
       | Login as root  |
       | port 22        |
       +--------------->|
       | Port           |
       | closed         |
       |<---------------+
       |         #      |
       v         #      v
     sleep       # Boot finished
       .         #      |
       . Login as root  .
       . port 22        .
       +--------------->|
       .         #      | Call                        +-----------+
       .         #      +---------------------------->|Init script|
       .         #      .                             +-----------+
       .         #      .                                   |
       .         #      .                                   v
       .         #      .                              Install Git
       .         #      .                                   |
       .         #      .                                   v
       .         #      .                          git clone mender-qa
       .         #      .                                   |
       .         #      .                                   |Source +------------------------+
       .         #      .                                   +------>|initialize-build-host.sh|
       .         #      .                                   .       +------------------------+
       .         #      .                                   .                   |
       .         #      .                                   .                   v
       .         #      .                                   .      Run remaining script commands
       .         #      .                                   .        (usually package installs)
       .         #      .                                   .                   |
       .         #      .                                   |<------------------'
       .         #      .                                   |
       .         #      |<----------------------------------'
       .         #      |
       |<---------------'
       |         #      .
       | Build   #      .
       | recipe  #      .
       +--------------->|
       .         #      | Source                                    +------------------------+
       .         #      +------------------------------------------>|initialize-build-host.sh|
       .         #      .                                           +------------------------+
       .         #      .                                                       |
       .         #      .                                                       v
       .         #      .                                                Build and test
       .         #      .                                                   CFEngine
       .         #      .                                                       |
       .         #      |<------------------------------------------------------'
       .         #      |
       . Transfer       |
       . artifacts      |
       |<---------------'
       |         #      .
       v         #      .
  Kill slave     #      _
       |         #
       v         #
    Finished     #
                 #
```


Nested VMs
----------

We build on a number of very old platforms, and Cloud providers do not provide
images for these , so we need to run those in a special manner. The way we do
this is by launching a normal cloud instance with a recent Linux installation,
and then we run a nested VM inside this one with the desired OS.

Here is a diagram displaying the launch sequence for the nested VM
configuration:

```
 Jenkins master                                           Cloud VM machine                                         Nested VM
    machine                                                       |                                                 machine
       |                                                          |                                                    |
/===============\ /============================================================================================\ /============\
                 #                                                                                              #
                 #                                                                                              #
+--------------+ #                                                                                              #
|Jenkins master| #                                                                                              #
+--------------+ #                                                                                              #
       |         #                                                                                              #
       |Provision   +--------+                                                                                  #
       +----------->|Cloud VM|                                                                                  #
       |         #  +--------+                                                                                  #
       | Login jenkins  |                                                                                       #
       | port 222 [1]   |                                                                                       #
       +--------------->|                                                                                       #
       | Port           |                                                                                       #
       | closed         |                                                                                       #
       |<---------------+                                                                                       #
       |         #      |                                                                                       #
       v         #      v                                                                                       #
     sleep       # Boot finished                                                                                #
       .         #      |                                                                                       #
       .         #      |        +----------------+                                                             #
       .         #      +------->|User data script|                                                             #
       .         #      .        +----------------+                                                             #
       .         #      .                |                                                                      #
       .         #      .                v                                                                      #
       .         #      .           Install Git                                                                 #
       .         #      .                |                                                                      #
       .         #      .                v                                                                      #
       .         #      .        git clone mender-qa                                                            #
       .         #      .                |                                                                      #
       .         #      .                | Source     +-----------------------+                                 #
       .         #      .                +----------->|initialize-user-data.sh|                                 #
       .         #      .                .            +-----------------------+                                 #
       .         #      .                .                        |                                             #
       .         #      .                .                        v                                             #
       .         #      .                .               Create jenkins user                                    #
       .         #      .                .                        |                                             #
       .         #      .                .                        v                                             #
       .         #      .                .                   Prepare sudo                                       #
       .         #      .                .                        |                                             #
       .         #      .                .                        v                                             #
       .         #      .                .                   Open port 222                                      #
       .         #      .                .                        |                                             #
       . Login jenkins  .                |<-----------------------'                                             #
       . port 222       .                |                                                                      #
       +--------------->|                |                                                                      #
       .         #      | Call         .---.          +-----------+                                             #
       .         #      +--------------' | `--------->|Init script|                                             #
       .         #      .                v            +-----------+                                             #
       .         #      .          Insert keys to           |                                                   #
       .         #      .           image host              v                                                   #
       .         #      .             (id_rsa)        Wait for user                                             #
       .         #      .                |             data script                                              #
       .         #      .                v              to finish                                               #
       .         #      .           Mount image             .                                                   #
       .         #      .          host NFS share           .                                                   #
       .         #      .                |                  .                                                   #
       .         #      .                | Call           .---.                                  +------------+ #
       .         #      .                +----------------' . `--------------------------------->|nested-vm.sh| #
       .         #      .                .                  .                                    +------------+ #
       .         #      .                .                  .                                          |        #
       .         #      .                .                  .                                          v        #
       .         #      .                .                  .                                      Copy VM to   #
       .         #      .                .                  .                                      local disk   #
       .         #      .                .                  .                                          |        #
       .         #      .                .                  .                                          v        #
       .         #      .                .                  .                                  Copy authorized_keys
       .         #      .                .                  .                                    keys to VM /root
       .         #      .                .                  .                                          |        #
       .         #      .                .                  .                                          | Launch #  +---------+
       .         #      .                .                  .                                          +---------->|Nested VM|
       .         #      .                .                  .                                          |        #  +---------+
       .         #      .                .                  .                                          v        #       |
       .         #      .                .                  .                                     Wait for IP   #       |
       .         #      .                .                  .                                          .        #       v
       .         #      .                .                  .                                          .        # Boot finished
       .         #      .                .                  .                                          .        #       .
       .         #      .                .                  .                                          . Create         .
       .         #      .                .                  .                                          . jenkins user   .
       .         #      .                .                  .                                          +--------------->|
       .         #      .                .                  .                                          |<---------------+
       .         #      .                .                  .                                          |        #       .
       .         #      .                .                  .                                          | Install        .
       .         #      .                .                  .                                          | authorized_keys.
       .         #      .                .                  .                                          | to             .
       .         #      .                .                  .                                          | /home/jenkins  .
       .         #      .                .                  .                                          +--------------->|
       .         #      .                .                  .                                          |<---------------+
       .         #      .                .                  .                                          |        #       .
       .         #      .                .                  .                                          | Install rsync  .
       .         #      .                .                  .                                          +--------------->|
       .         #      .                .                  .                                          |<---------------+
       .         #      .                .                .---.                                        |        #       .
       .         #      .                |<---------------' . `----------------------------------------'        #       .
       .         #      .                |                  .                                                   #       .
       .         #      |<---------------'                  .                                                   #       .
       .         #      .                                   .                                                   #       .
       .         #      .                                   |Source +------------------------+                  #       .
       .         #      .                                   +------>|initialize-build-host.sh|                  #       .
       .         #      .                                   .       +------------------------+                  #       .
       .         #      .                                   .                   |                               #       .
       .         #      .                                   .                   | Transfer mender-qa            #       .
       .         #      .                                   .                   +-------------------------------------->|
       .         #      .                                   .                   |<--------------------------------------+
       .         #      .                                   .                   |                               #       .
       .         #      .                                   .                   v                               #       .
       .         #      .                                   .       (Skip workspace transfer)                   #       .
       .         #      .                                   .                   |                               #       .
       .         #      .                                   .                   v                               #       .
       .         #      .                                   .          Run on_proxy function                    #       .
       .         #      .                                   .         (usually Java install)                    #       .
       .         #      .                                   .                   |                               #       .
       .         #      .                                   .                   | Run remaining script commands #       .
       .         #      .                                   .                   | (usually package installs)    #       .
       .         #      .                                   .                   +-------------------------------------->|
       .         #      .                                   .                   |<--------------------------------------+
       .         #      .                                   .                   |                               #       .
       .         #      .                                   .                   v                               #       .
       .         #      .                                   .       (Skip workspace transfer)                   #       .
       .         #      .                                   .                   |                               #       .
       .         #      .                                   |<------------------'                               #       .
       .         #      .                                   |                                                   #       .
       .         #      |<----------------------------------'                                                   #       .
       .         #      |                                                                                       #       .
       |<---------------'                                                                                       #       .
       |         #      .                                                                                       #       .
       | Build   #      .                                                                                       #       .
       | recipe  #      .                                                                                       #       .
       +--------------->|                                                                                       #       .
       .         #      | Source                                    +------------------------+                  #       .
       .         #      +------------------------------------------>|initialize-build-host.sh|                  #       .
       .         #      .                                           +------------------------+                  #       .
       .         #      .                                                       |                               #       .
       .         #      .                                                       | Transfer mender-qa            #       .
       .         #      .                                                       +-------------------------------------->|
       .         #      .                                                       |<--------------------------------------+
       .         #      .                                                       |                               #       .
       .         #      .                                                       | Transfer workspace            #       .
       .         #      .                                                       +-------------------------------------->|
       .         #      .                                                       |<--------------------------------------+
       .         #      .                                                       |                               #       .
       .         #      .                                                       v                               #       .
       .         #      .                                              Run on_proxy function                    #       .
       .         #      .                                                (usually empty)                        #       .
       .         #      .                                                       |                               #       .
       .         #      .                                                       | Run remaining script commands #       .
       .         #      .                                                       +-------------------------------------->|
       .         #      .                                                       |                               #       |
       .         #      .                                                       |                               #       v
       .         #      .                                                       |                               # Build and test
       .         #      .                                                       |                               #    CFEngine
       .         #      .                                                       |                               #       |
       .         #      .                                                       |<--------------------------------------+
       .         #      .                                                       |                               #       .
       .         #      .                                                       | Transfer workspace back       #       .
       .         #      .                                                       +-------------------------------------->|
       .         #      .                                                       |<--------------------------------------+
       .         #      .                                                       |                               #       .
       .         #      |<------------------------------------------------------'                               #       .
       .         #      |                                                                                       #       .
       . Transfer       |                                                                                       #       .
       . artifacts      |                                                                                       #       .
       |<---------------'                                                                                       #       .
       |         #      .                                                                                       #       .
       v         #      .                                                                                       #       .
  Kill slave     #      _                                                                                       #       _
       |         #                                                                                              #
       v         #                                                                                              #
    Finished     #                                                                                              #
                 #                                                                                              #
```

Tips and lessons learned
------------------------

* To follow the launching of a slave, start a build, and as soon as the build
  slave pops up (even if it says "(offline)"), click it and select Log. This
  allows you to follow the log of what's happening.

* Since user data scripts run as a service on the platform, they do not give
  *any* output. Right now the initialize-build-host.sh script will dump the
  output of the user data log (`/var/log/cloud-init-output.log`), but this only
  happens if the init script successfully runs. Hence if something fails in the
  user data section, and this causes the init script not to run, you'll never
  see it.

* If anything causes Jenkins to abort provisioning (see next point), it will
  terminate both the Jenkins node and the VM *immediately*. This sometimes
  happens so quick that the log doesn't even have time to update before it's
  gone, and then the output is lost besides what you have already captured in
  the browser. At least this is true when using the DigitalOcean plugin. Debug
  sleeps can help in this regard.

* Reasons Jenkins might abort the slave provisioning are:
  * Login credentials are wrong (see notes about port 222 below)
  * Init script return non-zero.
  * Java doesn't exist or is wrong version.

* Make small changes. Due to the many things that can potentially go wrong, and
  the difficulty of capturing output correctly if it does, it's better to debug
  one thing at a time.

* Keep the "idle termination timer", specified in the config screen, low. You
  don't want to wait long for it to expire to make your next attempt, and trying
  to kill slaves manually results in Jenkins getting screwed up, thinking it has
  more slaves active than it does. It also means the slaves won't be properly
  cleaned up in DigitalOcean.

* Make sure no one else is editing the config screen of Jenkins when you
  are. Jenkins provides no synchronization whatsoever, and will happily
  overwrite changes others have made while you were on the config screen, and
  vice versa. You can recover lost changes in the jenkins-jobs private
  repository, but this is tedious.

Notes
-----

1. Why is it necessary to connect on port 222? Well, it's not strictly
   necessary, but what tends to happen if you don't is that Jenkins tries to
   connect, and this often happens after ssh is up, but before the jenkins user
   has been added yet. Unlike "port closed", which is a temporary error, failure
   to authenticate is a permanent error for Jenkins, and this causes it to give
   up immediately and tear down the whole VM. It will try again, but will
   instantiate a new VM to do so, and this loop can repeat many times until we
   are lucky, the timing is right and we can authenticate as the jenkins
   user. This is why we use port 222, in order to force the port to remain
   closed until we know it's ready to connect to.


Glossary
--------

* User data script - The script which is specified as the "user data" to the
  cloud instance. This is specified in the plugin configuration for the cloud
  provider. This is run automatically during boot of the instance.

* initialize-user-data.sh - The script of this name inside mender-qa. It is
  expected to source this script in the user data script.

* Init script - The script which is specified as the "init script" to the cloud
  instance. This is specified in the plugin configuration for the cloud
  provider. This is run by Jenkins when it connects, but before it has installed
  and launched its own Java agent.

* initialize-build-host.sh - The script of this name inside mender-qa. It is
  expected to source this script in all scripts that will make use of the build
  host, both the init script, and every recipe that will build on it. If using a
  nested VM (which makes the original host a proxy), it will copy itself to the
  nested VM and run the script there instead, ignoring any remaining commands on
  the proxy host, with the exception of commands inside the `on_proxy()`
  function. Note that commands executed before this script is sourced are run on
  both hosts. The file `$HOME/proxy-target.txt` is expected to contain the
  address of the build slave to log in to if this is a proxy, and if it is
  missing, it means that the current host is the build slave.

* nested-vm.sh - The script of this name inside mender-qa. The script is given
  one argument which is the image to boot, and it should be run from the user
  data script.

* CloudInit - The service that runs user data scripts. Only present on more
  recent Linux distributions.
