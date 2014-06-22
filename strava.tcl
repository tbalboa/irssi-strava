##
#
# auth: tommy balboa (tbalboa)
# date: 2014-04-23
#

package require json
package require http
package require tls

::http::register https 443 ::tls::socket

namespace eval ::strava {
	namespace eval announce {
		# set server and channel for where to announce activities.
		# you can set these in the config file.
		variable server ""
		variable chan ""

		# period in seconds between API polls.
		# you can set this in the config file.
		variable frequency 300
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
	variable http_timeout 5

	# number of pages of activities to request at once.
	variable per_page 30

	# this is an internal counter to track the highest activity seen.
	variable club_activity_id 0

	# cache leaderboard for 1 hour.
	# TODO: caching feature is incomplete.
	variable leaderboard_cache_length 3600
	variable leaderboard_cache_time 0

	# how many days back to generate a leaderboard for.
	variable leaderboard_days 14

	# how many requests maximum to make when building a single leaderboard.
	variable leaderboard_max_requests 2

	# add a configuration option to set what channels are active for
	# channel triggers.
	settings_add_str "strava_enabled_channels" $::strava::announce::chan

	# add a channel for retrieving leader board for the club.
	signal_add msg_pub .leaderboard ::strava::leaderboard
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
			}
			set ::strava::announce::server $value
			continue
		}
		if {[string equal $setting announce_channel]} {
			if {[expr [string length $value] == 0]} {
				irssi_print "strava: warning: blank announce channel"
			}
			set ::strava::announce::chan $value
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
}

# main loop where we continuously check for new activities and show them if
# necessary.
proc ::strava::main {} {
	::strava::club_activities
	if {![string is integer -strict $::strava::announce::frequency] || \
		[expr $::strava::announce::frequency <= 0]} \
	{
		irssi_print "strava: main: invalid announcement frequency!"
		return
	}
	after [::tcl::mathop::* $::strava::announce::frequency 1000] ::strava::main
}

proc ::strava::show {club_activities} {
	if {[expr [string length $::strava::announce::server] == 0] || \
		[expr [string length $::strava::announce::chan] == 0]} \
	{
		irssi_print "strava: show: no announce server/channel set!"
		return
	}
	foreach activity $club_activities {
		if {[catch {dict size $activity} errno]} {
			irssi_print "strava activity error: $errno"
			continue
		}

		# TODO: check each key we want in the dict is there - it's an error to get
		#   one and it not be present.
		set id [dict get $activity "id"]
		if {$::strava::club_activity_id >= $id} {
			continue
		}

		set distance [::strava::convert "km" [dict get $activity "distance"]]
		set moving_time [::strava::duration [dict get $activity "moving_time"]]
		set climb [::tcl::mathfunc::int [dict get $activity "total_elevation_gain"]]
		set avg_speed [::strava::convert "kmh" [dict get $activity "average_speed"]]
		set name [dict get $activity "athlete" "firstname"]

		#set timestamp [dict get $activity "start_date_local"]
		#set unix [clock scan $timestamp -format "%Y-%m-%dT%H:%M:%SZ"]

		set output "\00307(strava)\017 ${name}: \002Distance:\002 ${distance}km \002Speed:\002 ${avg_speed}km/h \002Moving Time:\002 ${moving_time} \002\u2191\002${climb}m"

		if {[dict exists $activity "average_watts"]} {
			set watts [::tcl::mathfunc::int [dict get $activity "average_watts"]]
			append output " ${watts}w"
		}

		if {[dict exists $activity "average_cadence"]} {
			set cadence [::tcl::mathfunc::int [dict get $activity "average_cadence"]]
			append output " ${cadence}rpm"
		}

		if {[dict exists $activity "average_heartrate"] && [dict exists $activity "max_heartrate"]} {
			set avg_heartrate [::tcl::mathfunc::int [dict get $activity "average_heartrate"]]
			set max_heartrate [::tcl::mathfunc::int [dict get $activity "max_heartrate"]]
			append output " ${avg_heartrate}\00304\u2665\017${max_heartrate}"
		}

		putchan $::strava::announce::server $::strava::announce::chan $output
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
		set climb [::tcl::mathfunc::int [dict get $activity total_elevation_gain]]
		dict incr elevations $name $climb
	}
	# sort them. I convert to a list so we can use lsort.
	set elevations_list [list]
	foreach athlete [dict keys $elevations] {
		lappend elevations_list [list $athlete [dict get $elevations $athlete]]
	}
	set elevs_sorted [lsort -integer -decreasing -index 1 $elevations_list]
	putchan $server $chan "Leaderboard (elevation) for the past $::strava::leaderboard_days days:"
	set i 0
	foreach elev $elevs_sorted {
		lassign $elev athlete elevation
		incr i
		if {[expr $i > 10]} {
			break
		}
		set output "$i. $athlete @ ${elevation}m"
		putchan $server $chan $output
	}
	if {[expr [llength $elevs_sorted] == 0]} {
		putchan $server $chan "No athletes!"
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
		::strava::leaderboard_output $server $chan $activities
		return
	}
	# check if there's an activity that is outside of our leaderboard range. if
	# so, we can stop.
	foreach activity $activities {
		if {![::strava::activity_is_in_leaderboard $activity]} {
			irssi_print "_leaderboard_cb: found activity that is old enough, done!"
			::strava::leaderboard_output $server $chan $activities
			return
		}
	}
	# we also do not make any more API requests if we're at our maximum number of
	# requests already.
	if {[expr $request_count >= $::strava::leaderboard_max_requests]} {
		irssi_print "_leaderboard_cb: max API request count hit"
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
	set activities [list]
	set page 1
	set request_count 0
	::strava::leaderboard_api_request $server $chan $activities $page \
		$request_count
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
	if {![string match [::http::status $token] "ok"]} {
		irssi_print "club_activities_cb: HTTP request problem"
		::http::cleanup $token
		return
	}
	set data [::http::data $token]
	::http::cleanup $token

	set activities [::json::json2dict $data]
	# check that we have a valid dict.
	# TODO: we don't have a dict here, do we? we should have a list.
	if {[catch {dict size $activities}]} {
		irssi_print "club_activities_cb: HTTP response is not valid json"
		return
	}

	# we only show activities if we have seen an activity already because
	# otherwise on startup we'll spit out every activity.
	if {$::strava::club_activity_id != 0} {
		::strava::show $activities
	}
	# store highest we've seen now so we don't notify about the same activities
	# next time.
	set ::strava::club_activity_id [::strava::get_highest_id $activities]
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
	set http_token [::http::geturl $url -headers $headers \
		-timeout [expr $::strava::http_timeout * 1000] \
		-command $cb]
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
irssi_print "strava.tcl v $::strava::version loaded (c) tbalboa 2014"
