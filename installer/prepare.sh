#!/bin/sh -e
# Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Usage: prepare.sh arch mirror distro release proxy version
ARCH="${1:-"#ARCH"}"
MIRROR="${2:-"#MIRROR"}"
DISTRO="${3:-"#DISTRO"}"
RELEASE="${4:-"#RELEASE"}"
PROXY="${5:-"#PROXY"}"
VERSION="${6:-"#VERSION"}"

# We need all paths to do administrative things
export PATH='/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin'

# Apply the proxy for this script
if [ ! "$PROXY" = 'unspecified' -a "${PROXY#"#"}" = "$PROXY" ]; then
    export http_proxy="$PROXY" https_proxy="$PROXY" ftp_proxy="$PROXY"
fi


# Takes in a list of crouton-style package names, and outputs the list, filtered
# for the current distro.
# A crouton-style package name looks something like the following:
#   distro_a+distro_b=pkg_for_a_b,distro_c=pkg_for_c,pkg_for_others
# That means distros A and B will use the first package name, distro C will use
# the second, and all others will use the third. You can also specify a specific
# release in a distro via: distro~release to filter to a specific release.
# If distros have DISTROAKA set (see the distro's prepare script), they can also
# use the pkg name for a distro they are derived from if one specific for them
# has not been specified. So if the distro is "ubuntu", it will use a "debian"
# entry if one is specified and an "ubuntu" one is not.
# The list is not ordered; instead there's a priority to the filtering:
#   specific release > distro > parent distro > any distro
# It's safe for a package name to have an = in it as long as the distro is
# specified. This is good for specifying a specific version of a Debian package
# to install, for instance.
# Leaving a pkg name blank will result in that package being dropped for that
# distro. You can do so for all distros not listed by leaving a trailing comma.
# If no package for the distro is found, this will spit out an error and exit.
distropkgs() {
    local descriptor desc pkgname rank option optionname optiondistro optionrel
    # For each package
    for descriptor in "$@"; do
        pkgname='.'
        rank=0
        # For each filter/pkgname pair (add a comma to consider trailing commas)
        desc="$descriptor,"
        while [ -n "$desc" ]; do
            option="${desc%%,*}"
            optionname="${option#*=}"
            desc="${desc#*,}"
            if [ "$optionname" = "$option" ]; then
                # No filter specified; minimum rank.
                if [ "$rank" -lt 1 ]; then
                    rank=1
                    pkgname="$optionname"
                fi
                continue
            fi
            # For each distro option in the filter
            option="${option%%=*}"
            option="${option%+}+"
            while [ -n "$option" ]; do
                optiondistro="${option%%+*}"
                option="${option#*+}"
                if [ "${optiondistro%~*}" = "$DISTRO" ]; then
                    optionrel="${optiondistro#*~}"
                    if [ "$optionrel" = "$optiondistro" ]; then
                        # No specific release specified
                        if [ "$rank" -lt 3 ]; then
                            rank=3
                            pkgname="$optionname"
                        fi
                    elif [ "$optionrel" = "$RELEASE" ]; then
                        # Specific release matches
                        if [ "$rank" -lt 4 ]; then
                            rank=4
                            pkgname="$optionname"
                        fi
                    fi
                elif [ "$optiondistro" = "$DISTROAKA" ]; then
                    # Option matches parent distro
                    if [ "$rank" -lt 2 ]; then
                        rank=2
                        pkgname="$optionname"
                    fi
                fi
            done
        done
        # Print out the result or error out if nothing found
        if [ ! "$pkgname" = '.' ]; then
            echo -n "$pkgname "
        else
            echo "Nothing specified for $DISTRO~$RELEASE in '$descriptor'" 1>&2
            exit 2
        fi
    done
}


# install: For the specified crouton-style package names (see distropkgs()),
# installs the first set, while avoiding installing the second set if they are
# not already installed. The two groups are separated by a -- entry.
# If the first parameter is --minimal, avoids installing unnecessary packages.
install() {
    install_dist `distropkgs "$@"`
}


# install_pkg: Installs the specified package file(s), ignoring dependency
# problems, and then attempts to resolve the dependencies. If called without
# parameters, simply fixes any dependency problems.
# If the first parameter is --minimal, avoids installing unnecessary packages.
install_pkg() {
    install_pkg_dist "$@"
}


# remove: Removes the specified packages. See distropkgs() for package syntax.
remove() {
    remove_dist `distropkgs "$@"`
}


# list_uninstalled: For the specified crouton-style package names (see
# distropkgs()), prints out any package that is not already installed.
# Appends each package printed out with the contents of the first parameter.
list_uninstalled() {
    suffix="$1"
    shift
    list_uninstalled_dist "$suffix" `distropkgs "$@"`
}


# Fixes the tty keyboard mode. keyboard-configuration puts tty1~6 in UTF8 mode,
# assuming they are consoles. Since everything other than tty2 can be an X11
# session, we need to revert those back to RAW. keyboard-configuration could be
# reconfigured after bootstrap, dpkg --configure -a, or dist-upgrade.
fixkeyboardmode() {
    if hash kbd_mode 2>/dev/null; then
        for tty in 1 3 4 5 6; do
            kbd_mode -s -C "/dev/tty$tty"
        done
    fi
}


# compile: Grabs the necessary dependencies and then compiles a C file from
# stdin to the specified output and strips it. Finally, removes whatever it
# installed. This allows targets to provide on-demand binaries without
# increasing the size of the chroot after install.
# $1: name; target is /usr/local/bin/crouton$1
# $2: linker flags, quoted together
# $3+: any package dependencies other than gcc and libc-dev, crouton-style.
compile() {
    local out="/usr/local/bin/crouton$1" linker="$2"
    echo "Installing dependencies for $out..." 1>&2
    shift 2
    local pkgs="gcc libc-dev $*"
    local remove="`list_uninstalled '' $pkgs`"
    install --minimal $pkgs
    echo "Compiling $out..." 1>&2
    ret=0
    if ! gcc -xc -Os - $linker -o "$out" || ! strip "$out"; then
        ret=1
    fi
    remove $remove
    return $ret
}


# The rest is dictated first by the distro-specific prepare.sh, and then by the
# selected targets.

# All distro-specific prepare.sh scripts must define the install_dist,
# install_pkg_dist, remove_dist, and list_uninstalled_dist functions.
# They must also set PKGEXT and DISTROAKA.
# Finally, they must do whatever distro-specific bootstrapping is necessary.

# Note that we install targets before adding the user, since targets may affect
# /etc/skel or other default parts. The user is added in post-common, which is
# always added to targets.
