package Plugins::22tracks::Settings;

# Plugin to stream audio from 22tracks streams
#
# Released under GNU General Public License version 2 (GPLv2)
# Written by Daniel Vijge
# See file LICENSE for full license details

use strict;
use base qw(Slim::Web::Settings);

use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $log   = logger('plugin.22tracks');
my $prefs = preferences('plugin.22tracks');
$prefs->init({ defaultCity => '0' });

use constant HTTP_TIMEOUT => 15;
use constant HTTP_CACHE => 1;
use constant HTTP_EXPIRES => '1h';

use constant BASE_URL => 'http://22tracks.com/';
use constant API_BASE_URL => BASE_URL . 'api/';

sub handler {
    my ($class, $client, $params, $callback, @args) = @_;

    $params->{'locations'} = {
        "0" => string('PLUGIN_22TRACKS_ALL_CITIES')
    };

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my ($http)  = @_;
            my $json  = eval { from_json($http->content) };

            for my $entry (@$json) {
                $params->{'locations'}->{$entry->{'id'}} = $entry->{'title'};
            }

            return $callback->($client, $params, $class->SUPER::handler($client, $params), @args);
        },
        sub {
            $log->warn('Could not retrieve list of cities');
            # Add current default city to list so it is not overwritten
            if ($prefs->{'prefs'}->{'defaultCity'} ne '0') {
                $params->{'locations'}->{$prefs->{'prefs'}->{'defaultCity'}} = string('PLUGIN_22TRACKS_DEFAULT_CITY');
            }
            return $callback->($client, $params, $class->SUPER::handler($client, $params), @args);
        },
        {
            timeout  => HTTP_TIMEOUT,
            cache    => HTTP_CACHE,
            expires  => HTTP_EXPIRES,
        },
    )->get( API_BASE_URL . 'cities' );

    return undef;
}

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
