package Plugins::22tracks::Settings;

# Plugin to stream audio from 22tracks streams
#
# Released under GNU General Public License version 2 (GPLv2)
# Written by Daniel Vijge
# See file LICENSE for full license details

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

# Returns the name of the plugin. The real 
# string is specified in the strings.txt file.
sub name {
	return 'PLUGIN_22TRACKS';
}

sub page {
    return 'plugins/22tracks/settings/basic.html';
}

sub prefs {
    return (preferences('plugin.22tracks'), qw(defaultCity));
}

# Always end with a 1 to make Perl happy
1;
