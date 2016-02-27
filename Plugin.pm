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

use Plugins::22tracks::ProtocolHandler;

# Defines the timeout in seconds for a http request
use constant HTTP_TIMEOUT => 15;
use constant HTTP_CACHE => 1;
use constant HTTP_EXPIRES => '1h';

use constant BASE_URL => 'http://22tracks.com/';
use constant API_BASE_URL => BASE_URL . 'api/';

my $log;
my $compat;

# Get the data related to this plugin and preset certain variables with 
# default values in case they are not set
my $prefs = preferences('plugin.22tracks');
$prefs->init({ defaultCity => '0', scrobble => '1' });

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
    # menu entry '22tracks'. 
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
        match => qr/22tracks:/,
        func => \&remoteMetadataProvider,
    );

    Slim::Player::ProtocolHandlers->registerHandler(
        '22tracks' => 'Plugins::22tracks::ProtocolHandler'
    );

    Slim::Menu::TrackInfo->registerInfoProvider( '22tracksbio' => (
        func  => \&trackInfoMenuBio,
    ) );

    Slim::Menu::TrackInfo->registerInfoProvider( '22tracksplaylistinfo' => (
        func  => \&trackInfoMenuPlaylist,
    ) );

    Slim::Control::Request::addDispatch(['22tracks', 'bio'], 
        [1, 1, 1, \&cliInfoQuery]);
    Slim::Control::Request::addDispatch(['22tracks', 'playlistinfo'], 
        [1, 1, 1, \&cliInfoQuery]);
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
    my $playlist = exists $passDict->{'playlist'} ? $passDict->{'playlist'} : '';

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
                    _parseTracks($json, $menu, $playlist);
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
            {
                timeout       => HTTP_TIMEOUT,
                cache         => HTTP_CACHE,
                expires       => HTTP_EXPIRES,
            }
            
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
            passthrough => [ { resource => 'tracks', id => $json->{'id'}, playlist=> $json } ]
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
    my ($json, $menu, $playlist) = @_;

    for my $entry (@$json) {
        push @$menu, _makeMetadata($entry, $playlist);
    }
}

sub _makeMetadata {
    my ($json, $playlist) = @_;

    my $icon = getIcon($playlist);

    my $soundcloud = '';
    my $download = '';

    my $shoplinks = $json->{'shoplinks'};
    for my $shoplink (@$shoplinks) {
        if ($shoplink->{'title'} =~ qr/download/i) {
            $download = $shoplink->{'shop_url'};
        }
        elsif ($shoplink->{'title'} =~ qr/soundcloud/i) {
            $soundcloud = $shoplink->{'shop_url'};
        }
    }

    my $DATA = {
        duration => int($json->{'duration'}),
        name => $json->{'title'},
        title => $json->{'title'},
        artist => $json->{'artist'},
        album => $json->{'original_genre'}->{'title'},
        play => "22tracks:track:" . $json->{'id'},
        bitrate => '128kbps VBR',
        type => 'MP3 (22tracks)',
        on_select => 'play',
        icon => $icon,
        image => $icon,
        cover => $icon,
        bio => $json->{'bio'},
        biolinks => {'homepage' => $json->{'site_url'},
                        'facebook' => $json->{'facebook'},
                        'twitter' => $json->{'twitter'},
                        'soundcloud' => $soundcloud,
                        'download' => $download },
        playlistinfo => $playlist->{'description_html'},
        playlistlinks => {'homepage' => $playlist->{'site_url'},
                        'facebook' => $playlist->{'facebook_url'},
                        'twitter' => $playlist->{'twitter'} }

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

sub remoteMetadataProvider {
    my ( $client, $url ) = @_;

    return unless $url =~ m{^22tracks:};

    my ($id) = $url =~ m{^22tracks:track:(.+)$};
    
    my $cache = Slim::Utils::Cache->new;
    my $meta = $cache->get( '22tracks_meta_' . $id );

    return $meta if $meta;
    
    my $trackURL = API_BASE_URL . 'track/' . $id;
    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $json = eval { from_json($http->content) };
            
            my $meta = _makeMetadata($json->{'track'}, $json->{'genre'});
            my $cache = Slim::Utils::Cache->new;
            
            $cache->set( '22tracks_meta_' . $json->{'track'}->{'id'}, $meta, 86400 );

            $http->params->{callback}->();
        },
        sub {
            $log->warn('Could net get tracks information for remote track');
        },
        {
            timeout       => HTTP_TIMEOUT,
            cache         => HTTP_CACHE,
            expires       => HTTP_EXPIRES,
        },
    )->get( $trackURL );

    return { type => 'MP3 (22tracks)' };
}

sub trackInfoMenuBio {
    my ($client, $url, $track, $meta) = @_;
    
    return unless $client;
    return unless $url =~ m{^22tracks:};

    my @menu;
    my $item;

    if ($meta->{'bio'}) {
        push @menu, {
                name        => controllerCapabilities($client)==2 ? $meta->{'bio'} : strip_tags($meta->{'bio'}),
                type        => 'textarea',
                favorites   => 0,
        };
    }

    if ($meta->{'biolinks'}->{'homepage'} && controllerCapabilities($client)==2) {
        push @menu, {
                name        => string('PLUGIN_22TRACKS_LINK_HOMEPAGE'),
                type        => 'text',
                favorites   => 0,
                weblink     => $meta->{'biolinks'}->{'homepage'},
        };
    }

    if ($meta->{'biolinks'}->{'facebook'} && controllerCapabilities($client)==2) {
        push @menu, {
                name        => string('PLUGIN_22TRACKS_LINK_FACEBOOK'),
                type        => 'text',
                favorites   => 0,
                weblink     => $meta->{'biolinks'}->{'facebook'},
        };
    }

    if ($meta->{'biolinks'}->{'twitter'} && controllerCapabilities($client)==2) {
        push @menu, {
                name        => string('PLUGIN_22TRACKS_LINK_TWITTER'),
                type        => 'text',
                favorites   => 0,
                weblink     => 'https://www.twitter.com/' . $meta->{'biolinks'}->{'twitter'},
        };
    }

    if ($meta->{'biolinks'}->{'soundcloud'} && controllerCapabilities($client)==2) {
        push @menu, {
                name        => string('PLUGIN_22TRACKS_LINK_SOUNDCLOUD'),
                type        => 'text',
                favorites   => 0,
                weblink     => $meta->{'biolinks'}->{'soundcloud'},
        };
    }

    if ($meta->{'biolinks'}->{'download'} && controllerCapabilities($client)==2) {
        push @menu, {
                name        => string('PLUGIN_22TRACKS_LINK_DOWNLOAD'),
                type        => 'text',
                favorites   => 0,
                weblink     => $meta->{'biolinks'}->{'download'},
        };
    }

    if (controllerCapabilities($client)==1) {
        push @menu, {
                name        => string('PLUGIN_22TRACKS_LINK'),
                type        => 'text',
                favorites   => 0,
                jive => {
                    actions => {
                        go => {
                            cmd => [ '22tracks', 'bio' ],
                            params => {
                                '22tracks_homepage' => $meta->{'biolinks'}->{'homepage'},
                                '22tracks_facebook' => $meta->{'biolinks'}->{'facebook'},
                                '22tracks_twitter' => $meta->{'biolinks'}->{'twitter'},
                                '22tracks_soundcloud' => $meta->{'biolinks'}->{'soundcloud'},
                                '22tracks_download' => $meta->{'biolinks'}->{'download'}
                            },
                        },
                    },
                },
        };
    }
    
    if (scalar @menu) {
        $item = {
            name  => string('PLUGIN_22TRACKS_BIO'),
            items => \@menu,
        };
    }

    return $item;
}

sub trackInfoMenuPlaylist {
    my ($client, $url, $track, $meta) = @_;
    
    return unless $client;
    return unless $url =~ m{^22tracks:};

    my @menu;
    my $item;

    if ($meta->{'playlistinfo'}) {
        push @menu, {
                name        => controllerCapabilities($client)==2 ? $meta->{'playlistinfo'} : strip_tags($meta->{'playlistinfo'}),
                type        => 'textarea',
                favorites   => 0,
        };
    }

    if ($meta->{'playlistlinks'}->{'homepage'} && controllerCapabilities($client)==2) {
        push @menu, {
                name        => string('PLUGIN_22TRACKS_LINK_HOMEPAGE'),
                type        => 'text',
                favorites   => 0,
                weblink     => $meta->{'playlistlinks'}->{'homepage'},
        };
    }

    if ($meta->{'playlistlinks'}->{'facebook'} && controllerCapabilities($client)==2) {
        push @menu, {
                name        => string('PLUGIN_22TRACKS_LINK_FACEBOOK'),
                type        => 'text',
                favorites   => 0,
                weblink     => $meta->{'playlistlinks'}->{'facebook'},
        };
    }

    if ($meta->{'playlistlinks'}->{'twitter'} && controllerCapabilities($client)==2) {
        push @menu, {
                name        => string('PLUGIN_22TRACKS_LINK_TWITTER'),
                type        => 'text',
                favorites   => 0,
                weblink     => 'https://www.twitter.com/' . $meta->{'playlistlinks'}->{'twitter'},
        };
    }

    if (controllerCapabilities($client)==1) {
        push @menu, {
                name        => string('PLUGIN_22TRACKS_LINK'),
                type        => 'text',
                favorites   => 0,
                jive => {
                    actions => {
                        go => {
                            cmd => [ '22tracks', 'playlistinfo' ],
                            params => {
                                '22tracks_homepage' => $meta->{'playlistlinks'}->{'homepage'},
                                '22tracks_facebook' => $meta->{'playlistlinks'}->{'facebook'},
                                '22tracks_twitter' => $meta->{'playlistlinks'}->{'twitter'}
                            },
                        },
                    },
                },
        };
    }
    
    if (scalar @menu) {
        $item = {
            name  => string('PLUGIN_22TRACKS_PLAYLIST_INFO'),
            items => \@menu,
        };
    }

    return $item;
}

sub strip_tags {
    my $html = shift;

    $html =~ s/<(?:[^>'"]*|(['"]).*?\1)*>//gs;
    return $html;
}

# return controller capabilities for displaying HTML and/or weblinks
# 2: controller can display HTML and weblinks
# 1: controller can display weblinks, not HTML
# 0: controller cannot display HTML or weblinks
sub controllerCapabilities {
    my $client = shift;

    if (!defined $client->controllerUA) {
        return 2;
    }
    elsif ($client->controllerUA =~ qr/iPeng/i) {
        return 1;
    }
    else {
        return 0;
    }
}

# special query to allow weblink to be sent to iPeng
sub cliInfoQuery {
    my $request = shift;

    if ($request->isNotQuery([['22tracks'], ['bio', 'playlistinfo']])) {
        $request->setStatusBadDispatch();
        return;
    }

    my $homepage = $request->getParam('22tracks_homepage');
    my $facebook = $request->getParam('22tracks_facebook');
    my $twitter = $request->getParam('22tracks_twitter');
    my $soundcloud = $request->getParam('22tracks_soundcloud');
    my $download = $request->getParam('22tracks_download');
    my $i = 0;

    if ($homepage) {
        $request->addResultLoop('item_loop', $i, 'text', string('PLUGIN_22TRACKS_LINK_HOMEPAGE'));
        $request->addResultLoop('item_loop', $i, 'weblink', $homepage);
        $i++;
    }
    if ($facebook) {
        $request->addResultLoop('item_loop', $i, 'text', string('PLUGIN_22TRACKS_LINK_FACEBOOK'));
        $request->addResultLoop('item_loop', $i, 'weblink', $facebook);
        $i++;
    }
    if ($twitter) {
        $request->addResultLoop('item_loop', $i, 'text', string('PLUGIN_22TRACKS_LINK_TWITTER'));
        $request->addResultLoop('item_loop', $i, 'weblink', 'https://www.twitter.com/' . $twitter);
        $i++;
    }
    if ($soundcloud) {
        $request->addResultLoop('item_loop', $i, 'text', string('PLUGIN_22TRACKS_LINK_SOUNDCLOUD'));
        $request->addResultLoop('item_loop', $i, 'weblink', $soundcloud);
        $i++;
    }
    if ($download) {
        $request->addResultLoop('item_loop', $i, 'text', string('PLUGIN_22TRACKS_LINK_DOWNLOAD'));
        $request->addResultLoop('item_loop', $i, 'weblink', $download);
        $i++;
    }
    
    $request->addResult('count', $i);
    $request->addResult('offset', 0);

    $request->setStatusDone();
}

# Always end with a 1 to make Perl happy
1;
