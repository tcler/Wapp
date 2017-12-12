# Copyright (c) 2017 D. Richard Hipp
# 
# This program is free software; you can redistribute it and/or
# modify it under the terms of the Simplified BSD License (also
# known as the "2-Clause License" or "FreeBSD License".)
#
# This program is distributed in the hope that it will be useful,
# but without any warranty; without even the implied warranty of
# merchantability or fitness for a particular purpose.
#
#---------------------------------------------------------------------------
#
# Design rules:
#
#   (1)  All identifiers in the global namespace begin with "wapp"
#
#   (2)  Indentifiers intended for internal use only begin with "wappInt"
#
#   (2)  Assume single-threaded operation
#
#   (3)  Designed for maintainability
#
proc wapp {txt} {
  global wapp
  dict append wapp .reply $txt
}
proc wapp-unsafe {txt} {
  global wapp
  dict append wapp .reply $txt
}
proc wapp-escape-html {txt} {
  global wapp
  dict append wapp .reply [string map {& &amp; < &lt; > &gt;} $txt]
}
proc wapp-reset {} {
  global wapp
  dict set wapp .reply {}
}
proc wapp-mimetype {x} {
  global wapp
  dict set wapp .mimetype $x
}
proc wapp-reply-code {x} {
  global wapp
  dict set wapp .reply-code $x
}

# This is a safety-check that is run prior to startup
#
# Examine the bodys of all procedures in this program looking for
# unsafe calls to "wapp".  Issue warnings.
#
proc wapp-safety-check {} {
  foreach p [info procs] {
    set ln 0
    foreach x [split [info body $p] \n] {
      incr ln
      if {[regexp {[;\n] *wapp +\[} $x] ||
          [regexp {[;\n] *wapp +"[^\n]*[[$]} $x]} {
        puts "$p:$ln: unsafe \"wapp\" call: \"[string trim $x]\"\n"
      }
    }
  }
}

# Start up the wapp framework.  Parameters are a list passed as the
# single argument.
#
#    -port $PORT           Listen on this TCP port
#
#    -mode $MODE           One of "auto" (the default), "cgi", "server"
#                          or "scgi".
#
proc wapp-start {arglist} {
  set mode auto
  set port 0
  set n [llength $arglist]
  for {set i 0} {$i<$n} {incr i} {
    switch -- [lindex $args $i] {
      -port {incr i; set port [lindex $args $i]}
      -mode {incr i; set mode [lindex $args $i]}
      default {error "unknown option: [lindex $args 1]"}
    }
  }
  if {$mode=="auto" && [info exists env(GATEWAY_INTERFACE)]
        && $env(GATEWAY_INTERFACE)=="CGI/1.0"} {
     wappInt-hanle-cgi-request
  }
  if {$mode=="server"} {
    wappInt-start-listener $port 0 0
  } else {
    wappInt-start-listener $port 1 1
  }
  vwait ::forever
}

# Start up a listening socket.  Arrange to invoke wappInt-new-connection
# for each inbound HTTP connection.
#
#    localonly   -   If true, listen on 127.0.0.1 only
#
#    browser     -   If true, launch a web browser pointing to the new server
#
proc wappInt-start-listener {port localonly browser} {
  if {$localonly} {
    set x [socket -server wappInt-new-connection -myaddr 127.0.0.1 $port]
  } else {
    set x [socket -server wappInt-new-connection $port]
  }
  if {$browser} {
    set port [chan configure $x -sockname]
    set url http://[lindex $port 1]:[lindex $port 2]/
    wappInt-start-browser $url
  }
}

# Start a web-browser and point it at $URL
#
proc wappInt-start-browser {url} {
  global tcl_platform
  if {$tcl_platform(platform)=="windows"} {
    exec start $url &
  } elseif {$tcl_platform(os)=="Darwin"} {
    exec open $url &
  } elseif {[catch {exec xdg-open $url}]} {
    exec firefox $url &
  }
}

# Accept a new inbound HTTP request
#
proc wappInt-new-connection {chan ip port} {
  upvar #0 wappInt-$chan W
  set W [dict create REMOTE_HOST $ip:$port .header {}]
  fconfigure $chan -blocking 0 -translation binary
  fileevent $chan readable "wappInt-readable $chan"
}

# Close an input channel
#
proc wappInt-close-channel {chan} {
  unset ::wappInt-$chan
  close $chan
}

# Process new text received on an inbound HTTP request
#
proc wappInt-readable {chan} {
  if {[catch [list wappInt-readable-unsafe $chan] msg]} {
    puts stderr "$msg\n$::errorInfo"
    wappInt-close-channel $chan
  }
}
proc wappInt-readable-unsafe {chan} {
  upvar #0 wappInt-$chan W
  set line [string trimright [gets $chan]]
  set n [string length $line]
  if {$n>0} {
    if {[dict get $W .header]=="" || [regexp {^\s+} $line]} {
      dict append W .header $line
    } else {
      dict append W .header \n$line
    }
    if {[string length [dict get $W .header]]>100000} {
      error "HTTP request header too big - possible DOS attack"
    }
  } elseif {$n==0} {
    wappInt-parse-header $chan
    if {[dict get $W REQUEST_METHOD]=="POST"
           && [dict exists $W hdr.CONTENT-LENGTH]
           && [string is integer -strict [dict get $W hdr.CONTENT-LENGTH]]} {
      dict set W .toread [dict get $W hdr.CONTENT-LENGTH]
      fileevent $chan readable [list wappInt-read-post-data $chan]
    } else {
      wappInt-handle-request $chan
    }
  }
}

# Read in as much of the POST data as we can
#
proc wappInt-read-post-data {chan} {
  if {[catch [list wappInt-read-post-data-unsafe $chan]]} {
    wappInt-close-channel $chan
  }
}
proc wappInt-read-post-data-unsafe {chan} {
  upvar #0 wappInt-$chan W
  set got [read $chan [dict get $W .toread]]
  dict append W .post $got
  dict set W .toread [expr {[dict get $W .toread]-[string length $got]}]
  if {[dict get $W .toread]<=0} {
    wappInt-parse-post-data $chan
    wappInt-handle-request $chan
  }
}

# Decode the HTTP request header.
#
# This routine is always running inside of a [catch], so if
# any problems arise, simply raise an error.
#
proc wappInt-parse-header {chan} {
  upvar #0 wappInt-$chan W
  set hdr [split [dict get $W .header] \n]
  set req [lindex $hdr 0]
  dict set W REQUEST_METHOD [lindex $req 0]
  if {[lsearch {GET HEAD POST} [dict get $W REQUEST_METHOD]]<0} {
    error "unsupported request method: \"[dict get $W REQUEST_METHOD]\""
  }
  set uri [lindex $req 1]
  set split_uri [split $uri ?]
  set uri0 [lindex $split_uri 0]
  if {![regexp {^/[-.a-z0-9_/]*$} $uri0]} {
    error "invalid request uri: \"$uri0\""
  }
  dict set W REQUEST_URI $uri0
  dict set W PATH_INFO $uri0
  dict set W QUERY_STRING [lindex $split_uri 1]
  if {[regexp {^/([^/]+)(.*)$} $uri0 all head tail]} {
    dict set W PATH_HEAD $head
    dict set W PATH_TAIL $tail
  } else {
    dict set W PATH_HEAD {}
    dict set W PATH_TAIL {}
  }
  set n [llength $hdr]
  for {set i 1} {$i<$n} {incr i} {
    set x [lindex $hdr $i]
    if {![regexp {^(.+): +(.*)$} $x all name value]} {
      error "invalid header line: \"$x\""
    }
    set name [string toupper $name]
    dict set W .hdr:$name $value
  }
  if {![dict exists $W hdr.HOST]} {
    dict set W BASE_URL {}
  } elseif {[dict exists $W HTTPS]} {
    dict set W BASE_URL https://[dict get $W hdr.HOST]
  } else {
    dict set W BASE_URL http://[dict get $W REMOTE_HOST]
  }
}

# Invoke application-supplied methods to generate a reply to
# a single HTTP request.
#
# This routine always runs within [catch], so handle exceptions by
# invoking [error].
#
proc wappInt-handle-request {chan} {
  upvar #0 wappInt-$chan W wapp wapp
  set wapp $W
  dict set wapp .reply {}
  dict set wapp .mimetype text/html
  dict set wapp .reply-code {200 Ok}
  set mname [dict get $wapp PATH_HEAD]
  if {$mname!="" && [llength [info commands wapp-page-$mname]]>0} {
    wapp-page-$mname
  } else {
    wapp-default
  }
  puts $chan "HTTP/1.0 [dict get $wapp .reply-code]\r"
  puts $chan "Server: wapp\r"
  puts $chan "Content-Length: [string length [dict get $wapp .reply]]\r"
  puts $chan "Content-Type: [dict get $wapp .mimetype]\r"
  puts $chan "Connection: Closed\r\n\r"
  puts $chan [dict get $wapp .reply]
  flush $chan
  wappInt-close-channel $chan
}
