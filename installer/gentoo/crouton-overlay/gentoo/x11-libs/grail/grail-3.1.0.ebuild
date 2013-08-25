# Copyright 1999-2011 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

inherit base

DESCRIPTION="Gesture Recognition And Instantiation Library"
SRC_URI="http://launchpad.net/grail/trunk/${PV}/+download/grail-${PV}.tar.gz"
HOMEPAGE="https://launchpad.net/grail"
KEYWORDS="~x86 ~amd64"
SLOT="0"
LICENSE="GPV-3"
IUSE=""

RDEPEND=""
DEPEND="${RDEPEND}
	sys-libs/mtdev
	x11-libs/evemu
	x11-libs/frame
	"

