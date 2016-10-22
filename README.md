# A 22tracks plugin for Logitech SqueezeBox media server #

This is a Logitech Media Server (LMS) (a.k.a Squeezebox server) plugin to browse
Spotify playlists from 22tracks. It is not really needed, because a Squeezebox can
already browse Spotify playlists. This plugin is there to make browsing those
playlists a but easier, and to provide an upgrade path from the old plugin that
streamed from 22tracks own web site, to the new implementation with Spotify streams.

To install, use the settings page of Logitech Media server.
Go to the _Plugins_ tab, scroll down to _Third party source_ and select _22tracks_.
Press the _Apply_ button and restart LMS.

The plugin is included as a default third party resource. It is distributed via my
[personal repository](http://server.vijge.net/squeezebox/) There is no need
to add an additional repository, because this is an official third party repository.
However, if you want to, you can add the repository directly. A new version might be
earlier available in this repository:
    
    http://danielvijge.github.io/squeezebox-22tracks/public.xml

The old version of this plugin is available in the brach _old-22tracks_. It is kept
there because it is a nice example of a plugin that reads data from a JSON feed and
plays tracks from a remote source.

## Licence ##

This work is distributed under the GNU General Public License version 2. See file LICENSE for
full license details.
