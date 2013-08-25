# Copyright 1999-2010 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

EAPI="4"

inherit eutils

DESCRIPTION="A tool that prints the user's idle time to stdout"
HOMEPAGE="http://www.dtek.chalmers.se/~henoch/text/xprintidle.html"
SRC_URI="http://dev.gentoo.org/~radhermit/distfiles/${P}.tar.gz"

LICENSE="GPL-2"
SLOT="0"
KEYWORDS="~amd64 ~x86"
IUSE=""

RDEPEND="x11-libs/libX11
	x11-libs/libXext
	x11-libs/libXScrnSaver"
DEPEND="${RDEPEND}"

src_prepare() {
	epatch "${FILESDIR}"/${P}-dpms.patch
	epatch "${FILESDIR}/make.patch"
}
