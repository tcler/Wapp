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

# Add text to the end of the HTTP reply.  wapp and wapp-safe work the
# same.  The only difference is in how wapp-safety-check deals with these
# procs during analysis.
#
proc wapp {txt} {
  global wapp
  dict append wapp .reply $txt
}
proc wapp-unsafe {txt} {
  global wapp
  dict append wapp .reply $txt
}

# Append text after escaping it for HTML
#
proc wapp-escape-html {txt} {
  global wapp
  dict append wapp .reply [string map {& &amp; < &lt; > &gt;} $txt]
}

# Append text after escaping it for URL query parameters.
#
proc wapp-escape-url {txt} {
  global wapp
  dict append wapp .reply [wappInt-url-encode $txt]
}

# Reset the document back to an empty string.
#
proc wapp-reset {} {
  global wapp
  dict set wapp .reply {}
}

# Change the mime-type of the result document.
proc wapp-mimetype {x} {
  global wapp
  dict set wapp .mimetype $x
}

# Change the reply code.
#
proc wapp-reply-code {x} {
  global wapp
  dict set wapp .reply-code $x
}

# Set a cookie
#
proc wapp-set-cookie {name value} {
  global wapp
  dict lappend wapp .new-cookies $name $value
}

# Examine the bodys of all procedures in this program looking for
# unsafe calls to "wapp".  Return a text string containing warnings.
# Return an empty string if all is ok.
#
# This routine is advisory only.  It misses some constructs that are
# dangerous and flags others that are safe.
#
proc wapp-safety-check {} {
  set res {}
  foreach p [info procs] {
    set ln 0
    foreach x [split [info body $p] \n] {
      incr ln
      if {[regexp {^[ \t]*wapp[ \t]+\[} $x] ||
          [regexp {^[ \t]*wapp[ \t]+[^\173][^\n]*[[$]} $x]} {
        append res "$p:$ln: unsafe \"wapp\" call: \"[string trim $x]\"\n"
      }
    }
  }
  return $res
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
  if {![dict exists $W .toread]} {
    # If the .toread key is not set, that means we are still reading
    # the header
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
      set len 0
      if {[dict exists $W .hdr:CONTENT-LENGTH]} {
        set len [dict get $W .hdr:CONTENT-LENGTH]
      }
      if {$len>0} {
        dict set W .toread $len
      } else {
        wappInt-handle-request $chan
      }
    }
  } else {
    # If .toread is set, that means we are reading the query content.
    # Continue reading until .toread reaches zero.
    set got [read $chan [dict get $W .toread]]
    dict append W .post $got
    dict set W .toread [expr {[dict get $W .toread]-[string length $got]}]
    if {[dict get $W .toread]<=0} {
      wappInt-parse-post-data $chan
      wappInt-handle-request $chan
    }
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
  set uri1 [lindex $split_uri 1]
  dict set W QUERY_STRING $uri1
  foreach qterm [split $uri1 &] {
    set qsplit [split $qterm =]
    set nm [lindex $qsplit 0]
    if {[regexp {^[a-z][a-z0-9]*$} $nm]} {
      dict set W $nm [wappInt-url-decode [lindex $qsplit 1]]
    }
  }
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
  if {![dict exists $W .hdr:HOST]} {
    dict set W BASE_URL {}
  } elseif {[dict exists $W HTTPS]} {
    dict set W BASE_URL https://[dict get $W .hdr:HOST]
  } else {
    dict set W BASE_URL http://[dict get $W .hdr:HOST]
  }
  dict set W SELF_URL [dict get $W BASE_URL]/[dict get $W PATH_HEAD]
  if {[dict exists $W .hdr:COOKIE]} {
    foreach qterm [split [dict get $W .hdr:COOKIE] {;}] {
      set qsplit [split [string trim $qterm] =]
      set nm [lindex $qsplit 0]
      if {[regexp {^[a-z][-a-z0-9_]*$} $nm]} {
        dict set W $nm [wappInt-url-decode [lindex $qsplit 1]]
      }
    }
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
  dict set wapp .mimetype {text/html; charset=utf-8}
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
  if {[dict exists $wapp .new-cookies]} {
    foreach {nm val} [dict get $wapp .new-cookies] {
      if {[regexp {^[a-z][-a-z0-9_]*$} $nm]} {
        set val [wappInt-url-encode $val]
        puts $chan "Set-Cookie: $nm=$val; HttpOnly; Path=/\r"
      }
    }
  }
  puts $chan "Connection: Closed\r\n\r"
  puts $chan [dict get $wapp .reply]
  flush $chan
  wappInt-close-channel $chan
}

# Undo the www-url-encoded format.
#
# HT: This code stolen from ncgi.tcl
#
proc wappInt-url-decode {str} {
  set str [string map [list + { } "\\" "\\\\" \[ \\\[ \] \\\]] $str]
  regsub -all -- \
      {%([Ee][A-Fa-f0-9])%([89ABab][A-Fa-f0-9])%([89ABab][A-Fa-f0-9])} \
      $str {[encoding convertfrom utf-8 [DecodeHex \1\2\3]]} str
  regsub -all -- \
      {%([CDcd][A-Fa-f0-9])%([89ABab][A-Fa-f0-9])}                     \
      $str {[encoding convertfrom utf-8 [DecodeHex \1\2]]} str
  regsub -all -- {%([0-7][A-Fa-f0-9])} $str {\\u00\1} str
  return [subst -novar $str]
}

# Process POST data
#
proc wappInt-parse-post-data {chan} {
  upvar #0 wappInt-$chan W
  if {[dict exists $W .hdr:CONTENT-TYPE]
      && [dict get $W .hdr:CONTENT-TYPE]=="application/x-www-form-urlencoded"} {
    foreach qterm [split [string trim [dict get $W .post]] &] {
      set qsplit [split $qterm =]
      set nm [lindex $qsplit 0]
      if {[regexp {^[a-z][a-z0-9]*$} $nm]} {
        dict set W $nm [wappInt-url-decode [lindex $qsplit 1]]
      }
    }
    return
  }
  # TODO: Decode multipart/form-data
}

# Data for doing url-encoding.
#
array set wappInt-map {
  \000 %00 \001 %01 \002 %02 \003 %03 \004 %04 \005 %05 \006 %06 \007 %07
  \010 %08 \011 %09 \012 %0A \013 %0B \014 %0C \015 %0D \016 %0E \017 %0F
  \020 %10 \021 %11 \022 %12 \023 %13 \024 %14 \025 %15 \026 %16 \027 %17
  \030 %18 \031 %19 \032 %1A \033 %1B \034 %1C \035 %1D \036 %1E \037 %1F
  { } + \041 %21 \042 %22 \043 %23 \044 %24 \045 %25 \046 %26 \047 %27
  \050 %28 \051 %29 \052 %2A \053 %2B \054 %2C \055 %2D \056 %2E \057 %2F
  \072 %3A \073 %3B \074 %3C \075 %3D \076 %3E \077 %3F \100 %40 \133 %5B
  \134 %5C \135 %5D \136 %5E \137 %5F \140 %60 \173 %7B \174 %7C \175 %7D
  \176 %7E \177 %7F \200 %80 \201 %81 \202 %82 \203 %83 \204 %84 \205 %85
  \206 %86 \207 %87 \210 %88 \211 %89 \212 %8A \213 %8B \214 %8C \215 %8D
  \216 %8E \217 %8F \220 %90 \221 %91 \222 %92 \223 %93 \224 %94 \225 %95
  \226 %96 \227 %97 \230 %98 \231 %99 \232 %9A \233 %9B \234 %9C \235 %9D
  \236 %9E \237 %9F \240 %A0 \241 %A1 \242 %A2 \243 %A3 \244 %A4 \245 %A5
  \246 %A6 \247 %A7 \250 %A8 \251 %A9 \252 %AA \253 %AB \254 %AC \255 %AD
  \256 %AE \257 %AF \260 %B0 \261 %B1 \262 %B2 \263 %B3 \264 %B4 \265 %B5
  \266 %B6 \267 %B7 \270 %B8 \271 %B9 \272 %BA \273 %BB \274 %BC \275 %BD
  \276 %BE \277 %BF \300 %C0 \301 %C1 \302 %C2 \303 %C3 \304 %C4 \305 %C5
  \306 %C6 \307 %C7 \310 %C8 \311 %C9 \312 %CA \313 %CB \314 %CC \315 %CD
  \316 %CE \317 %CF \320 %D0 \321 %D1 \322 %D2 \323 %D3 \324 %D4 \325 %D5
  \326 %D6 \327 %D7 \330 %D8 \331 %D9 \332 %DA \333 %DB \334 %DC \335 %DD
  \336 %DE \337 %DF \340 %E0 \341 %E1 \342 %E2 \343 %E3 \344 %E4 \345 %E5
  \346 %E6 \347 %E7 \350 %E8 \351 %E9 \352 %EA \353 %EB \354 %EC \355 %ED
  \356 %EE \357 %EF \360 %F0 \361 %F1 \362 %F2 \363 %F3 \364 %F4 \365 %F5
  \366 %F6 \367 %F7 \370 %F8 \371 %F9 \372 %FA \373 %FB \374 %FC \375 %FD
  \376 %FE \377 %FF
}

# Do URL encoding
#
proc wappInt-url-encode {str} {
  upvar #0 wappInt-map map
  regsub -all -- \[^a-zA-Z0-9\] $str {$map(&)} str
  regsub -all -- {[][{})\\]\)} $str {\\&} str
  return [subst -nocommand $str]
}
