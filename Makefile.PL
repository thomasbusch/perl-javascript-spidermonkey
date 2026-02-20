######################################################################
#
# MakeMaker file for JavaScript::SpiderMonkey
#
# Authors: Mike Schilli  m@perlmeister.com, 2002-2005
#          Thomas Busch  tbusch@cpan.org, 2006-2026
#
######################################################################

use ExtUtils::MakeMaker;
use ExtUtils::PkgConfig;

my @mozjs_candidates = qw(
    mozjs-140 mozjs-128 mozjs-115 mozjs-102
    mozjs-91  mozjs-78  mozjs-68  mozjs-60  mozjs-52
);

my %mozjs;
for my $pkg (@mozjs_candidates) {
    if (ExtUtils::PkgConfig->exists($pkg)) {
        %mozjs = ExtUtils::PkgConfig->find($pkg);
        last;
    }
}
if (!%mozjs) {
    print <<EOT;

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
This module requires a SpiderMonkey (mozjs) library, version 52+.
Tried: @mozjs_candidates

Install the mozjs-devel package for your distribution, e.g.:
  Rocky/RedHat 9:  dnf install mozjs78 mozjs78-devel
  Rocky/RedHat 8:  dnf install mozjs60 mozjs60-devel
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

EOT
    exit 0;
}

my $JS_CFLAGS = $mozjs{cflags};
my $JS_LIBS   = $mozjs{libs};
print "Found mozjs $mozjs{modversion}:\n";
print "  CFLAGS: $JS_CFLAGS\n";
print "  LIBS:   $JS_LIBS\n";

my ($major) = $mozjs{modversion} =~ /^(\d+)/;
my $cxx_std  = ($major >= 78) ? '-std=c++17' : '-std=c++14';

my $JS_DEFINE = ($^O ne 'MSWin32') ? '-DXP_UNIX' : '-DXP_WIN';
$JS_DEFINE .= " -DMOZJS_MAJOR_VERSION=$major";

WriteMakefile(
    'NAME'          => 'JavaScript::SpiderMonkey',
    'VERSION_FROM'  => 'SpiderMonkey.pm',
    'LICENSE'       => 'perl_5',
    'PREREQ_PM'    => {},
    'CONFIGURE_REQUIRES' => {
        'ExtUtils::PkgConfig' => 0,
    },
    ($] >= 5.005 ?
      (ABSTRACT_FROM => 'SpiderMonkey.pm',
       AUTHOR     => 'Mike Schilli <m@perlmeister.com>') : ()),
    'CC'            => 'g++',
    'LD'            => 'g++',
    'XSOPT'        => '-C++',
    'CCFLAGS'       => "$cxx_std $JS_DEFINE $JS_CFLAGS",
    'LIBS'          => [$JS_LIBS],
    'DEFINE'        => '',
    'INC'           => '',

    (eval { ExtUtils::MakeMaker->VERSION(6.46) } ?
      (
        META_MERGE => {
          "meta-spec" => { version => 2 },
          resources => {
            repository => {
              type => 'git',
              url => 'git://github.com/thomasbusch/perl-javascript-spidermonkey.git',
              web => 'https://github.com/thomasbusch/perl-javascript-spidermonkey',
            },
          },
        }
      ) : ()
    ),
);

######################################################################
sub MY::postamble {
######################################################################
    '
README: SpiderMonkey.pm
	pod2text SpiderMonkey.pm >README
    ';
}
