irssi-strava is an [irssi-tcl](https://github.com/horgh/irssi-tcl) script that
allows showing Strava activities to IRC channels.

It periodically polls a Strava club for new activities. For each activity it has
not seen before, it outputs information about the activity to the configured
channel(s).

It also has a trigger in channels, `.leaderboard`, to output the top athletes
in a club for various metrics.


# Setup
To use the script you need to install the
[irssi-tcl](https://github.com/horgh/irssi-tcl) Irssi module.

Afterwards, copy `strava.conf.example` to `~/.irssi/strava.conf`, and edit it.
You must set at least `oauth_token`, `club_id`, `announce_server`, and
`announce_channel`.

To get an `oauth_token`, see the [Strava API
documentation](http://strava.github.io/api/#access).

To know the `club_id` to use, go to the club's page. Hovering over several of
the links will show a number such as `79240` as part of the links. This is the
`club_id`. Alternatively, there is an [API
request](http://strava.github.io/api/v3/clubs/#get-athletes) to list the clubs
an athlete is a member of.

`announce_server` and `announce_channel` are comma separated lists of servers
and corresponding channels to output to.

Place `strava.tcl` in `~/.irssi/tcl` and add it to `~/.irssi/tcl/scripts.conf`.
Then load or reload the `irssi-tcl` module (`/unload tcl` then `/load tcl`).

You should see activities start to appear as new ones are added. Note the
script will note the most recent activity when it is first loaded, and not
output any activities until a new one (after the script was loaded) appears.
This is to avoid large amounts of repetitive output each time you load the
script.
