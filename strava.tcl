##
#
# auth: tommy balboa (tbalboa)
# date: 2014-04-23
#

package require json
package require http
package require tls

namespace eval ::strava {
	namespace eval announce {
		# set server and channel for where to announce activities.
		# set these in the config file.
		variable server []
		variable chan []

		# period in seconds between API polls.
		# you can set this in the config file.
		variable frequency 300

		# track when we last polled the api (unixtime)
		variable last_poll_time 0
	}

	# oauth token used in API requests. you can set this in the config file.
	variable oauth_token ""

	# club to retrieve activities for. you can set this in the config file.
	variable club_id 0

	# path to a configuration file. if this does not exist then the
	# defaults will be used. however the script is not very useful without
	# having set up your configuration!
	variable config_file [irssi_dir]/strava.conf

	# script version.
	variable version 1.0

	# base url to send API requests to.
	variable base_url "https://www.strava.com/api/v3"

	# http useragent.
	variable useragent "Tcl http client package 2.7"

	# http timeout. in seconds.
	variable http_timeout 2

	# number of pages of activities to request at once.
	variable per_page 30

	# this is an internal counter to track the highest activity seen.
	variable club_activity_id 0

	# we cache leaderboard activities for this many seconds.
	variable leaderboard_cache_length 3600
	# cached_time records the unixtime of when the leaderboard cache was built.
	variable leaderboard_cached_time 0
	# a list of activities - cached for leaderboard use.
	variable leaderboard_activities [list]

	# how many days back to generate a leaderboard for.
	variable leaderboard_days 14

	# how many requests maximum to make when building a single leaderboard.
	variable leaderboard_max_requests 2

	# output this many in each leaderboard at most.
	variable leaderboard_top_count 5

	# add a configuration option to set what channels are active for
	# channel triggers.
	settings_add_str "strava_enabled_channels" ""

	# add a channel for retrieving leader board for the club.
	signal_add msg_pub .leaderboard ::strava::leaderboard

	signal_add msg_pub * ::strava::msg_pub
}

# load a config from disk if one is present.
#
# the file format is:
# <setting1>=<value1>
# <setting2>=<value2>
# ...
#
# there maybe "# comment" lines.
#
# returns nothing
#
# SIDE EFFECT: we will set various global settings here.
proc ::strava::load_config {} {
	if {![file exists $::strava::config_file]} {
		irssi_print "strava: no configuration file to load! ($::strava::config_file)"
		return
	}
	if {[catch {open $::strava::config_file r} fh]} {
		irssi_print "strava: failed to open configuration file: $fh"
		return
	}
	set content [read -nonewline $fh]
	close $fh
	set lines [split $content \n]

	foreach line $lines {
		set line [string trim $line]

		if {[expr [string length $line] == 0]} {
			continue
		}

		# skip "# comment" lines.
		if {[string match [string index $line 0] #]} {
			continue
		}

		# find '=' as delimiter between setting name and its value.
		if {![regexp -- {^\s*(\S+)\s*=\s*(.*)$} $line -> setting value]} {
			irssi_print "strava: warning: invalid configuration line: $line"
			continue
		}
		set value [string trim $value]

		if {[string equal $setting oauth_token]} {
			if {[expr [string length $value] == 0]} {
				irssi_print "strava: warning: blank oauth token"
				continue
			}
			set ::strava::oauth_token $value
			continue
		}

		if {[string equal $setting club_id]} {
			if {![string is integer -strict $value]} {
				irssi_print "strava: warning: club_id is not an integer"
				continue
			}
			set ::strava::club_id $value
			continue
		}

		if {[string equal $setting announce_server]} {
			if {[expr [string length $value] == 0]} {
				irssi_print "strava: warning: blank announce server"
				continue
			}
			set ::strava::announce::server [split $value ,]
			continue
		}

		if {[string equal $setting announce_channel]} {
			if {[expr [string length $value] == 0]} {
				irssi_print "strava: warning: blank announce channel"
				continue
			}
			set ::strava::announce::chan [split $value ,]
			continue
		}

		if {[string equal $setting announce_frequency]} {
			if {![string is integer -strict $value]} {
				irssi_print "strava: warning: announce frequency is not an integer"
				continue
			}
			set ::strava::announce::frequency $value
			continue
		}
	}

	if {[llength $::strava::announce::server] != [llength $::strava::announce::chan]} {
		irssi_print "strava: Warning: mismatched number of servers/channels"
	}
}

# main loop where we continuously check for new activities and show them if
# necessary.
proc ::strava::main {} {
	# ensure we always will call ourselves again by calling after
	# immediately. this prevents things like if there being an error that
	# our loop will stop forever.
	#after [::tcl::mathop::* $::strava::announce::frequency 1000] ::strava::main
	#
	# I'm going to try not using event due to issues with ssl race conditions.
	# let's try polling when we see a message if we haven't polled in a while.

	if {![string is integer -strict $::strava::announce::frequency] || \
		[expr $::strava::announce::frequency <= 0]} \
	{
		irssi_print "strava: main: invalid announcement frequency!"
		return
	}

	::strava::club_activities
}

# the idea here is we will block and run the http request through and avoid
# race conditions. we'll do that by running when we see a message (sometimes).
#
# TODO: it would be nice if we didn't have to wait on messages but could
#   use something that happens all the time. like server pings. but there is
#   no signal implemented we can listen on for that right now.
proc ::strava::msg_pub {server nick uhost chan argv} {
	# if we haven't polled in a while then do so

	# NOTE: this doesn't care what channel we saw a message in clearly

	set next_poll_time [expr $::strava::announce::last_poll_time + \
		$::strava::announce::frequency]
	if {[clock seconds] < $next_poll_time} {
		return
	}

	set ::strava::announce::last_poll_time [clock seconds]

	::strava::main
}

# output activities we have not seen yet to the announce channel.
proc ::strava::show {club_activities} {
	if {[expr [string length $::strava::announce::server] == 0] || \
		[expr [string length $::strava::announce::chan] == 0]} \
	{
		irssi_print "strava: show: no announce server/channel set!"
		return
	}

	# List the keys in the activity we will always use.
	# achievement_count: PR
	set keys [list id distance moving_time total_elevation_gain average_speed \
		athlete achievement_count]

	foreach activity $club_activities {
		# Check the dict is sane
		if {[catch {dict size $activity} errno]} {
			irssi_print "strava: show: activity error: $errno"
			return
		}

		foreach key $keys {
			if {![dict exists $activity $key]} {
				irssi_print "strava: show: activity missing key $key"
				return
			}
		}

		set id [dict get $activity "id"]

		# If we have seen this activity before then do not show it again.
		# Note this depends on the ids being always increasing and compareable.
		if {$::strava::club_activity_id >= $id} {
			continue
		}

		set distance [::strava::convert "km" [dict get $activity "distance"]]
		set moving_time [::strava::duration [dict get $activity "moving_time"]]
		set climb [::tcl::mathfunc::int [dict get $activity "total_elevation_gain"]]
		set avg_speed [::strava::convert "kmh" [dict get $activity "average_speed"]]

		set athlete [dict get $activity athlete]
		if {[catch {dict size $athlete} err]} {
			irssi_print "show: athlete dict is invalid!"
			return
		}
		if {![dict exists $athlete firstname]} {
			irssi_print "show: athlete dict is missing firstname!"
			return
		}
		set name [dict get $athlete firstname]
		if {[expr [string length $name] == 0]} {
			irssi_print "show: athlete firstname is blank!"
			return
		}

		set achievement_count [dict get $activity achievement_count]

		set output "\00307(strava)\017 ${name}: \002Distance:\002 ${distance}km \002Speed:\002 ${avg_speed}km/h \002Moving Time:\002 ${moving_time} \002\u2191\002${climb}m"

		if {[dict exists $activity "average_watts"]} {
			set watts [::tcl::mathfunc::int [dict get $activity "average_watts"]]
			append output " ${watts}w"
		}

		if {[dict exists $activity "average_cadence"]} {
			set cadence [::tcl::mathfunc::int [dict get $activity "average_cadence"]]
			append output " ${cadence}rpm"
		}

		if {[dict exists $activity "average_heartrate"] && \
			[dict exists $activity "max_heartrate"]} \
		{
			set avg_heartrate [::tcl::mathfunc::int [dict get $activity \
				"average_heartrate"]]
			set max_heartrate [::tcl::mathfunc::int [dict get $activity \
				"max_heartrate"]]
			append output " ${avg_heartrate}\00304\u2665\017${max_heartrate}"
		}

		if {$achievement_count > 0} {
			append output " \u2605${achievement_count}"
		}

		# Output. Possibly to multiple channels.
		for {set i 0} {$i < [llength $::strava::announce::server]} {incr i} {
			set server [lindex $::strava::announce::server $i]
			set chan [lindex $::strava::announce::chan $i]
			putchan $server $chan $output
		}
	}
}

proc ::strava::convert {type meters} {
	set converted [::tcl::mathop::/ $meters 1000.0]

	if {[string match $type "kmh"]} {
		set converted [::tcl::mathop::* $converted 3600.0]
	}

	return [format "%.1f" $converted]
}

proc ::strava::duration {seconds} {
	set hours [::tcl::mathop::/ $seconds 3600]
	set seconds [::tcl::mathop::% $seconds 3600]
	set minutes [::tcl::mathop::/ $seconds 60]
	set seconds [::tcl::mathop::% $seconds 60]

	return [format "%02d:%02d:%02d" $hours $minutes $seconds]
}

proc ::strava::get_highest_id {dictionary} {
	set id 0
	foreach key $dictionary {
		set key_id [dict get $key "id"]
		if {$key_id > $id} {
			set id $key_id
		}
	}

	return $id
}

# determine if an activity falls in our leaderboard time range.
#
# if an activity is more recent than leaderboard_days ago, we return 1.
# otherwise we return 0.
#
# parameters:
# activity - an activity dict.
#
# returns integer: 1 if activity should be included, 0 if not.
#
# SIDE EFFECT: throws an error if there is an error!
proc ::strava::activity_is_in_leaderboard {activity} {
		# check dict is valid.
		if {[catch {dict size $activity}]} {
			irssi_print "activity_is_in_leaderboard: invalid dict found"
			error "invalid activity dict found"
		}
		# get its date and find out how many days ago it was.
		if {![dict exists $activity start_date]} {
			irssi_print "activity_is_in_leaderboard: activity dict is missing start_date!"
			error "activity dict does not have start_date"
		}
		set start_date [dict get $activity start_date]
		# TODO: is this actually GMT? docs seem ambiguous.
		set start_date_unixtime [clock scan $start_date \
			-format "%Y-%m-%dT%H:%M:%SZ" -timezone :GMT]
		set diff [expr [clock seconds] - $start_date_unixtime]
		if {[expr $diff >= [expr $::strava::leaderboard_days * 24 * 60 * 60]]} {
			return 0
		}
		return 1
}

# generate and output the leaderboard to the IRC channel.
#
# parameters:
# server - the server to send leaderboard to
# chan - the channel to send leaderboard to
# activities - list of activities retrieved to build the leaderboard.
#
# returns nothing.
proc ::strava::leaderboard_output {server chan activities} {
	# pull out the totals for each athlete.
	set elevations [dict create]
	set distances [dict create]
	set speeds [dict create]
	set moving_times [dict create]
	foreach activity $activities {
		# NOTE: we assume the dict is valid at this point!
		if {![::strava::activity_is_in_leaderboard $activity]} {
			continue
		}
		# get the athlete name as a unique identifier for them.
		# TODO: first name is not a very unique key if we have a big club!
		if {![dict exists $activity athlete]} {
			irssi_print "leaderboard_output: activity is missing athlete!"
			return
		}
		set athlete [dict get $activity athlete]
		if {![dict exists $athlete firstname]} {
			irssi_print "leaderboard_output: athlete is missing firstname!"
			return
		}
		set name [dict get $athlete firstname]
		if {[expr [string length $name] == 0]} {
			irssi_print "leaderboard_output: athlete name is blank!"
			return
		}

		# elevation.
		if {![dict exists $elevations $name]} {
			dict set elevations $name 0
		}
		if {![dict exists $activity total_elevation_gain]} {
			irssi_print "leaderboard_output: total_elevation_gain is missing!"
			return
		}
		dict set elevations $name [expr [dict get $elevations $name] \
			+ [dict get $activity total_elevation_gain]]

		# distance.
		if {![dict exists $distances $name]} {
			dict set distances $name 0
		}
		if {![dict exists $activity distance]} {
			irssi_print "leaderboard_output: distance missing!"
			return
		}
		dict set distances $name [expr [dict get $distances $name] \
			+ [dict get $activity distance]]

		# speed.
		if {![dict exists $speeds $name]} {
			dict set speeds $name 0
		}
		if {![dict exists $activity average_speed]} {
			irssi_print "leaderboard_output: average_speed missing!"
			return
		}
		if {[expr [dict get $activity average_speed] > [dict get $speeds $name]]} {
			dict set speeds $name [dict get $activity average_speed]
		}

		# moving time.
		if {![dict exists $moving_times $name]} {
			dict set moving_times $name 0
		}
		if {![dict exists $activity moving_time]} {
			irssi_print "leaderboard_output: moving_time missing!"
			return
		}
		dict set moving_times $name [expr [dict get $moving_times $name] \
			+ [dict get $activity moving_time]]
	}
	if {[expr [dict size $elevations] == 0]} {
		putchan $server $chan "No athletes!"
	}

	# sort everything. I build lists so we can use lsort.
	set athlete_elevations [list]
	set athlete_distances [list]
	set athlete_speeds [list]
	set athlete_moving_times [list]
	foreach athlete [dict keys $elevations] {
		lappend athlete_elevations [list $athlete [dict get $elevations $athlete]]
		lappend athlete_distances [list $athlete [dict get $distances $athlete]]
		lappend athlete_speeds [list $athlete [dict get $speeds $athlete]]
		lappend athlete_moving_times [list $athlete [dict get $moving_times \
			$athlete]]
	}
	set athlete_elevations_sorted [lsort -real -decreasing -index 1 \
		$athlete_elevations]
	set athlete_distances_sorted [lsort -real -decreasing -index 1 \
		$athlete_distances]
	set athlete_speeds_sorted [lsort -real -decreasing -index 1 \
		$athlete_speeds]
	set athlete_moving_times_sorted [lsort -real -decreasing -index 1 \
		$athlete_moving_times]

	putchan $server $chan "Elevation leaderboard for the past $::strava::leaderboard_days days:"
	set i 0
	foreach athlete_elevation $athlete_elevations_sorted {
		lassign $athlete_elevation athlete elevation
		incr i
		if {[expr $i > $::strava::leaderboard_top_count]} {
			break
		}
		set elevation [::tcl::mathfunc::int $elevation]
		set output "$i. $athlete @ ${elevation}m"
		putchan $server $chan $output
	}
	putchan $server $chan "Distance leaderboard for the past $::strava::leaderboard_days days:"
	set i 0
	foreach athlete_distance $athlete_distances_sorted {
		lassign $athlete_distance athlete distance
		incr i
		if {[expr $i > $::strava::leaderboard_top_count]} {
			break
		}
		set distance [::strava::convert km $distance]
		set output "$i. $athlete @ ${distance}km"
		putchan $server $chan $output
	}
	putchan $server $chan "Average speed leaderboard for the past $::strava::leaderboard_days days:"
	set i 0
	foreach athlete_speed $athlete_speeds_sorted {
		lassign $athlete_speed athlete speed
		incr i
		if {[expr $i > $::strava::leaderboard_top_count]} {
			break
		}
		set speed [::strava::convert kmh $speed]
		set output "$i. $athlete @ ${speed}km/h"
		putchan $server $chan $output
	}
	putchan $server $chan "Moving time leaderboard for the past $::strava::leaderboard_days days:"
	set i 0
	foreach athlete_moving_time $athlete_moving_times_sorted {
		lassign $athlete_moving_time athlete moving_time
		incr i
		if {[expr $i > $::strava::leaderboard_top_count]} {
			break
		}
		set moving_time [::strava::duration $moving_time]
		set output "$i. $athlete @ ${moving_time}"
		putchan $server $chan $output
	}
}

# handle a callback from an API request to build a leaderboard.
#
# see leaderboard_cb.
proc ::strava::_leaderboard_cb {server chan activities page request_count token} \
{
	# check the response
	set status [::http::status $token]
	if {![string match $status ok]} {
		irssi_print "_leaderboard_cb: HTTP request problem"
		::http::cleanup $token
		return
	}
	# parse out the activities.
	set data [::http::data $token]
	::http::cleanup $token
	set new_activities [::json::json2dict $data]
	# we have a list of activities now... not a dict yet, I think... so check the
	# dict as we iterate rather than checking $new_activities itself.
	foreach activity $new_activities {
		# check we have a valid dict.
		if {[catch {dict size $activity}]} {
			irssi_print "_leaderboard_cb: HTTP response is not valid json"
			return
		}
		# TODO: should we check the activity isn't already in our list somehow?
		#   possible race condition here... for example if an activity shows up on
		#   two pages we requested.
		lappend activities $activity
	}

	# now determine if we have enough activities to stop and generate the output
	# or if we have to start a new request to get more activities
	# we can stop if we received less than per_page activities (as that means we
	# hit the end of activities), or if we have an activity that's more than
	# leaderboard_days days back (because we only need activities up to that
	# point).
	if {[expr [llength $new_activities] < $::strava::per_page]} {
		irssi_print "_leaderboard_cb: hit end of activities"
		set ::strava::leaderboard_cached_time [clock seconds]
		set ::strava::leaderboard_activities $activities
		::strava::leaderboard_output $server $chan $activities
		return
	}
	# check if there's an activity that is outside of our leaderboard range. if
	# so, we can stop.
	foreach activity $activities {
		if {![::strava::activity_is_in_leaderboard $activity]} {
			irssi_print "_leaderboard_cb: found activity that is old enough, done!"
			set ::strava::leaderboard_cached_time [clock seconds]
			set ::strava::leaderboard_activities $activities
			::strava::leaderboard_output $server $chan $activities
			return
		}
	}
	# we also do not make any more API requests if we're at our maximum number of
	# requests already.
	if {[expr $request_count >= $::strava::leaderboard_max_requests]} {
		irssi_print "_leaderboard_cb: max API request count hit"
		set ::strava::leaderboard_cached_time [clock seconds]
		set ::strava::leaderboard_activities $activities
		::strava::leaderboard_output $server $chan $activities
		return
	}
	# we need to start a new request for more activities it seems.
	incr page
	::strava::leaderboard_api_request $server $chan $activities $page \
		$request_count
}

# callback from an http request to build a leaderboard.
#
# if we have enough activities for this leaderboard then we'll send the output.
# otherwise we'll initiate another API request.
#
# params:
# in the params list:
#   server - the server to send leaderboard to
#   chan - the channel to send leaderboard to
#   activities - list of activities retrieved so far. may be empty.
#     this is necessary because we may need to retrieve multiple pages of
#     activities and so this will hold those we've received so far.
#   page - the page we're on of activities
#   request_count - how many api requests we've made so far.
# token - ::http token
#
# returns nothing
proc ::strava::leaderboard_cb {params token} {
	lassign $params server chan activities page request_count
	# why is this structured this way? because due to us using async requests
	# we can 'lose' errors and make for difficult debugging if we don't
	# catch errors somewhere. it's a limitation with ::http::geturl that I haven't
	# figured a better solution for than this.
	if {[catch {::strava::_leaderboard_cb $server $chan $activities $page \
		$request_count $token} err]} \
	{
		irssi_print "leaderboard_cb: encountered error: $err"
	}
}

# initiate a new leaderboard API request.
#
# we expect we really do want to make an api request (though we'll check that
# request_count is within range just in case). otherwise we don't double check
# whether there are enough activities to output already.
#
# parameters:
# server - the server to send leaderboard to
# chan - the channel to send leaderboard to
# activities - list of activities retrieved so far. may be empty.
#   this is necessary because we may need to retrieve multiple pages of
#   activities and so this will hold those we've received so far.
# page - the page we're on of activities
# request_count - how many api requests we've made so far.
#
# returns void.
proc ::strava::leaderboard_api_request {server chan activities page request_count} {
	if {[expr $request_count >= $::strava::leaderboard_max_requests]} {
		irssi_print "leaderboard_api_request: already at maximum number of requests!"
		return
	}
	irssi_print "leaderboard_api_request: requesting page $page"
	set url [join [list $::strava::base_url "clubs" $::strava::club_id "activities"] "/"]
	set params [::http::formatQuery page $page per_page $::strava::per_page]
	append url "?$params"
	incr request_count

	# TODO: are there escaping issues here with this callback?
	set params [list [list $server $chan $activities $page $request_count]]
	set cb "::strava::leaderboard_cb $params"
	::strava::api_request $url $cb
}

# channel trigger to retrieve the leaderboard for the club.
#
# we will start an API request to determine this.
#
# parameters:
# server - server where trigger initiated
# nick - who initiated the trigger
# uhost - userhost of who initiated the trigger
# chan - channel where trigger initiated
# argv - arguments to the trigger
#
# returns nothing.
proc ::strava::leaderboard {server nick uhost chan argv} {
	if {![str_in_settings_str "strava_enabled_channels" $chan]} {
		return
	}
	# may have cached results for the leaderboard.
	if {[expr [clock seconds] < $::strava::leaderboard_cached_time \
		+ $::strava::leaderboard_cache_length]} \
	{
		irssi_print "leaderboard: using leaderboard cache"
		::strava::leaderboard_output $server $chan $::strava::leaderboard_activities
		return
	}
	set activities [list]
	set page 1
	set request_count 0
	::strava::leaderboard_api_request $server $chan $activities $page \
		$request_count
}

# callback for a club activities poll.
#
# see club_activities_cb
proc ::strava::_club_activities_cb {token} {
	set code [::http::code $token]
	set status [::http::status $token]
	if {![string match $status "ok"]} {
		irssi_print "_club_activities_cb: HTTP request problem: $status: $code"
		::http::cleanup $token
		return
	}
	set data [::http::data $token]
	::http::cleanup $token
	set activities [::json::json2dict $data]

	# we only show activities if we have seen an activity already because
	# otherwise on startup we'll spit out every activity.
	if {$::strava::club_activity_id != 0} {
		::strava::show $activities
	}
	# store highest we've seen now so we don't notify about the same activities
	# next time.
	set ::strava::club_activity_id [::strava::get_highest_id $activities]
}

# this proc is a callback from ::http::geturl called asynchronously
# in ::strava::club_activities.
#
# we parse the response and output the activities, if any.
#
# parameters:
# token: the ::http request token
#
# returns nothing
proc ::strava::club_activities_cb {token} {
	# wrap the main logic so we can catch errors. otherwise if an error occurs
	# due to this being an asynchronous request we will not see any error.
	if {[catch {::strava::_club_activities_cb $token} err]} {
		irssi_print "club_activities_cb: error encountered: $err"
	}
}

# start an http request to the strava API.
#
# this is asynchronous so we don't block.
#
# parameters:
# url - url to request to
# cb - callback function to run on http request completion
#
# returns nothing.
proc ::strava::api_request {url cb} {
	if {[expr [string length $::strava::oauth_token] == 0]} {
		irssi_print "strava: api_request: cannot perform API request without a token!"
		return
	}
	set headers [list "Authorization" "Bearer $::strava::oauth_token"]
	# set a useragent prior to every request. why? because many scripts set this
	# and we could end up with an unknown useragent if we don't. this is
	# apparently a limitation with global state in the http package.
	::http::config -useragent $::strava::useragent
	::http::register https 443 [list ::tls::socket -ssl2 0 -ssl3 0 -tls1 1]
	set http_token [::http::geturl \
		$url \
		-headers $headers \
		-timeout [expr $::strava::http_timeout * 1000] \
	]

	{*}$cb $http_token
}

# start an http request to retrieve and output club activities.
# this is asynchronous so we don't block.
#
# returns nothing.
proc ::strava::club_activities {} {
	if {![string is integer -strict $::strava::club_id] || \
		[expr $::strava::club_id <= 0]} \
	{
		irssi_print "strava: api_request: you must set a club id"
		return
	}
	set url [join [list $::strava::base_url "clubs" $::strava::club_id "activities"] "/"]
	set page 1
	# only get a small number at once because we will be polling frequently
	# usually.
	set per_page 5
	set params [::http::formatQuery page $page per_page $per_page]
	append url "?$params"
	::strava::api_request $url ::strava::club_activities_cb
}

::strava::load_config
::strava::main
irssi_print "strava.tcl v $::strava::version loaded (c) tbalboa 2016"
