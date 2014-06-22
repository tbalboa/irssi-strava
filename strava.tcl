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

		# period in seconds between API polls.
		variable frequency 300
	}

	# add a configuration option to set what channels are active for
	# channel triggers.
	settings_add_str "strava_enabled_channels" $::strava::announce::chan

	# script version.
	variable version 1.0

	# path to a configuration file. if this does not exist then the
	# defaults will be used. however the script is not very useful without
	# having set up your configuration!
	variable config_file [irssi_dir]/strava.conf

	# you must set your token here.
	variable oauth_token ""

	# base url to send API requests to.
	variable base_url "https://www.strava.com/api/v3"

	# you must set this to your club.
	variable club_id 0

	# http useragent.
	variable useragent "Tcl http client package 2.7"

	# this is an internal counter to track the highest activity seen.
	variable club_activity_id 0

	# cache leaderboard for 1 hour
	variable leaderboard_cache_length 3600
	variable leaderboard_cache_time 0

	# debug mode. currently only controls whether we will use a cached
	# json file instead of requesting a new one.
	variable debug 0

	signal_add msg_pub !clubs ::strava::clubs
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
	# set a useragent prior to every request. why? because many scripts set this
	# and we could end up with an unknown useragent if we don't. this is
	# apparently a limitation with global state in the http package.
	::http::config -useragent $::strava::useragent
	set http_token [::http::geturl $url -headers $headers -timeout 5000 \
		-command ::strava::club_activities_cb]
}

::strava::load_config
::strava::main
irssi_print "strava.tcl v $::strava::version loaded (c) tbalboa 2014"
