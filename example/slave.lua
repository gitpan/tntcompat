local console = require 'console'

box.cfg {
    work_dir            = 'example/slave/work',
    snap_dir            = '.',
    wal_dir             = '.',
    replication_source  = 'tcp://root:password@127.0.0.1:4587',

    listen              = 3013,

    slab_alloc_arena    = 2.5
}


console.listen('/tmp/admin.socket')
