# Copyright 1999-2011 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

DESCRIPTION="Event Emulation for the uTouch Stack"
SRC_URI="http://launchpad.net/evemu/trunk/evemu-${PV}/+download/evemu-${PV}.tar.gz"
HOMEPAGE="https://launchpad.net/evemu"
KEYWORDS="~x86 ~amd64"
SLOT="0" 
LICENSE="GPL-3"
IUSE=""

src_compile() {
    econf
    emake || die
}

src_install() {
    emake DESTDIR="${D}" install || die

}
