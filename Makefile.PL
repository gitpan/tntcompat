use 5.010000;
use ExtUtils::MakeMaker;
WriteMakefile(
    NAME              => 'tntcompat',
    VERSION_FROM      => 'tntcompat',
    PREREQ_PM         => {
        'AnyEvent::Socket'  => 0,
        'List::MoreUtils'   => 0,
        'Carp'              => 0,
        'Coro'              => 0,
        'Coro::AnyEvent'    => 0,
        'Coro::Handle'      => 0,
        'Data::Dumper'      => 0,
        'Digest::SHA'       => 0,
        'Encode'            => 0,
        'Errno'             => 0,
        'JSON::XS'          => 0,
        'MIME::Base64'      => 0,
        'Scalar::Util'      => 0,
        'Time::HiRes'       => 0,
        'UUID'              => 0,
    },
    META_MERGE => {
        resources => {
            homepage   => 'https://github.com/tarantool/compat-flow',
            repository => 'https://github.com/tarantool/compat-flow',
            bugtracker => 'https://github.com/tarantool/compat-flow/issues',
        }
    },
    ABSTRACT_FROM  => 'tntcompat',
    AUTHOR         => 'Dmitry E. Oboukhov <unera@debian.org>',
    LICENSE           => 'artistic',
    EXE_FILES       => [ 'tntcompat' ]
);

