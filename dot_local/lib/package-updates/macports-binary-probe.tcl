package require macports
mportinit
foreach name $argv {
  if {[catch {
    lassign [mportlookup $name] found info
    if {$found eq ""} { error "not-found" }
    set m [mportopen [dict get $info porturl] [dict create subport $name]]
    set worker [ditem_key $m workername]
    set archive [$worker eval {get_portimage_name}]
    puts "$name\t[dict get $info version]\t$archive"
    mportclose $m
  } reason]} { puts "$name\tERROR" }
}
