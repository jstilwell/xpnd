package OpenSSL::safe::installdata;

use strict;
use warnings;
use Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(
    @PREFIX
    @libdir
    @BINDIR @BINDIR_REL_PREFIX
    @LIBDIR @LIBDIR_REL_PREFIX
    @INCLUDEDIR @INCLUDEDIR_REL_PREFIX
    @APPLINKDIR @APPLINKDIR_REL_PREFIX
    @ENGINESDIR @ENGINESDIR_REL_LIBDIR
    @MODULESDIR @MODULESDIR_REL_LIBDIR
    @PKGCONFIGDIR @PKGCONFIGDIR_REL_LIBDIR
    @CMAKECONFIGDIR @CMAKECONFIGDIR_REL_LIBDIR
    $COMMENT $VERSION @LDLIBS
);

our $COMMENT                    = 'This file should be used when building against this OpenSSL build, and should never be installed';
our @PREFIX                     = ( '/Users/jesse/code/apps/xpnd/vendor/build/openssl-build-x86_64' );
our @libdir                     = ( '' );
our @BINDIR                     = ( '/Users/jesse/code/apps/xpnd/vendor/build/openssl-build-x86_64/apps' );
our @BINDIR_REL_PREFIX          = ( 'apps' );
our @LIBDIR                     = ( '/Users/jesse/code/apps/xpnd/vendor/build/openssl-build-x86_64' );
our @LIBDIR_REL_PREFIX          = ( '' );
our @INCLUDEDIR                 = ( '/Users/jesse/code/apps/xpnd/vendor/build/openssl-build-x86_64/include', '/Users/jesse/code/apps/xpnd/vendor/build/openssl-build-x86_64/../src/openssl-3.5.9/include' );
our @INCLUDEDIR_REL_PREFIX      = ( 'include', '../src/openssl-3.5.9/include' );
our @APPLINKDIR                 = ( '/Users/jesse/code/apps/xpnd/vendor/build/openssl-build-x86_64/ms' );
our @APPLINKDIR_REL_PREFIX      = ( 'ms' );
our @ENGINESDIR                 = ( '/Users/jesse/code/apps/xpnd/vendor/build/openssl-build-x86_64/engines' );
our @ENGINESDIR_REL_LIBDIR      = ( 'engines' );
our @MODULESDIR                 = ( '/Users/jesse/code/apps/xpnd/vendor/build/openssl-build-x86_64/providers' );
our @MODULESDIR_REL_LIBDIR      = ( 'providers' );
our @PKGCONFIGDIR               = ( '/Users/jesse/code/apps/xpnd/vendor/build/openssl-build-x86_64' );
our @PKGCONFIGDIR_REL_LIBDIR    = ( '.' );
our @CMAKECONFIGDIR             = ( '/Users/jesse/code/apps/xpnd/vendor/build/openssl-build-x86_64' );
our @CMAKECONFIGDIR_REL_LIBDIR  = ( '.' );
our $VERSION                    = '3.5.9';
our @LDLIBS                     =
    # Unix and Windows use space separation, VMS uses comma separation
    $^O eq 'VMS'
    ? split(/ *, */, ' ')
    : split(/ +/, ' ');

1;
