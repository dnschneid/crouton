crouton: Chromium OS Ubuntu Chroot Environment
==============================================

crouton is a set of scripts based around debootstrap that bundle up into an
easy-to-use, Chromium OS-centric Ubuntu chroot generator.  It should work for
Debian as well (you can specify a different mirror and release), but "Chromium
OS Debian Chroot Environment" doesn't acronymize as well.


"crouton"...an acronym?
-----------------------
It stands for _ChRomium Os UbunTu chrOot enviroNment_  
...or something like that. Do capitals really matter if caps-lock has been
(mostly) banished, and the keycaps are all lower-case?

Moving on...


Who's this for?
---------------
Anyone who wants to run straight Linux on their Chromium OS device, and doesn't
care about physical security. You're also better off having some knowledge of
Linux tools and the command line in case things go funny, but it's not strictly
necessary.


What's a chroot?
----------------
Like virtualization, chroots provide the guest OS with their own, segregated
file system to run in, allowing applications to run in a different binary
environment from the host OS. Unlike virtualization, you are *not* booting a
second OS; instead, the guest OS is running using the Chromium OS system. The
benefit to this is that there is zero speed penalty since everything is run
natively, and you aren't wasting RAM to boot two OSes at the same time. The
downside is that you must be running the correct chroot for your hardware, the
software must be compatible with Chromium OS's kernel, and machine resources are
inextricably tied between the host Chromium OS and the guest OS. What this means
is that while the chroot cannot directly access files outside of its view, it
*can* access all of your hardware devices, including the entire contents of
memory. A root exploit in your guest OS will essentially have unfettered access
to the rest of Chromium OS.

...but hey, you can run TuxRacer!


Prerequisites
-------------
You need a device running Chromium OS that has been switched to developer mode.
Note that developer mode, in its default configuration, is *completely
insecure*, so don't expect a password in your chroot to keep anyone from your
data. crouton does support encrypting chroots, but the encryption is only as
strong as the quality of your passphrase. Consider this your warning.

That's it!  Surprised?


Usage
-----
There are three ways to acquire and run crouton. Two of which have cyclical
dependencies.

If you're just here to use crouton, you can grab the latest release from
[goo.gl/fd3zc](http://goo.gl/fd3zc).  Download it, pop open a shell
(Ctrl+Alt+T), and run `sh -e ~/Downloads/crouton` to see the help text. See the
"examples" section for some usage examples.

The other two involve cloning this repo and either running `installer/main.sh`
directly, or using `make` to build your very own `crouton`. Of course, you won't
have git on your Chromium OS device with which to do this, hence the cyclical
dependency. Downloading a git snapshot from GitHub would bypass that issue.

crouton uses the concept of "targets" to decide what to install.  While you will
have apt-get in your chroot, some targets may need minor hacks to avoid issues
when running in the chrooted environment.  As such, if you expect to want
something that is fulfilled by a target, install that target when you make the
chroot and you'll have an easier time.

Once you've set up your chroot, you can easily enter it using the
newly-installed `enter-chroot` command.  Ta-da!  That was easy.


Examples
--------

### The easy way (assuming you want Xfce)
  1. Download `crouton`.
  2. Open a shell (Ctrl+Alt+T) and run
     `sudo sh -e ~/Downloads/crouton -t xfce`
  3. Wait patiently and answer the prompts like a good person.
  4. Done! You can jump straight to your Xfce session by running
     `sudo enter-chroot startxfce4` or, as a special shortcut, `sudo startxfce4`
  5. On x86/amd64, switch between Chromium OS and your chroot using
     Ctrl+Alt+Back and Ctrl+Alt+Refresh. If you are on R25 or above, you may
     need to hit Ctrl+Alt+Forward before Ctrl+Alt+Refresh will work. On ARM
     platforms (or if you've explicitly selected the xephyr target on non-ARM),
     use Ctrl+Alt+Shift+Back and Ctrl+Alt+Shift+Forward to cycle through the
     chroots.
  6. Exit the chroot by logging out of Xfce.

### With encryption!
  1. Add the -e parameter when you run crouton to create an encrypted chroot.
  2. You can get some extra protection on your chroot by storing the decryption
     key separately from the place the chroot is stored. Use the -k parameter to
     specify a file or directory to store the keys in (such as a USB drive or SD
     card) when you create the chroot. Beware that if you lose this file, your
     chroot will not be decryptable.

### You want to make a bootstrap tarball and create a chroot from that
  1. Download `crouton`.
  2. Open a shell (Ctrl+Alt+T) and run
     `sudo sh -e ~/Downloads/crouton -d -f ~/Downloads/mybootstrap.tar.bz2`
  3. You can then create chroots using the tarball by running
     `sudo sh -e ~/Downloads/crouton -f ~/Downloads/mybootstrap.tar.bz2`

*This is the quickest way to create multiple chroots at once, since you won't
have to determine and download the bootstrap files every time.*

### A new version of crouton came out, and you want to update your chroot
  1. Download the new `crouton`.
  2. Open a shell (Ctrl+Alt+T) and run
     `sudo sh -e ~/Downloads/crouton -t xfce -u`
  3. You can use this with -e to encrypt a non-encrypted chroot, but make sure
     you don't interrupt the operation.

### You're crazy and want to play with all of the features of crouton
  1. Download the source snapshot tarball to your Chromium OS device.
  2. Extract it and cd into the source directory.
  3. Create a tarball of an old Ubuntu with perhaps the wrong architecture on a
     different mirror using the unbundled scripts:

        sh -e installer/main.sh -d -a i386 -r hardy \
           -m 'http://mirrors.us.kernel.org/ubuntu/' -f iamcrazy.tar.bz2

  4. Install the chroot with a custom name to an encrypted subdirectory in /tmp
     with the key stored on a removable disk, and install just cli-extra since
     you may be crazy but at least you recognize that /tmp is backed by RAM on
     Chromium OS and you'll quickly exhaust the available space if you install
     X11:

        sudo sh -e installer/main.sh -m 'http://mirrors.us.kernel.org/ubuntu/' \
                -f iamcrazy.tar.bz2 -p /tmp -n crazychrooty -t core,cli-extra \
                -e -k '/media/removable/External Drive/chrootkeys/'

  5. If that command actually worked, enter the chroot and login as root
     straight into vi because, well, you're crazy:
     
        sudo sh -e host-bin/enter-chroot -c /tmp/chroots -n crazychrooty \
                -u root vi

### Help! I've created a monster that must be slain!
  1. The delete-chroot command is your sword, shield, and only true friend.
     `sudo delete-chroot evilchroot`


Tips
----

  * Chroots are cheap! Create multiple ones using `-n`, break them, then make
    new, better ones!
  * A script is installed in your chroot called `brightness`. You can assign
    this to keyboard shortcuts to adjust the brightness of the screen (e.g.
    `brightness up`) or keyboard (e.g. `brightness k down`).
  * Multiple monitors will work fine in the chroot, but you may have to switch
    to Chromium OS and back to enable them.
  * You can make commands run in the background so that you can close the
    terminal. This is particularly useful for desktop environments: try running
    `sudo startxfce4 -b`
  * Want to disable Chromium OS's power management? Run `croutonpowerd -i`
  * If you just want a nice CLI environment for running Vim, servers, gcc,
    there's no need to install X11. Just use the `core` or `cli-extra` targets
    and use the chroot via `enter-chroot` from the crosh shell. You can enter
    the chroot simultaneously with as many crosh shells as you want.


Hey, I just met you, and this is crazy, but I'm getting a Pixel, so confirm support maybe?
------------------------------------------------------------------------------------------
`-t touch`.  'nuff said.


Issues?
-------
Running another OS in a chroot is a pretty messy technique (although it's hidden
behind very pretty scripts), and these scripts are pretty new, so problems are
not surprising. Check the issue tracker and file a bug if your issue isn't
there.


I prefer Arch/Gentoo/Haiku/whatever
-----------------------------------
Great! Make your own scripts. Call it "chroagh!!"


License
-------
crouton (including this eloquently-written README) is copyright &copy; 2013 The
Chromium OS Authors. All rights reserved. Use of the source code included here
is governed by a BSD-style license that can be found in the LICENCE file in the
source tree.
