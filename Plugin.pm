package Plugins::22tracks::Plugin;

# Plugin to stream audio from 22tracks streams
#
# Released under GNU General Public License version 2 (GPLv2)
# Written by Daniel Vijge
# See file LICENSE for full license details

use strict;
use utf8;

use vars qw(@ISA);

use JSON::XS::VersionOneAndTwo;
use XML::Simple;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Log;

my $log;
my $compat;


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

    # A far easier approach is to just pass the OPML url as the feed. However,
    # once the 22tracks meny entry is opened it will have the title of the
    # OMPL (which is 'Playlist'). Not so nice, so have a toplevel menu that
    # parses the OPML feed
    $class->SUPER::initPlugin(
        feed   => \&toplevel, #Slim::Networking::SqueezeNetwork->url('/api/spotify/v1/opml/playlists?user=22tracks'),
        tag    => '22tracks',
        menu   => 'radios',
        is_app => $class->can('nonSNApps') ? 1 : undef,
        weight => 10
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
    
    my $menu = [];
    my $fetch;
    $fetch = sub {
        
        Slim::Networking::SqueezeNetwork->new(
            # Called when a response has been received for the request.
            sub {
                my $http = shift;
                my $json = eval { from_json($http->content) };
                my $xml = eval { XMLin($http->content) };

                if (defined $xml && lc($xml->{'head'}->{'title'}) =~ m/error/) {
                    _parseError($xml->{'body'}->{'outline'}, $menu);
                }
                else {
                    _parseSpotifyPlaylists($json->{'body'}->{'outline'}, $menu);
                }

                $callback->({
                    items  => $menu
                });
            },
            sub {
                $log->warn("error: $_[1]");
                $callback->([ { name => $_[1], type => 'text' } ]);
            }
        # Need to add additional header for authentication
        )->get(Slim::Networking::SqueezeNetwork->url('/api/spotify/v1/opml/playlists?user=22tracks'),
                                                     Slim::Networking::SqueezeNetwork->getHeaders($client)
                                                    );
    };
        
    $fetch->();
}

sub _parseSpotifyPlaylists {
     my ($json, $menu) = @_;

     for my $entry (@$json) {
        # Because every playlists starts with '22: ', remove this to clean it up a little
        
        my $text = $entry->{'text'};
        if (substr($entry->{'text'},0,4)=='22: ') {
            $text = substr($entry->{'text'},4);
        }
        # Remove [22tracks] at the end of the title
        if (index($text,' [22tracks]') != -1) {
            $text = substr($text,0,index($text,' [22tracks]'));
        }
        push @$menu, {
            name => $text  ,
            type => 'playlist',
            image => $entry->{'image'},
            url => $entry->{'URL'}
        }
    }
}

sub _parseError {
    my ($xml, $menu) = @_;

    push @$menu, {
            name => $xml->{'text'},
            type => 'text'
        }
}

# Always end with a 1 to make Perl happy
1;
