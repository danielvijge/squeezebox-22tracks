package Plugins::22tracks::Plugin;

# Plugin to stream audio from 22tracks streams
#
# Released under GNU General Public License version 2 (GPLv2)
# Written by Daniel Vijge
# See file LICENSE for full license details

use strict;
use utf8;

use vars qw(@ISA);

use URI::Escape;
use JSON::XS::VersionOneAndTwo;
use LWP::Simple;
use LWP::UserAgent;
use File::Spec::Functions qw(:ALL);
use List::Util qw(min max);

use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Cache;

use Data::Dumper;
use Plugins::22tracks::ProtocolHandler;

# Defines the timeout in seconds for a http request
use constant HTTP_TIMEOUT => 15;

use constant API_BASE_URL => 'http://22tracks.com/api/';
use constant BASE_URL => 'http://22tracks.com/';

my $log;
my $compat;

# Get the data related to this plugin and preset certain variables with 
# default values in case they are not set
my $prefs = preferences('plugin.22tracks');
$prefs->init({ defaultCity => '0' });

# This is the entry point in the script
BEGIN {
    # Initialize the logging
    $log = Slim::Utils::Log->addLogCategory({
        'category'     => 'plugin.22tracks',
        'defaultLevel' => 'WARN',
        'description'  => string('PLUGIN_22TRACKS'),
    });

    # Always use OneBrowser version of XMLBrowser by using server or packaged 
    # version included with plugin
    if (exists &Slim::Control::XMLBrowser::findAction) {
        $log->info("using server XMLBrowser");
        require Slim::Plugin::OPMLBased;
        push @ISA, 'Slim::Plugin::OPMLBased';
    } else {
        $log->info("using packaged XMLBrowser: Slim76Compat");
        require Slim76Compat::Plugin::OPMLBased;
        push @ISA, 'Slim76Compat::Plugin::OPMLBased';
        $compat = 1;
    }
}

# This is called when squeezebox server loads the plugin.
# It is used to initialize variables and the like.
sub initPlugin {
    my $class = shift;

    # Initialize the plugin with the given values. The 'feed' is the first
    # method called. The available menu entries will be shown in the new 
    # menu entry 'soundclound'. 
    $class->SUPER::initPlugin(
        feed   => \&toplevel,
        tag    => '22tracks',
        menu   => 'radios',
        is_app => $class->can('nonSNApps') ? 1 : undef,
        weight => 10,
    );

    if (!$::noweb) {
        require Plugins::22tracks::Settings;
        Plugins::22tracks::Settings->new;
    }

    Slim::Formats::RemoteMetadata->registerProvider(
        match => qr/22tracks\.com/,
        func => \&metadata_provider,
    );

    Slim::Player::ProtocolHandlers->registerHandler(
        tracks22 => 'Plugins::22tracks::ProtocolHandler'
    );
}

# Called when the plugin is stopped
sub shutdownPlugin {
    my $class = shift;
}

# Returns the name to display on the squeezebox
sub getDisplayName { 'PLUGIN_22TRACKS' }


sub playerMenu { shift->can('nonSNApps') ? undef : 'RADIO' }

sub toplevel {
    my ($client, $callback, $args) = @_;

    if ($prefs->get('defaultCity') ne "0") {
        _feedHandler($client, $callback, $args, {resource => 'genres', id => $prefs->get('defaultCity'), allcities => '1'} );
    }
    else {
        _feedHandler($client, $callback, $args, {resource => 'cities'} );
    }
}

sub _feedHandler {
    my ($client, $callback, $args, $passDict) = @_;

    my $resource = $passDict->{'resource'};
    my $id = exists $passDict->{'id'} ? $passDict->{'id'} : '';
    my $hide = exists $passDict->{'hide'} ? $passDict->{'hide'} : "-1";
    my $allcities = exists $passDict->{'allcities'} ? $passDict->{'allcities'} : "0";
    my $icon = exists $passDict->{'icon'} ? $passDict->{'icon'} : '';

    my $queryUrl = API_BASE_URL;

    $queryUrl .= $resource;
    if ($id ne '') {
        $queryUrl .= '/' . $id;
    }

    my $menu = [];
    my $fetch;
    $fetch = sub {

        $log->debug("Fetching $queryUrl");
        
        Slim::Networking::SimpleAsyncHTTP->new(
            # Called when a response has been received for the request.
            sub {
                my $http = shift;
                my $json = eval { from_json($http->content) };

                if ($resource eq 'cities') {
                    _parseCities($json, $menu, $hide, $allcities);
                }
                elsif ($resource eq 'genres') {
                    _parseGenres($json, $menu, $allcities);
                }
                elsif ($resource eq 'tracks') {
                    _parseTracks($json, $menu, $icon);
                }

                $callback->({
                    items  => $menu
                });

            },
            # Called when no response was received or an error occurred.
            sub {
                $log->warn("error: $_[1]");
                $callback->([ { name => $_[1], type => 'text' } ]);
            },
            
        )->get($queryUrl);
    };
        
    $fetch->();
}

sub _parseCities {
    my ($json, $menu, $hide, $allcities) = @_;
    
    for my $entry (@$json) {
        if ($entry->{'id'} ne $hide) {
            push @$menu, _parseCity($entry, $allcities);
        }
    }
}

sub _parseCity {
    my ($json, $allcities) = @_;

    return {
        name => $json->{'title'},
        type => 'link',
        url => \&_feedHandler,
        passthrough => [ { resource => 'genres', id => $json->{'id'}, allcities => $allcities} ]
    };
}

sub _parseGenres {
    my ($json, $menu, $allcities) = @_;

    for my $entry (@$json) {
        push @$menu, _parseGenre($entry);
    }

    if ($prefs->get('defaultCity') ne '0' && $allcities ne '0') {
        push @$menu, {
            name => string('PLUGIN_22TRACKS_ALL_CITIES'),
            type => 'link',
            icon => 'plugins/22tracks/icon.png',
            url => \&_feedHandler,
            passthrough => [ { resource => 'cities', hide => $prefs->get('defaultCity'), allcities => '0' } ]
        }
    }
}

sub _parseGenre {
    my ($json) = @_;

    my $icon = getIcon($json);

    if ($icon ne '') {
        return {
            name => $json->{'title'},
            icon => $icon,
            image => $icon,
            type => 'playlist',
            url => \&_feedHandler,
            passthrough => [ { resource => 'tracks', id => $json->{'id'}, icon => $icon } ]
        };
    }
    else {
        return;
    }
}

sub getIcon {
    my ($json) = shift;

    my $picture = '';

    if (exists $json->{'picture'} && $json->{'picture'}) {
        $picture = BASE_URL . $json->{'picture'};
    }
    elsif (exists $json->{'picture_web'} && $json->{'picture_web'}) {
        $picture = BASE_URL . $json->{'picture_web'};
    }
    elsif (exists $json->{'picture_app'} && $json->{'picture_app'}) {
        $picture = BASE_URL . $json->{'picture_app'};
    }

    return $picture;
}

sub _parseTracks {
    my ($json, $menu, $icon) = @_;

    for my $entry (@$json) {
        push @$menu, _makeMetadata($entry, $icon);
    }
}

sub _makeMetadata {
    my ($json, $icon) = @_;
    
    my $DATA = {
        duration => int($json->{'duration'}),
        name => $json->{'title'},
        title => $json->{'title'},
        artist => $json->{'artist'},
        album => $json->{'original_genre'}->{'title'},
        play => "tracks22://" . $json->{'id'},
        bitrate => '128k',
        type => 'MP3 (22tracks)',
        on_select => 'play',
        icon => $icon,
        image => $icon,
        cover => $icon
    };

    # Already set meta cache here, so that playlist does not have to
    # query each track individually
    my $cache = Slim::Utils::Cache->new;
    $log->debug("setting ". '22tracks_meta_' . $json->{'id'});
    $cache->set( '22tracks_meta_' . $json->{'id'}, $DATA, 86400 );

    return $DATA;
}

# Returns the default metadata for the track which is specified by the URL.
# In this case only the track title that will be returned.
sub defaultMeta {
    my ( $client, $url ) = @_;

    return {
        title => Slim::Music::Info::getCurrentTitle($url)
    };
}

# Always end with a 1 to make Perl happy
1;
