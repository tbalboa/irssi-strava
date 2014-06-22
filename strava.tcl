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
		variable server ""
		variable chan ""

		variable frequency 300
	}

	settings_add_str "strava_enabled_channels" $::strava::announce::chan

	variable version 1.0

	# you must set your token here.
	variable oauth_token ""
	variable base_url "https://www.strava.com/api/v3"

	# you must set this to your club.
	variable club_id 0

	# this is an internal counter to track the highest activity seen.
	variable club_activity_id 0
	# cache leaderboard for 1 hour
	variable leaderboard_cache_length 3600
	variable leaderboard_cache_time 0

	variable debug 0

	signal_add msg_pub !clubs ::strava::clubs
#	signal_add msg_pub !strava ::strava::main
#	signal_add msg_pub .strava ::strava::main
}

# main loop where we continuously check for new activities and show them if
# necessary.
proc ::strava::main {} {
	::strava::club_activities
	after [::tcl::mathop::* $::strava::announce::frequency 1000] ::strava::main
}

proc ::strava::show {club_activities} {
	foreach activity $club_activities {
		if {[catch {dict size $activity} errno]} {
			irssi_print "strava activity error: $errno"
			continue
		}

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

proc ::strava::clubs {server nick uhost chan argv} {
	if {![str_in_settings_str "strava_enabled_channels" $chan]} {
		return
	}
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
	if {[catch {dict size $activities}]} {
		irssi_print "club_activities_cb: HTTP request is not valid json"
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

# start an http request to retrieve and output club activities.
# this is asynchronous so we don't block.
#
# returns nothing.
proc ::strava::club_activities {} {
	if {$::strava::debug == 1} {
		set fid [open "json.txt" r]
		set data [read $fid]
		close $fid
		return [::json::json2dict $data]
	}
	set headers [list "Authorization" "Bearer $::strava::oauth_token"]
	set url [join [list $::strava::base_url "clubs" $::strava::club_id "activities"] "/"]
	set http_token [::http::geturl $url -headers $headers -timeout 5000 \
		-command ::strava::club_activities_cb]
}

::strava::main

irssi_print "strava.tcl v $::strava::version loaded (c) tbalboa 2014"
