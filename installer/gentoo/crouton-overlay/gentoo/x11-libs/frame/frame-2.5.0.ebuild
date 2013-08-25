# Copyright 1999-2011 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

inherit base

DESCRIPTION="Touch Frame Library "
SRC_URI="http://launchpad.net/frame/trunk/v${PV}/+download/frame-${PV}.tar.gz"
HOMEPAGE="https://launchpad.net/frame"
KEYWORDS="~x86 ~amd64"
SLOT="0"
LICENSE="GPV-3"
IUSE=""

RDEPEND=""
DEPEND="${RDEPEND}
    x11-libs/evemu"
