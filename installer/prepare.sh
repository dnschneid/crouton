#!/bin/sh -e
# Copyright (c) 2014 The crouton Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

ARCH='#ARCH#'
MIRROR='#MIRROR#'
MIRROR2='#MIRROR2#'
DISTRO='#DISTRO#'
RELEASE='#RELEASE#'
PROXY='#PROXY#'
VERSION='#VERSION#'
USERNAME='#USERNAME#'
SETOPTIONS='#SETOPTIONS#'

# Additional set options: -x or -v can be added for debugging (-e is always on)
if [ -n "$SETOPTIONS" ]; then
    set $SETOPTIONS
fi

# We need all paths to do administrative things
export PATH='/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin'

# Common functions
. "`dirname "$0"`/../installer/functions"

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
            error 2 "Nothing specified for $DISTRO~$RELEASE in '$descriptor'"
        fi
    done
}


# install [--minimal] [--asdeps] <packages> -- <avoid packages>
# For the specified crouton-style package names (see distropkgs()), installs
# <packages>, while avoiding installing <avoid packages> if they are not
# already installed.
# If --minimal is specified, avoids installing unnecessary packages.
# Unlike --minimal, <avoid packages> is useful for allowing "recommended"
# dependencies to be brought in while avoiding installing specific ones.
# Distros without "recommended" dependencies can ignore <avoid packages>.
# --asdeps installs the packages, but marks them as dependencies if they are not
# already installed. Running the distro-equivalent of 'autoremove' at the end
# of his script will uninstall such packages, as they are considered as orphans.
install() {
    install_dist `distropkgs "$@"`
}


# install_pkg: Installs the specified package file(s), ignoring dependency
# problems, and then attempts to resolve the dependencies. If called without
# parameters, simply fixes any dependency problems.
# If the first parameter is --minimal, avoids installing unnecessary packages.
# Distros that do not support external packages can implement this as an error.
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


# Requests a re-launch of the preparation script with a fresh chroot setup.
# Generally called immediately after bootstrapping to fix the environment.
relaunch_setup() {
    exit 0
}


# Fixes the tty keyboard mode. keyboard-configuration puts tty1~6 in UTF8 mode,
# assuming they are consoles. This isn't true for Chromium OS and crouton, and
# X11 sessions need to be in RAW mode. We do the smart thing and revert ttys
# with X sessions back to RAW.  keyboard-configuration could be reconfigured
# after bootstrap, dpkg --configure -a, or dist-upgrade.
fixkeyboardmode() {
    if hash kbd_mode 2>/dev/null; then
        for tty in `ps -CX -CXorg -otname=`; do
            # On some systems, the tty of Chromium OS returns ?
            if [ "$tty" = "?" ]; then
                tty='tty1'
            fi
            if [ -e "/dev/$tty" ]; then
                kbd_mode -s -C "/dev/$tty" 2>/dev/null || true
            fi
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
    local pkgs="gcc libc6-dev $*"
    install --minimal --asdeps $pkgs </dev/null
    echo "Compiling $out..." 1>&2
    local tmp="`mktemp crouton.XXXXXX --tmpdir=/tmp`"
    addtrap "rm -f '$tmp'"
    gcc -xc -Os - $linker -o "$tmp"
    /usr/bin/install -sDT "$tmp" "$out"
}


# Convert an automake Makefile.am into a shell script, and provide useful
# functions to compile libraries and executables.
# Needs to be run in the same directory as the Makefile.am file.
# This outputs the converted Makefile.am to stdout, which is meant to be
# piped to sh -s (see audio and xiat for examples)
convert_automake() {
    echo '
        top_srcdir=".."
        top_builddir=".."
    '
    sed -e '
        # Concatenate lines ending in \
        : start; /\\$/{N; b start}
        s/ *\\\n[ \t]*/ /g
        # Convert automake to shell
        s/^[^ ]*:/#\0/
        s/^\t/#\0/
        s/\t/ /g
        s/ *= */=/
        s/\([^ ]*\) *+= */\1=${\1}\ /
        s/ /\\ /g
        y/()/{}/
        s/if\\ \(.*\)/if [ -n "${\1}" ]; then/
        s/endif/fi/
    ' 'Makefile.am'
    echo '
        # buildsources: Build all source files for target
        #  $1: target
        #  $2: additional gcc flags
        # Prints a list of .o files
        buildsources() {
            local target="$1"
            local extragccflags="$2"

            eval local sources=\"\$${target}_SOURCES\"
            eval local cppflags=\"\$${target}_CPPFLAGS\"
            local cflags="$cppflags ${CFLAGS} ${AM_CFLAGS}"

            for dep in $sources; do
                if [ "${dep%.c}" != "$dep" ]; then
                    ofile="${dep%.c}.o"
                    gcc -c "$dep" -o "$ofile" '"$archgccflags"' \
                        $cflags $extragccflags 1>&2 || return $?
                    echo -n "$ofile "
                fi
            done
        }

        # fixlibadd:
        # Fix list of libraries ($1): replace lib<x>.la by -l<x>
        fixlibadd() {
            for libdep in $*; do
                if [ "${libdep%.la}" != "$libdep" ]; then
                    libdep="${libdep%.la}"
                    libdep="-l${libdep#lib}"
                fi
                echo -n "$libdep "
            done
        }

        # buildlib: Build a library
        #  $1: library name
        #  $2: additional linker flags
        buildlib() {
            local lib="$1"
            local extraflags="$2"
            local ofiles
            # local eats the return status: separate the 2 statements
            ofiles="`buildsources "${lib}_la" "-fPIC -DPIC"`"

            eval local libadd=\"\$${lib}_la_LIBADD\"
            eval local ldflags=\"\$${lib}_la_LDFLAGS\"

            libadd="`fixlibadd $libadd`"

            # Detect library version (e.g. 0.0.0)
            local fullver="`echo -n "$ldflags" | \
                      sed -n '\''y/:/./; \
                                 s/.*-version-info \([0-9.]*\)$/\\1/p'\''`"
            local shortver=""
            # Get "short" library version (e.g. 0)
            if [ -n "$fullver" ]; then
                shortver=".${fullver%%.*}"
                fullver=".$fullver"
            fi
            local fullso="$lib.so$fullver"
            local shortso="$lib.so$shortver"
            gcc -shared -fPIC -DPIC $ofiles $libadd -o "$fullso" \
                '"$archgccflags"' $extraflags -Wl,-soname,"$shortso"
            if [ -n "$fullver" ]; then
                ln -sf "$fullso" "$shortso"
                # Needed at link-time only
                ln -sf "$shortso" "$lib.so"
            fi
        }

        # buildexe: Build an executable file
        #  $1: executable file name
        #  $2: additional linker flags
        buildexe() {
            local exe="$1"
            local extraflags="$2"
            local ofiles="`buildsources "$exe" ""`"

            eval local ldadd=\"\$${exe}_LDADD\"
            eval local ldflags=\"\$${exe}_LDFLAGS\"

            ldadd="`fixlibadd $ldadd`"

            gcc $ofiles $ldadd -o "$exe" '"$archgccflags"' $extraflags
        }
    '
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
