package Plugins::22tracks::ProtocolHandler;

# Plugin to stream audio from 22track streams
#
# Released under GNU General Public License version 2 (GPLv2)
# Written by Daniel Vijge
# See file LICENSE for full license details

#use strict;

use base qw(Slim::Player::Protocols::HTTP);

use List::Util qw(min max);
use LWP::Simple;
use LWP::UserAgent;
use HTML::Parser;
use URI::Escape;
use JSON::XS::VersionOneAndTwo;
use XML::Simple;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;
use Scalar::Util qw(blessed);

# Defines the timeout in seconds for a http request
use constant HTTP_TIMEOUT => 15;
use constant API_BASE_URL => 'http://22tracks.com/api/';
use constant BASE_URL => 'http://22tracks.com/';
use constant TOKEN_URL => 'http://app01.22tracks.com/token.php?desktop=true&u=/128/%s';
use constant AUDIO_URL => 'http://audio.22tracks.com%s?st=%s&e=%s';

my $log   = logger('plugin.22tracks');

use Data::Dumper;

Slim::Player::ProtocolHandlers->registerHandler('tracks22', __PACKAGE__);

sub canSeek { 1 }

sub _makeMetadata {
    my ($json, $realURL) = @_;

    $icon = getIcon($json);
    
    my $DATA = {
        duration => int($json->{'track'}->{'duration'}),
        name => $json->{'track'}->{'title'},
        title => $json->{'track'}->{'title'},
        artist => $json->{'track'}->{'artist'},
        album => $json->{'track'}->{'original_genre'}->{'title'},
        link => $realURL,
        play => "tracks22://" . $json->{'id'},
        bitrate => '128k',
        type => 'mp3 (22tracks)',
        icon => $icon,
        image => $icon,
        cover => $icon,
        bio => $json->{'track'}->{'bio'},
        playlist_info => $json->{'genre'}->{'description_html'}
    };
}

sub getIcon {
    my ($json) = shift;

    my $picture = '';

    if (exists $json->{'genre'}->{'picture'} && $json->{'genre'}->{'picture'}) {
        $picture = BASE_URL . $json->{'genre'}->{'picture'};
    }
    elsif (exists $json->{'genre'}->{'picture_web'} && $json->{'genre'}->{'picture_web'}) {
        $picture = BASE_URL . $json->{'genre'}->{'picture_web'};
    }
    elsif (exists $json->{'genre'}->{'picture_app'} && $json->{'genre'}->{'picture_app'}) {
        $picture = BASE_URL . $json->{'genre'}->{'picture_app'};
    }

    return $picture;
}

sub getFormatForURL () { 'mp3' }

sub isRemote { 1 }

sub scanUrl {
    my ($class, $url, $args) = @_;
    
    $args->{cb}->( $args->{song}->currentTrack() );
}

sub gotNextTrack {
    my $http  = shift;

    my $client = $http->params->{client};
    my $song   = $http->params->{song};     
    #my $url    = $url ? $url : $song->currentTrack()->url;
    my $json  = eval { from_json($http->content) };

    my $tokenURL = sprintf(TOKEN_URL, $json->{'track'}->{'filename'});
    $log->debug("Token URL $tokenURL");

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http2  = shift;
            my $json2  = eval { from_json($http2->content) };

            my $trackURL = sprintf(AUDIO_URL, $json2->{'filename'}, $json2->{'st'}, $json2->{'e'});

            $log->debug("Stream URL $trackURL");

            my $meta = _makeMetadata($json, $trackURL);
            $song->duration( $meta->{duration} );
            $song->streamUrl( $trackURL );

            my $cache = Slim::Utils::Cache->new;
            $log->debug("setting ". '22tracks_meta_' . $json->{'track'}->{'id'});
            $cache->set( '22tracks_meta_' . $json->{'track'}->{'id'}, $meta, 86400 );

            $http->params->{callback}->();
        },
        sub {
            $log->warn("There was en error getting remote URL");
        },
        {
            song          => $song,
            timeout       => HTTP_TIMEOUT,
        },
    )->get( $tokenURL );
}

sub gotNextTrackError {
    my $http = shift;
    
    $log->warn("Error " . $http->error);
    #$http->params->{errorCallback}->( 'PLUGIN_22TRACKS_ERROR', $http->error );
}

sub getNextTrack {
    my ($class, $song, $successCb, $errorCb) = @_;
    
    my $client = $song->master();
    my $url    = $song->currentTrack()->url;
        
    # Get next track
    my ($id) = $url =~ m{^tracks22://(.*)$};
        
    my $trackURL = API_BASE_URL . 'track/' . $id;
    $log->debug("Track URL $trackURL");
        
    Slim::Networking::SimpleAsyncHTTP->new(
        \&gotNextTrack,
        \&gotNextTrackError,
        {
            client        => $client,
            song          => $song,
            callback      => $successCb,
            errorCallback => $errorCb,
            timeout       => HTTP_TIMEOUT,
        },
    )->get( $trackURL );
}

sub getNextTrackError {
    my $http = shift;
    
    $http->params->{errorCallback}->( 'PLUGIN_22TRACKS_ERROR', $http->error );
}

# To support remote streaming (synced players, slimp3/SB1), we need to subclass Protocols::HTTP
sub new {
    my $class  = shift;
    my $args   = shift;
    
    my $client = $args->{client};

    my $song      = $args->{song};
    my $streamUrl = $song->streamUrl() || return;
    my $track     = $song->pluginData();

    $log->info('Remote streaming 22tracks: ' . $streamUrl );

    my $sock = $class->SUPER::new( {
        url     => $streamUrl,
        song    => $song,
        client  => $client,
    } ) || return;

    ${*$sock}{contentType} = 'audio/mpeg';

    return $sock;
}

# Metadata for a URL, used by CLI/JSON clients
sub getMetadataFor {
    my ( $class, $client, $url ) = @_;
    
    return {} unless $url;

    my $cache = Slim::Utils::Cache->new;

    # If metadata is not here, fetch it so the next poll will include the data
    my ($trackId) = $url =~ m{tracks22://(.+)};
    my $meta      = $cache->get( '22tracks_meta_' . $trackId );

    return $meta || {
        type      => 'MP3 (22tracks)'
    };
}


sub canDirectStreamSong {
    my ( $class, $client, $song ) = @_;
    
    # We need to check with the base class (HTTP) to see if we
    # are synced or if the user has set mp3StreamingMethod

    return $class->SUPER::canDirectStream( $client, $song->streamUrl(), $class->getFormatForURL() );
}

# If an audio stream fails, keep playing
sub handleDirectError {
    my ( $class, $client, $url, $response, $status_line ) = @_;
    
    main::INFOLOG && $log->info("Direct stream failed: $url [$response] $status_line");
}

1;
