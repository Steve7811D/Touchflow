#!/usr/bin/perl
# TouchFlow's now-playing reader.
#
# macOS only exposes "what is playing" to processes the system trusts; a plain
# self-signed helper gets an empty answer, while a system interpreter is
# allowed to ask.  So the app runs this little glue script with /usr/bin/perl,
# and the script loads the BSD-licensed MediaRemoteMini adapter and lets it
# print the JSON payload on stdout.
#
# Usage: read-nowplaying.pl /path/to/MediaRemoteMini.dylib
use strict;
use warnings;
use DynaLoader;

my $library = shift @ARGV
    or die "usage: read-nowplaying.pl <MediaRemoteMini.dylib>\n";

my $handle = DynaLoader::dl_load_file($library, 0)
    or die "cannot load $library: " . DynaLoader::dl_error() . "\n";
my $symbol = DynaLoader::dl_find_symbol($handle, "adapter_get")
    or die "adapter_get not found in $library\n";

my $call = DynaLoader::dl_install_xsub("main::tf_adapter_get", $symbol);
&$call();
