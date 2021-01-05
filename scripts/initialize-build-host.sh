#!/bin/false

# This file should be sourced, not run.

# When sourced, this script will do several things:
#
# 1. Will wait for the cloud-init service to finish running, in order to enforce
#    serial execution of initialization steps. It will post the output when
#    finished, if any.
#
# 2. If $HOME/proxy-target.txt exists, it means this is a proxy host, and the
#    real build machine is on the host specified by the login details inside
#    that file. If the file does not exist, we are on the build slave itself.
#    After figuring that stuff out, this script will run either on_proxy() or
#    the rest of the original script that sourced this file, depending on
#    whether we are on the proxy or build host, respectively. Note that commands
#    that are specified *before* this script is sourced will run on both hosts,
#    so make sure this is sourced early, but after on_proxy() is defined.
#
# The script is expected to be sourced early in the init-script phase after
# provisioning.


# Keys that you can use to log in to the build slaves.
SSH_KEYS='
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCni4pKbhXkYZo0/Rz8v/pzjIfQdZTm1UtsqkTxY2OlIUiDgWIdBsYtEkYD6Z4bdGO0FfbZjwb18Sz9Dl7voVnMqavtWUN1ZVtsrutaKZ2Aa8rphSGE2dplUJGdTKjKAgL5nhBSAk5h73WcZ+vhDhv3ZNP4k+qS566BwJvhRDysSxmYaRCumOgMhk6AQ0GoYy2n7p8D/6+J3t0JnLq17MqKqC51sXZL1q9XBMCB1To4s1HYA0t2pORnm9fAU+QbJVyHwCD+Ng1/x/9Reaf9eJp8OpwE05HGbNDtlywGsov0Q/l6NCLcv+ZJTi/bjkqDlFAXXkZbmQHG1JNEzc2Df6N37D30GwI/xPwbEVu1LW4W2sKgF4lcj82A17CSL/WpJyDSB3Sm2XbJ+KjlMJLuKh7Jzp/PwDm5LBb7x91gKqcNSHrEwVOxQ4vRekOu1jKQCx8SxVY/yE88YRKgdxjT+p1eHv2Kt1pk6IC78hPFBUY538nSleem6gajRuJIDOBToAhg+VUULdJ/1bwooglFAZzZEJvwIBU4bIZ0O0OjRyxppQLzMsen9CT3QQucV49KiRas+DP7durMZHBMB9i/i28jyfouAaygGynNqB4Fo0K9rg5YLprxdI1S0FjHYucpkM8tRugiFz5moBxctthVmmvT92mai7HnLscN3Xu8TTC23w== craig_comstock@yahoo.com
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCz3yWxbpXj49IYZgxtwjRNiF+wuu58Kq1QoiRH8Q9UPK4kA7gQf53GFvZj4W2QhzJvrKUwo67Aw/ywxWHxzBiNZCcRweB21E6WOK0DJe6+t/lXzzVl7eTmctfh5zsZLMbSSd4TM+05fMh/qjPN18Khb1zsvWP4rYfZcnhPWu2MoMOjbydwN4OlT8AxMVWZC+0rNqR7ghUlPHgGAY0dW/iGGodX6+wvoq5D2hNSeqxwKAW4/WEMHO0Vzl6DZIYtHB3h6U0KuGmPkZjj60oJvjWsJjWMZzdxvZNB373q8z9wgp+QdZYHiTKldi/mitWQT3c8nNFhFEE/8tNx7wMmdy5H lex@flower
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDDmlwzo9m1ypsusAp9cVj+XgmDBsZMPdZzIt15pM7Ay2Ie4dl0TtVpj/H9S5O5NsHkQ/fPEaWCpZGgbRrOsrb3wgMg0qM6pA5fvbmCBKxvdvCwp03FyATY0yC+OnvmnWtLOshdZX1gZjzQwiEG/UFyl0N5p/wu8cJv+ODWJ+EOLWs0yTie8oCV2XXFiRsby9qCwDCQIvXrbp1amZJOYNW49GNPKEoJgq6D9fZ5mYE/ozoUdW2ecIOWRWDMI+4AKv48JYPN/wtYJnUs/JmRHUc4HTZ7P9wsXLSc8F+9eVEWzGIZL8WuCS3L8V1n3tPJIxZhQKe3R8DcjER07M+0J9HP kristian@kristian-mender
ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAy6vrcU1d/80WMFqzumFHG/dllkhakswezvKfX7KupQwpc55JyyUNpnjxLy76leuJnlTTZTaxq1CcW3lIH9CjG/rJVQLN/PLjQPLZgfvzHqS8HuVCtKynwp0Sgw9tRmrN1KcXRiQMWs3plVDJwB4HFQpb7NsC0f5fskpgxr2KRNPn058oe6VYx183Err/0Uawy64aFSiowRgvHgXgelhSDWUVkOoviKR1zB11EZ8Xr5d4s/yXDE9ehlgv2EBFdhZrqsMmhs7KdPPNDD6/El2dID7V7LKHblbtVO009VS/dlq1XUGE0IUl153ZaVm/dt4+2+NriGpI7COAU4cLxhpj9w== cmdln@tp
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC/NLV9UQu5eXr/CE9NfnC6IsvLx+vvVDxpbIfOVNhBjpLHoXqLDVedAT4dn+82x+OulBXdYzZkEGoKlkBkbmxjsXBF6gX1oWFnSmdlZNEe+GqTcfRHL4+fF09oUh6tCdCBFaMLbkdA1M+UvYtJc8BZoNUXCVG/Sn0saVLDOFfmUG9ICfmVFzwcVW+X6+qfyauBC6lGtW/Bnqj6GY6VaSo94cYyLUFeUI1GbJ5sDmkFKBXn/p/1ks6eWlejcs2Q/mqqaH5sseek+0MP8qHss9HSZzbn9Iq4n1uUW43NBu242KISE/fDDqZtJs54zJmt97cDOgr+p0wglwFUT8x6Grl5 build-sstate-cache@mender
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC5MGowxEkIXVweJId1Fmxp+EL+0e19xH8OPdwfc9daepPaT8SmYqVNq+YA6/PJUUr39oGgTdX6iK2dk5JW4OqgtcwotECspW7mVfF7izLapw/bpFOWryhJmVlYXKnwg61tcmZHMtVf+cSPcljyjAH+gULA+mzivikfKl9YHoHZI1BbxcqNUz5uJxw/WiZr9BLd+ZRw7D53HpNPGlfyHZOi+DzjZmmfdk9MqA/fiEoxw2nSXBE10n9bC/dxplvOvKvNXjVPFs/UpUpanY4AGsFCWM1+7z2c8LxpWanBLHYSVLH0Ung+uJVu6gtnSK4jKwWfPuHGJ6Qi7ZQo4Uyw90rN buildmaster@buildmaster
ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA3Jo+DWnGMqK2SoU9ZqBS/yFsrOy6GAKcMeKFV79Bp3nRCjSzgOhRI5lmTU9tSg5IHkBqiv0qjkEyaxjrV/rX5JGRrFfpJT0uuNcNvPTlhNuWnkdmv/Xy5zwU27AMdz2/kRsEPEdYWwch5wd7VV1xgxiJG0yGMCVeRpLYrUJpILt1LHMz+HYYjiz6dHxfCgcywCs7aaFS4Z//Idwm0XOnzpDpBb3tBCtQjiOY88N4xfGwUpx8A1+bq4Wg2pQ0RJxabvtLp9oJ1s5h9Be0ZUKwChAiqOlG6ATsYk/09Uwj3ypdPMjFYZ1HWuoKH1KkLmhwpw6K9Mg21loy0TEBGYIOSQ== root@buildmaster
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDNnTtUnV0GbKJPA6ICnI9CS3zIaXmmXeN8FquEuduHpHfk6KUYi1ScH7dSspa1ETUb43piKS4Pp5kJ5sn+SisWlDt0520OoFKxM89avS2I8Ml/bEG/BbRmfC1oI+0i/R6iygHVe5nyDMLNd7VfRxlncC0pe2zuT46thwBnyhhDFJHFETLO8r+KJqOFIztO0h1DFc3DZXp7eBTCqIeImDB+aVO7rUyvKhnrQCdvA/zR2U7XYQBgcDvnZCeYwn7pZABHnKY2iWUjH7T6tvouu25oBsiRcuJJ6A2d+mfnQSrdxVglULWxo8ECyX+YYzuzqb9k72BEvIO/An1cCy2llPImIGi5QYM6nDtT+hLPrf0UnPERYIjESkhmSYpXoUWCsW3+zWYxc7CESmIY9M/fPyrRqKaUd9on6aSBqMaBH6MwK8R4iK8O1sElANhDNuqgzLuYzThiItOAbYMmUirRTnVPByETrMu7qoPILDvEUsdbuGdmtF7QGd9B9V3zBSTzCeP0FcHdDRSrT1C4zPCq8lAZGgMSL4Fo7fDgNRwR1irIMu/KWZPvjzF3jVCLf+G+LRBmoPl9xkAfvHNTfnJzbvGcJ8NFd2ecHeQSciwT0EgnkcBWhJBSrCNNDyufbc1gXnkewi5FQeogEJWOQk52UdQqtTS0PIn1lC/4+gsK/afYUQ== ole.orhagen@northern.tech
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDMlalU0tstx48b98vad9UMMqbqx7dp37uFXpSacU/sveOrIAPclXUXfUILmXB51ucXXh6G7UO2oy23SyvzquRl3Bmop8+ZEa9TPPuwj3SQAhuxpSHRpWU9qMC1N8M2i0l3fPF+qcWHD7Uhi92/nz2QUdChr6lExy+k+95euGfWjW7RpL0248NkfChVJRLeoKkbNYuMzgeMJ5pkn/epn9B+/N0W1KZDYb+fXPSc6lVRtYbd9RSUxnAZI7iMaMkGAuqakFY/307lZNOLoRbJJqP8MDhEBwVj82uYgQdTtIYM4mE6pRK9shz0Dz5Hx/fRgCv9QihNjMFSECM6Q3xNp5+D karl.totland@northern.tech
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCtoU/75IdcahCzBY9RbSrouIHq0sWZU4xQr9wopGtZlSTOUN1CUAuNzEdTHi1ftmLIQHGGAQ/ZhPwRaToMqQVT9GM8YhRvgIpRkJacIQO85I/jQB0Tl0y5cZ2hu914zWVQ8vGCuRU3kwJncm0l1RvqFD5Nfk54McB6nHi4TSwXuOMZcRZDw5NUWu5sk0q4bCZzFHvRvledD4zHWHdkXkl1PC+E7VtemkqDkRYCES+sb8MN1wpWMmBdulYh4alVNNqfKlIIRPreDDzLa2VSNa8pX9xaPbkhOHQ3rBVWmcMW3HLe5gEhPLYDepqvLES0/+ncPLumtTET2BvmW+0uM/CD vratislav.podzimek@northern.tech
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCf15IaQYmnUW5L83O2mR0DX8Oxlie7zJG0W90Y4Nl7/JlHFtA00u2aDGHdqePlKg7WZREZf2//At5kaz6MosStjlHUuMEKF+xat3rJU5mjljQ4b9MGw1vXLOBZFBIZMcaTTZPmB+nssvoKWNPxjmYysTjXcXZEMwPAI2PXUBzSywK9gGtBJptoYC4n7aIiCXSTYL2wAhLJIG5RZYxhF5Q0evNK446evNBYxcxG+RMxzQFqKc4LyCwQURLeCTExXWL4W+fiYmYnuCuxZe95yn7j/i6Ms1SYWhM6q++UEitjBzoTC/x4jClAfkR9XcS9tAnuZ8jD/cN41aVbEQRRZyBr6cWvVW27fdNsxfrx52jQ/16HFqG8EzMOxFfMj4TfaAY2MUBUTBSUh7xOVcDj1xKGcjoyBE5V6q11csEHXoBFe+NUoCEWa5rb4DND4VGZs37wTRjySJJOTXDzs53nAKNwl9paE6fSuIoaPwuNcn+6TH0GEGjIERNotu23i5kZmnmq47DmNIps2tGQWAZh0RBYTWzQ3wo770JHpuRkMoR34PacKBfxFSobmbIBHo3j365kllLVt6jGVBUr+efzQxD83ySfGt2rFf3z3/V5DzM5oNWXef142kptEnNndJWLuTUiOslNZWj/AXierDX/vZ17L6cTaOEO05qIIn9Da8GMnw== krzysiekjaskiewicz@gmail.com
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC7k+hLCll/m4XRX+XWixUD97yMSr1GY2XfTA2875R5np1HiwoZtsSTXJgV8FwJwmtcBT0q8ULL1ZxoTb+ZV16E/Bgkcn3k6rmmHTdb9HQFcRNGRAkFIfocAHONe6fUuWdVoRvU0/am95u9BUiF/9di2ZFoekFWqh8o6asqgzGtoddhKDRhlWeFwgw7UA71O2E967KgQWR+BxqRG1+2PWQ3DNCWxhExqPRu1t3Q+OBBSHALeVBF27kmHAhTYOT2PP+h6baJ7qBmM6ZpI8cdhagEISC4qHJPJdf5Kqatj2AfHT7qs1TnmIMp6uDNeH+Z5xeEoiELPB9YHuOmskT2+e1zit7ijbSne4Qu3KDKaij21Za5Nn2e1vMXGA25Y1xo59YB+URoAfGk6+gPLDu5Fzd+qVcbn1BwuF16NixuSnKjkPyi1vl3gLm6+7M6mzge7zo1GI8SHuG0MfnPQReUGEhrx6zJzcr57OhYGQqAwAK6j0AdytOoT/8Ve89yHMV3b3UUXA6yDpBsnLZnDG4+LBqgpOdraqfniO57jWwddSOWt7GiOxrEt4Brj21nt4LQwCjxXQi+SkB7lvnmPhlEj2AEqWH86Qntw8cOEM2XJIO6//6saY2Zt6zP8gqx+EGBhy562faR3XMIz76BVjm3Wu0EotsFcnJanWgiqO/PREb9YQ== m.chalczynski@gmail.com
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDln8c/w2aQWW4kB6PwP8mE7uQeURTc/H7VC7QEWmxF2EB4Ld0mEvyPy6Q3ukbgTVFd/ooI35Vyno/zuIveGIEY9FflYSRmhlCJCz9Un7X1krqjtT0ymbjKDvCoNUw0BolZ4Rb+QR/6bu/JNJay+rgXFmkQHizawflu9bVKRRf7yFRmyvIESoKhI4vLXxHpdSfY0lKQDqjkG6dY8hL0PSHIvVOHdUBq/H+biLzInJjX0w565IDbsUuPVWiyBpm6F5xSN2oKTFje6nvlVh1Dxo2aX51lwQViaOMFZhZ4OcSfYkORj37k+C4BTsNTR66JbnqLOOX+V1+x4uhJW7ca1WXtInwNCFXdCtHvYyH0Xlsen/7F7SxHDT/ipQdQeLcT7twFXOOlaMYTMEX/bVqWbT/7nCD+oHk4chWAkRFO2bvEqkIMNKdtrSin4fHQCX5SDvHgwwZ5K0MIfUjfWsJIUkIua9vpwEOrQlpvR/i91+GV7laCeWCh1xMtSF26PfwyjwXtUDPj5WiGtlAsLR+lI12u0S88Ti9zOKuMWBsBYzfrGRv0TQf0wRneOTk3oMFW+cREOWKbLwt1ZgXTyVDClmRBvrt+Sje8Ph55/OXaYlXfFy7OmJO3kdGn98uW79OuMPBEo9sOiH36+DNcY7wdCO8PW2B5HfXNWI4z4NKPdDNZwQ== lluis.campos@northern.tech
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDUDxgQrGTOT1DJCNUS0RrO4wthwVBzhbXLDefv39CUD6y306jMP4qnUGto22cBqqo8rcnyqmQV87xa7Axy8FaVgB/PIqsfZKYXETJS3EegYhUeFAnxkTlYQX8GUXJBHffFfEJYDqGn90Bw+O0WtRwEvZy9hy3JdSUEcJ5Fg0C9VvhKqiA5yyX2xVJLXiKFW/MECTgfiyhm7B55/SdeSilMF8qaANJQdoYw0uYKDj8/5aRjjyFjAcKctB+6RoYtVHH7i2yvV3G+cio0bH9CA+pw5UVRHIa/wAQzP1fgC3N/m4yEl+STa/MQdWhSCwfTIzd22Y6DReKXC64HbSg2pxdh alex@northern.tech
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDNn4W5ZV07WPrIJ0oBgc1f9ibW+O0BoZ6HE2adtTjSo3JF8KQ1wZyN4MS9i9aTZkaBSrea7YYlw5D1slwXp6Gg0xSJH/NZnjnLCMw5OAhfrEK9KmyBkwf0sU/nrbHfCofwewckeToFEko6OBIWwpcrywIbGtmTgu7GXgyY0w2+7YlYQns3jiTcYEEqKtv8ivqBve+4QzvZhbVXzNMdMyEtdWUwthiEr69QovaFcx6r0sp6fN84GkOq7iZpvzeGkaG/2iLf76S/OiGoNAsmg3IldVeDY9/vKfgzvhbdoWaPDxFRt9a4Gf20DcpdKqSlRXk/jM03BqWOUsxrKmV240rwszevFrRJy5SbrAi9Ac9Z8b/sIfKzBeimYmhdAxI7INuHH+63y0AzzCJvqQfOIuMv8WWCzHQIezpAO0+7RCAcurhlwApf2+y1nzmAQOLkybJ/poUwewbn13ZdD1f3z2KyRLl/k7dM5RYXxesJPMs4w87XTDuouybYZVu1IzmYImgnANBYMuXJfOPCRDtmIEHEZAgLDRa7otfkdie0CQP9u7zGn+bzoRIkeCxhIaxX3EXCzdVHJhfP481d+aOb/l+zS2YYXhcwPgMaLO1YhjzhFR+EP4BZLR/JIZnlT8jsrwEF5b7F0UbtFcdYSxUrgpnb0kWzGwqVhuQ8NOSBnNNbYQ== peter@northern.tech
'

#
# Detect and replace non-POSIX shell
#
try_exec() {
    type "$1" > /dev/null 2>&1 && exec "$@"
}

broken_posix_shell()
{
    unset foo
    local foo=1 || true
    test "$foo" != "1" || return $?
    return 0
}

set_github_status()
{
    # first check if already reported
    if [ "x$GH_STATUS_REPORTED" = "x1" ]
    then
        return 0
    fi

    set +e  # this is not critical
    if [ -f "$WORKSPACE"/GITHUB_STATUS_TOKEN ] && [ -f "$WORKSPACE"/GH_status_info.json ] &&
       [ -f "$WORKSPACE"/output/PRs ] &&
       [ -f "$WORKSPACE"/buildscripts/build-scripts/set_github_status.sh ]
    then
        GITHUB_STATUS_TOKEN=`cat "$WORKSPACE"/GITHUB_STATUS_TOKEN`
        export GITHUB_STATUS_TOKEN
        rm -f "$WORKSPACE"/GITHUB_STATUS_TOKEN
        bash -x "$WORKSPACE"/buildscripts/build-scripts/set_github_status.sh "$WORKSPACE"/output/PRs "$WORKSPACE"/GH_status_info.json
    fi
    set -e
    return 0
}

if broken_posix_shell >/dev/null 2>&1; then
    try_exec /usr/xpg4/bin/sh "$0" "$@"
    echo "No compatible shell script interpreter found."
    echo "Please find a POSIX shell for your system."
    exit 42
fi

# Make sure the GH PR status is attempted to be set at the end, but not multiple
# times and only in the proxy if this is a proxied job.
if [ -z "$PROXIED" ] || [ "x$PROXIED" = "x0" ];
then
    GH_STATUS_REPORTED=0
    trap set_github_status EXIT
fi

# Make sure error detection and verbose output is on, if they aren't already.
set -x -e


echo "Current user: $USER"
echo "IP information:"
/sbin/ifconfig -a || true
/sbin/ip addr || true


RSYNC="rsync --delete -czrlpt -T /tmp"
RSH="ssh -o BatchMode=yes"

# Support launching scripts that were initially launched under bash.
if [ -n "$BASH_VERSION" ]
then
    SUBSHELL=bash
else
    SUBSHELL=sh
fi

if [ "$STOP_SLAVE" = "true" ]; then
    touch $HOME/stop_slave
else
    if [ -f $HOME/stop_slave ]; then
        rm $HOME/stop_slave
    fi
fi

# In the "user-data" script, i.e. the one that runs on VM boot by
# cloud-init process, there are a bunch of commands running even *after*
# the 222 port has been opened. Wait for it to complete.
# Same on Google Cloud, the only difference is that process name is
# google_metadata, and we don't use port 222, since it can't be
# Configured in Jenkins.
# Also, we timeout (and abort the build) after 25 minutes.
attempts=150
while pgrep cloud-init >/dev/null 2>&1 || pgrep google_metadata >/dev/null 2>&1
do
    attempts=`expr $attempts - 1 || true`
    if [ $attempts -le 0 ]
    then
        break
    fi
    echo "Waiting 10 seconds until the cloud-init stage is done..."
    sleep 10
done

echo '========================================= PRINTING CLOUD-INIT LOG ==================================================='
sed 's/^.*/>>> &/' /var/log/cloud-init-output.log || true
echo '======================================= DONE PRINTING CLOUD-INIT LOG ================================================'

if [ $attempts -le 0 ]
then
    echo "Timeout when waiting for cloud-init stage to finish"
    ps -efH
    exit 1
fi

echo '=========================================== CURRENT ENVIRONMENT ====================================================='
export
echo '========================================= CURRENT ENVIRONMENT END ==================================================='

# Disable TTY requirement. This normally happens in initialize-user-data.sh, but
# for hosts that do not support cloud user data, it may not have happened
# yet. These hosts are always using root as login, since they cannot create any
# new users without the user data section. We still need to disable the TTY
# requirement, since even root will use sudo inside the scripts. If we are not
# root, we cannot do anything.
if [ "$(id -u)" = 0 ] && [ -f /etc/sudoers ]
then
    sed -i -e 's/^\( *Defaults *requiretty *\)$/# \1/' /etc/sudoers
    # Fix `hostname -f`, if it's broken - working `hostname -f` is needed for CFEngine
    # and some CFEngine acceptance tests
    hostname -f || hostname localhost
    # Ensure reverse hostname resolution is correct and 127.0.0.1 is always 'localhost'.
    # There's no nice shell command to test it but this one:
    # python -c 'import socket;print socket.gethostbyaddr("127.0.0.1")'
    sed -i -e '1s/^/127.0.0.1 localhost localhost.localdomian\n/' /etc/hosts
fi

apt_get() {
    # Work around apt-get not waiting for a lock if it's taken. We want to wait
    # for it instead of bailing out. No good return code to check unfortunately,
    # so we just have to look inside the log.

    pid=$$
    # Maximum five minute wait (30 * 10 seconds)
    attempts=30

    while true
    do
        ( /usr/bin/apt-get "$@" 2>&1 ; echo $? > /tmp/apt-get-return-code.$pid.txt ) | tee /tmp/apt-get.$pid.log
        if [ $attempts -gt 0 ] && \
               [ "$(cat /tmp/apt-get-return-code.$pid.txt)" -ne 0 ] && \
               fgrep "Could not get lock" /tmp/apt-get.$pid.log > /dev/null
        then
            attempts=`expr $attempts - 1 || true`
            sleep 10
        else
            break
        fi
    done

    ret="$(cat /tmp/apt-get-return-code.$pid.txt)"
    rm -f /tmp/apt-get-return-code.$pid.txt /tmp/apt-get.$pid.log

    return "$ret"
}
alias apt=apt_get
alias apt-get=apt_get

reset_nested_vm() {
    if sudo dmesg | grep -q "BIOS Google"
    then
	# We're in Google Cloud, so just need to run nested-vm script again
        if [ ! -d $HOME/mender-qa ]
	then
            echo "Where is mender-qa repo gone?"
	    sudo ls -lap $HOME
	    exit 1
        fi
	files=`ls $HOME/*.qcow2 | wc -l`
	if [ $files -gt 1 ]
	then
	    echo "too many *.qcow files found:"
	    sudo ls -lap $HOME
	    exit 1
        fi
	if [ ! -f $HOME/*.qcow2 ]
	then
	    echo "no *.qcow file found:"
	    sudo ls -lap $HOME
	    exit 1
        fi
	if [ ! -z "$login" ]
	then
	    ip=`sed 's/.*@//' $HOME/proxy-target.txt`
            if sudo arp | grep -q $ip
            then
                sudo arp -d $ip
            fi
	fi
	$HOME/mender-qa/scripts/nested-vm.sh $HOME/*.qcow2
        login="`cat $HOME/proxy-target.txt`"
        if $RSH $login true
        then
            echo "Nested VM is back up, it seems. Happily continuing!"
	else
	    echo "Failed to SSH into restarted nested VM, abourting the build"
	    exit 1
        fi
    else
	# Restart using virsh
	if [ -z $login ]
	then
	    echo "Sorry, proxy-target.txt is empty - restarting virsh won't help here"
	    echo "TODO: get IP address if we ever happen here"
	fi
        VM_id="$(sudo virsh list | cut -d' ' -f 2 | sed 's/[^0-9]//g;/^$/d')"
        if [ -z "$VM_id" ]
        then
            echo "Couldn't find a VM number, is it even there?"
            sudo virsh list
            exit 1
        fi
        sudo virsh reset $VM_id
        attempts=20
        while true
        do
            if $RSH $login true
            then
                echo "Nested VM is back up, it seems. Happily continuing!"
                break
            fi
            attempts=`expr $attempts - 1 || true`
            if [ $attempts -le 0 ]
	    then
                echo "Timeout while waiting for nested VM to reboot"
                exit 1
            fi
            sleep 10
        done
    fi
}

if [ -f $HOME/proxy-target.txt ]
then
    ret=0
    on_proxy || ret=$?
    # Failure to find a function returns 127, so check for that specifically,
    # otherwise there was an error inside the function.
    if [ $ret -ne 0 -a $ret -ne 127 ]
    then
        exit $ret
    fi

    # --------------------------------------------------------------------------
    # Check target machine health.
    # --------------------------------------------------------------------------

    login="$(cat $HOME/proxy-target.txt)"

    if [ ! -z "$login" ] && $RSH $login true
    then
	:
    else
	if [ -f $HOME/on-vm-hypervisor ]
	then
            echo "Failed to SSH to nested VM, probably it's hanging, resetting it"
            reset_nested_vm
        else
            echo "Failed to SSH to proxy target, aborting the build"
	    exit 1
        fi
    fi


    # --------------------------------------------------------------------------
    # Populate build host.
    # --------------------------------------------------------------------------

    # Put our currently executing script on the proxy target.
    $RSYNC -e "$RSH"   "$0"  $login:commands-from-proxy.sh

    # And the important parts of the environment.
    for var in \
        BUILD_CAUSE \
        BUILD_CAUSE_UPSTREAMTRIGGER \
        BUILD_DISPLAY_NAME \
        BUILD_ID \
        BUILD_NUMBER \
        BUILD_TAG \
        BUILD_URL \
        EXECUTOR_NUMBER \
        EXPLICIT_RELEASE \
        HUDSON_COOKIE \
        HUDSON_HOME \
        HUDSON_SERVER_COOKIE \
        HUDSON_URL \
        JENKINS_HOME \
        JENKINS_SERVER_COOKIE \
        JENKINS_URL \
        JOB_BASE_NAME \
        JOB_NAME \
        JOB_URL \
        LOGNAME \
        NODE_LABELS \
        NODE_NAME \
        NO_TESTS \
        RELEASE_BUILD \
        ROOT_BUILD_CAUSE \
        ROOT_BUILD_CAUSE_MANUALTRIGGER \
        WORKSPACE \
        label
    do
        case "$var" in
            WORKSPACE)
                # Special handling for WORKSPACE, because local and remote home
                # directory might not be the same.
                WORKSPACE_REMOTE="$(echo "$WORKSPACE" | sed -e "s,^$HOME/*,,")"
                echo "WORKSPACE=\"\$HOME/$WORKSPACE_REMOTE\""
                echo "export WORKSPACE"
                ;;
            *)
                eval "echo $var=\\\"\$$var\\\""
                echo "export $var"
                ;;
        esac
    done > env.sh

    # make it easy to check if running in a proxied target
    echo "PROXIED=1" >> env.sh
    echo "export PROXIED" >> env.sh

    $RSYNC -e "$RSH"    env.sh  $login:.

    # And the helper tools, including this script.
    # Note that only provisioned hosts will have this in HOME, since they use
    # the repository in provisioning. Permanent hosts don't keep it in HOME,
    # in order to avoid it getting stale, and will have it in the WORKSPACE
    # instead, synced separately below.
    if [ -d $HOME/mender-qa ]
    then
        $RSYNC -e "$RSH"    $HOME/mender-qa  $login:.
    fi

    # Copy the workspace. If there is no workspace defined, we are not in the
    # job section yet.
    if [ -n "$WORKSPACE" ]
    then
        $RSH  $login  sudo rm -rf "$WORKSPACE_REMOTE" || true
        $RSH  $login  mkdir -p "$WORKSPACE_REMOTE"
        $RSYNC -e "$RSH"    "$WORKSPACE"/  $login:"$WORKSPACE_REMOTE"/
    fi

    # --------------------------------------------------------------------------
    # Run the actual job.
    # --------------------------------------------------------------------------
    echo "Entering proxy target $login"
    ret=0
    $RSH  $login \
        ". ./env.sh && cd \$WORKSPACE && $SUBSHELL \$HOME/commands-from-proxy.sh" "$@" \
        || ret=$?
    echo "Leaving proxy target $login"

    # --------------------------------------------------------------------------
    # Collect artifacts and cleanup.
    # --------------------------------------------------------------------------
    # Copy the workspace back after job has ended.
    if [ -n "$WORKSPACE" ]
    then
        $RSYNC -e "$RSH"    $login:"$WORKSPACE_REMOTE"/  "$WORKSPACE"/
    fi

    # --------------------------------------------------------------------------
    # Set GitHub PR status (if possible)
    # --------------------------------------------------------------------------
    set_github_status
    GH_STATUS_REPORTED=1  # record that the GH PR status was reported

    # Return the error code from the job.
    exit $ret
elif [ -z "$INIT_BUILD_HOST_SUB_INVOKATION" ]
then
    (
        # Switch to newline as token separator.
        IFS='
'
        # Add key, but avoid adding it more than once (important for always-on
        # build slaves).
        for key in $SSH_KEYS
        do
            if ! fgrep "$key" ~/.ssh/authorized_keys > /dev/null
            then
                echo "$key" >> ~/.ssh/authorized_keys
            fi
        done
    )

    # Add build-artifacts-cache to known hosts
    KNOWN_HOSTS_FILE=~/.ssh/known_hosts
    # if fgrep build-artifacts-cache.cloud.cfengine.com $KNOWN_HOSTS_FILE  2>/dev/null
    # then
    #     :
    # else
        echo "build-artifacts-cache.cloud.cfengine.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC6qcxCQgtubv9WEhrAyMEFFMLLEjirk0p0Ru+vATioEIyw7gBFfOWOp/dBfsF6fuiY1vt3IsBx4u1DkS4j8x7DjB8X2dIcBia2jt2D3sBdDFb/nc7ZnWfFf/E7dWoiF0WKvxZ62RwjyZuyz9TmL1d3jlIyuRimkhgwnuRAMyymJ5YbxvvfTH01OuGS/0pkqkLAxomRyJTv6qcGr1rOPd5FuySwOO5M/tGkajJppKC+8u/RCyWfgu1khrBmi6PevXTaoJ/lQyexexZK0HVsA5G1U/+ipO18DqaCCAnHvZ/AKt+yYmoe9RtLfx0T7DHinEV1yj4ynUj7EqudCrLOorg5 root@yoctobuild-sstate-cache"  > $KNOWN_HOSTS_FILE
    # fi

    # Reexecute script in order to be able to collect the return code, and
    # potentially stop the slave.
    rsync -czt "$0" $HOME/commands.sh
    ret=0
    env INIT_BUILD_HOST_SUB_INVOKATION=1 $SUBSHELL $HOME/commands.sh || ret=$?

    if [ -f "$HOME/stop_slave" ]
    then
        echo "Stopping slave due to $HOME/stop_slave."
        echo "Will keep it stopped until the file is removed."
        while [ -f "$HOME/stop_slave" ]
        do
            sleep 10
        done
    fi

    exit $ret
fi

# Else continue executing rest of calling script.
