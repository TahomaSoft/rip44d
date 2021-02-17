#!/usr/bin/perl

#
# rip44d
#
# A naive custom RIPv2 daemon to receive RIP updates from the
# 44/8 ampr.org routing service, and insert them in the
# Linux routing table.
#
#
# This software is free.
# It is licensed under the EVVKTVH / ICCLEIYSIUYA license
# (public domain, no warranty of any sort).
# http://evvk.com/evvktvh.html#english
#
#
# Version history:
#
# v1.0 - 2011-09-13 Heikki Hannikainen, OH7LZB
#	* Initial published version
#
# v1.1 - 2011-09-14 Heikki Hannikainen, OH7LZB
#	* Enable multicast on the tunnel interface automatically
#
# v1.2 - 2012-01-01 Ronald Jochems, PD1ACF and Heikki Hannikainen, OH7LZB
#	* Added syslog functionality, using module: http://perldoc.perl.org/Sys/Syslog.html
#	* Fixed to use CIDR format when calling /sbin/ip, to support older distributions
#
# v1.3 - 2013-04-11 Heikki Hannikainen, OH7LZB
#	* write pid file and lock it to prevent running multiple copies
#	* fix a bug in interim version after 1.2: added routes with wrong prefix length
#
# v1.4 - 2013-10-01 Heikki Hannikainen, OH7LZB
#	* Set up an initial dummy route for 44.0.0.1 at startup to prevent
#	  rp_filter from dropping incoming RIP packets
#

# Things to do in the future:
#
# - support for better authentication, if one would be supported
# - support for multiple RIP masters, to fix the single point of failure
# - support for sig-hup message, to remove the routing entries again without manual intervention
#

use strict;
use warnings;

use IO::Socket::Multicast;
use Getopt::Std;
use Sys::Syslog;
use Fcntl qw(:flock);

use constant {
	RIP_HDR_LEN => 4,
	RIP_ENTRY_LEN => 2+2+4*4,
	RIP_CMD_REQUEST => 1,
	RIP_CMD_RESPONSE => 2,
	RIP_AUTH_PASSWD => 2,
	AF_INET => 2,
};

my $rip_passwd;
my $tunnel_if = 'tunl0';
my $route_table = '';
my $routebin = '/sbin/ip';
my $ifconfig = '/sbin/ifconfig';
my $pidfile = '/var/run/rip44d.pid';
my $verbose = 0;
my $udp_port = 520;
my $log_syslog = 0;
# Local gateway addresses (whose routes are skipped)
my %my_addresses;
# Allowed route destination networks
my $net_44_regexp = '^44\.';
# We do not accept routes less specific than /14
my $minimum_prefix_len = 14;
# tcp window to set
my $tcp_window = 840;
# time (in seconds) to use routes which are no longer advertised
# - this is set to a large value, so that if the rip advertisements
# from mirrorshades stop, the network won't go down right away.
my $route_ttl = 7*24*60*60;

my %current_routes;

my $me = 'rip44d';
my $VERSION = '1.4';

# help and version texts
$Getopt::Std::STANDARD_HELP_VERSION = 1;

# This subroutine takes care of placing messages on std output, and also into syslog facility

sub do_syslog($)
{
	my($logtxt) = @_;
	
	if ($log_syslog) {
		syslog("info", "%s", $logtxt);
	} else {
		warn "$logtxt\n";
	}
}

sub HELP_MESSAGE($)
{
	my($fh) = @_;
	
	print $fh "Usage:\n"
		. "  $me [-v] [-d] [-s] [-i <tunnelif>] [-a <localaddrs>] [-p <password>]\n"
		. "      [-t <routingtable>] [-l <pidlockfile>]\n"
		. "Options:\n"
		. "  -v   increase verbosity slightly to print error messages on stderr\n"
		. "  -d   increase verbosity greatly (debug mode)\n"
		. "  -s   log to syslog instead of stderr\n"
		. "  -i <tunnelinterface>\n"
		. "       use the specified tunnel interface, defaults to tunl0\n"
		. "  -a <comma-separated-ip-list>\n"
		. "       ignore routes pointing to these (local) gateways\n"
		. "       (list contains system's local IP addresses by default)\n"
		. "  -p <password>\n"
		. "       use RIPv2 password 'authentication', defaults to none\n"
		. "  -t <routingtable>\n"
		. "       insert routes in an alternate named routing table\n"
		. "       (ip route add .. table <routingtable>)\n"
		. "  -l <pidlockfile>\n"
		. "       write process ID to given file instead of default\n"
		. "       (/var/run/rip44d.pid)\n"
		;
}

sub VERSION_MESSAGE()
{
	my($fh) = @_;
	
	print $fh "$me version $VERSION\n";
}

# write and lock pid file

sub writepid($)
{
	my($f) = @_;
	open(PF, ">>$f") || die "Could not open $f for writing pid: $!";
	my $ofh = select(PF); $| = 1; select($ofh); # autoflush
	flock(PF, LOCK_EX|LOCK_NB) || die "Could not flock pid file (other copy already running?): $!";
	truncate(PF, 0) || die "Could not truncate pid file: $!";
	seek(PF, 0, 0) || die "Could not seek to beginning of pid file: $!";
	print PF "$$\n" || die "Could not write pid to $f: $!";
}

# Figure out local interface IP addresses so that routes to them can be ignored

sub fill_local_ifs()
{
	my $s = `$ifconfig -a`;
	
	while ($s =~ s/inet addr:(\d+\.\d+\.\d+\.\d+)//) {
		do_syslog("found local address: $1") if ($verbose);
		$my_addresses{$1} = 1;
	}
}

# Convert a netmask (in integer form) to the corresponding prefix length,
# and validate it too. This is a bit ugly, optimizations are welcome.

sub mask2prefix($)
{
	my($mask) = @_; # integer
	
	# convert to a string of 1's and 0's, like this (/25):
	# 11111111111111111111111110000000
	my($bits) = unpack("B32", pack('N', $mask));
	
	# There should be a continuous row of 1's in the
	# beginning, and a continuous row of 0's in the end.
	# Regexp is our hammer, again.
	return -1 if ($bits !~ /^(1*)(0*)$/);
	
	# The amount of 1's in the beginning is the prefix length.
	return length($1);
}

# delete a route from the kernel's table

sub route_delete($)
{
	my($rkey) = @_;
	
	# This is ugly and slow - we fork /sbin/ip twice for every route change.
	# Should talk to the netlink device instead, but this is easier to
	# do right now, and good enough for this little routing table.
	my($out, $cmd);
	$cmd = "LANG=C $routebin route del $rkey $route_table";
	$out = `$cmd 2>&1`;
	if ($?) {
		if ($verbose > 1 || $out !~ /No such process/) {
			do_syslog("route del failed: '$cmd': $out");
		}
	}
}

# expire old routes

sub expire_routes()
{
	do_syslog("expiring old routes") if ($verbose);
	
	my $exp_t = time() - $route_ttl;
	my $now = time();
	
	foreach my $rkey (keys %current_routes) {
		if ($current_routes{$rkey}->{'t'} < $exp_t) {
			# expire route
			do_syslog("route $rkey has expired, deleting") if ($verbose);
			route_delete($rkey);
			delete $current_routes{$rkey};
		} elsif ($current_routes{$rkey}->{'t'} > $now) {
			# clock has jumped backwards, the time is in
			# the future - set 't' to $now so that the route
			# will be expired eventually
			$current_routes{$rkey}->{'t'} = $now;
		}
	}
}

# Consider adding a route in the routing table

sub consider_route($$$$$)
{
	my($net, $mask, $plen, $nexthop, $rtag) = @_;
	
	my $rkey = "$net/$plen";
	if (defined $current_routes{$rkey}
		&& $current_routes{$rkey}->{'nh'} eq $nexthop
		&& $current_routes{$rkey}->{'rtag'} eq $rtag) {
		# ok, current route is fine
		do_syslog("route $rkey is installed and current") if ($verbose > 1);
		$current_routes{$rkey}->{'t'} = time();
		return;
	}
	
	do_syslog("route $rkey updated: via $nexthop rtag $rtag") if ($verbose > 1);
	
	$current_routes{$rkey} = {
		'nh' => $nexthop,
		'rtag' => $rtag,
		't' => time()
	};
	
	# now go and update the routing table
	route_delete($rkey);
	my($out, $cmd);
	$cmd = "LANG=C $routebin route add $rkey via $nexthop dev $tunnel_if window $tcp_window onlink $route_table";
	$out = `$cmd 2>&1\n`;
	if ($?) {
		do_syslog("route add failed: '$cmd': $out");
	}
}

# process a RIPv2 password authentication entry

sub process_rip_auth_entry($)
{
	my($entry) = @_;
	
	my $e_af = unpack('n', substr($entry, 0, 2));
	if ($e_af != 0xFFFF) {
		do_syslog("RIPv2 first message does not contain auth password: ignoring") if ($verbose);
		return 0;
	}
	
	my $e_type = unpack('n', substr($entry, 2, 2));
	if ($e_type != RIP_AUTH_PASSWD) {
		do_syslog("ignoring unsupported rip auth type $e_type") if ($verbose);
		return 0;
	}
	
	my $e_passwd = substr($entry, 4, 16);
	$e_passwd =~ s/\0*$//; # it's null-padded in the end
	
	if (!defined $rip_passwd) {
		do_syslog("RIPv2 packet contains password $e_passwd but we require none") if ($verbose);
		return 0;
	}
	
	if ($e_passwd ne $rip_passwd) {
		do_syslog("RIPv2 invalid password $e_passwd") if ($verbose);
		return 0;
	}
	
	return 1;
}

# validate a route entry, make sure we can rather safely
# insert it in the routing table

sub validate_route($$$$$$)
{
	my($e_net_i, $e_net_s, $e_netmask, $prefix_len, $e_netmask_s, $e_nexthop_s) = @_;
	
	# netmask is correct and not too wide
	if ($prefix_len < 0) {
		do_syslog("invalid netmask: $e_netmask_s") if ($verbose);
		return (0, 'invalid netmask');
	}
	
	if ($prefix_len < $minimum_prefix_len) {
		do_syslog("$e_net_s/$e_netmask_s => $e_nexthop_s blocked, prefix too short");
		return (0, 'prefix length too short');
	}
	
	# the network-netmask pair makes sense: network & netmask == network
	if (($e_net_i & $e_netmask) != $e_net_i) {
		#print "e_net '$e_net_i' e_netmask '$e_netmask' ANDs to " . ($e_net_i & $e_netmask) . "\n";
		do_syslog("$e_net_s/$e_netmask_s => $e_nexthop_s blocked, subnet-netmask pair does not make sense") if ($verbose);
		return (0, 'invalid subnet-netmask pair');
	}
	
	# network is in 44/8
	if ($e_net_s !~ /$net_44_regexp/) {
		do_syslog("$e_net_s/$e_netmask_s => $e_nexthop_s blocked, non-amprnet address") if ($verbose);
		return (0, 'net not in 44/8');
	}
	
	# nexthop address is not in 44/8
	if ($e_nexthop_s =~ /$net_44_regexp/) {
		do_syslog("$e_net_s/$e_netmask_s => $e_nexthop_s blocked, nexthop is within amprnet") if ($verbose);
		return (0, 'nexthop is in 44/8');
	}
	
	# nexthop address does not point to self
	if (defined $my_addresses{$e_nexthop_s}) {
		do_syslog("$e_net_s/$e_netmask_s => $e_nexthop_s blocked, local gw") if ($verbose);
		return (0, 'local gw');
	}
	
	return (1, 'ok');
}

# process a RIPv2 route entry

sub process_rip_route_entry($)
{
	my($entry) = @_;
	
	my $e_af = unpack('n', substr($entry, 0, 2));
	my $e_rtag = unpack('n', substr($entry, 2, 2));

	if ($e_af == 0xFFFF) {
		process_rip_auth_entry($entry);
		return -1;
	}
	
	if ($e_af != AF_INET) {
		do_syslog("$me: RIPv2 entry has unsupported AF $e_af");
		return 0;
	}
	
	my $e_net = substr($entry, 4, 4);
	my $e_net_i = unpack('N', $e_net);
	my $e_netmask = substr($entry, 8, 4);
	my $e_netmask_i = unpack('N', $e_netmask);
	my $e_nexthop = substr($entry, 12, 4);
	my $e_metric = unpack('N', substr($entry, 16, 4));
	my $e_net_s = inet_ntoa($e_net);
	my $e_netmask_s = inet_ntoa($e_netmask);
	my $e_nexthop_s = inet_ntoa($e_nexthop);
	my $e_prefix_len = mask2prefix($e_netmask_i);
	
	# Validate the route
	my($result, $reason) = validate_route($e_net_i, $e_net_s, $e_netmask_i, $e_prefix_len, $e_netmask_s, $e_nexthop_s);
	if (!$result) {
		do_syslog("entry ignored ($reason): af $e_af rtag $e_rtag $e_net_s/$e_netmask_s via $e_nexthop_s metric $e_metric") if ($verbose);
		return 0;
	}
	
	do_syslog("entry: af $e_af rtag $e_rtag $e_net_s/$e_netmask_s via $e_nexthop_s metric $e_metric") if ($verbose > 1);
	
	# Ok, we have a valid route, consider adding it in the kernel's routing table
	consider_route($e_net_s, $e_netmask_s, $e_prefix_len, $e_nexthop_s, $e_rtag);
	
	return 1;
}

# process a RIP message

sub process_msg($$$)
{
	my($addr_s, $perr_port, $msg) = @_;
	
	# validate packet's length
	if (length($msg) < RIP_HDR_LEN + RIP_ENTRY_LEN) {
		do_syslog("$me: ignored too short packet from $addr_s: " . length($msg));
		return -1;
	}
	
	if (length($msg) > RIP_HDR_LEN + RIP_ENTRY_LEN*25) {
		do_syslog("$me: ignored too long packet from $addr_s: " . length($msg));
		return -1;
	}
	
	# packet's length must be divisible by the length of an entry
	if ((length($msg) - RIP_HDR_LEN) % RIP_ENTRY_LEN != 0) {
		do_syslog("$me: ignored invalid length packet from $addr_s: " . length($msg));
		return -1;
	}
	
	# validate RIP packet header
	my $hdr = substr($msg, 0, 4);
	my $entries = substr($msg, 4);
	
	my($rip_command, $rip_version, $zero1, $zero2) = unpack('C*', $hdr);
	if ($rip_command != RIP_CMD_RESPONSE) {
		do_syslog("$me: ignored non-response RIP packet from $addr_s");
		return -1;
	}
	if ($rip_version != 2) {
		do_syslog("$me: ignored RIP version $rip_version packet from $addr_s (only accept v2)");
		return -1;
	}
	if ($zero1 != 0 || $zero2 != 0) {
		do_syslog("$me: ignored RIP packet from $addr_s: zero bytes are not zero in header");
		return -1;
	}
	
	my $init_msg = 0;
	
	# if password auth is required, require it!
	if (defined $rip_passwd) {
		return -1 if (!process_rip_auth_entry(substr($entries, 0, RIP_ENTRY_LEN)));
		$init_msg += RIP_ENTRY_LEN;
	}
	
	# Ok, process the actual route entries
	my $routes = 0;
	for (my $i = $init_msg; $i < length($entries); $i += RIP_ENTRY_LEN) {
		my $entry = substr($entries, $i, RIP_ENTRY_LEN);
		my $n = process_rip_route_entry($entry);
		return -1 if ($n < 0);
		$routes += $n;
	}
	
	return $routes;
}

#
####### main #############################################
#

# command line parsing
my %opts;
getopts('i:p:l:a:t:vhds', \%opts);

if (defined $opts{'i'}) {
	$tunnel_if = $opts{'i'};
}
if (defined $opts{'p'}) {
	$rip_passwd = $opts{'p'};
}
if (defined $opts{'l'}) {
	$pidfile = $opts{'l'};
}
if (defined $opts{'t'}) {
	$route_table = " table " . $opts{'t'};
}
if ($opts{'v'} && !$verbose) {
	$verbose = 1;
}
if ($opts{'d'}) {
	$verbose = 2;		
}
if ($opts{'s'}) {
	$log_syslog = 1;		
}
if ($opts{'a'}) {
	foreach my $a (split(',', $opts{'a'})) {
		$my_addresses{$a} = 1;
	}
}
if ($opts{'h'}) {
	HELP_MESSAGE(*STDOUT);
	exit(0);
}

openlog($me, 'cons,pid', 'user') if ($log_syslog);
writepid($pidfile);

fill_local_ifs();

# Enable multicast on the tunnel interface, the flag is
# not set by default
system($ifconfig, $tunnel_if, 'multicast') == 0 or die "ifconfig $tunnel_if multicast failed: $?\n";

# Create the UDP multicast socket to receive RIP broadcasts
do_syslog("opening UDP socket $udp_port...") if ($verbose);
my $socket = IO::Socket::Multicast->new(
	LocalPort => $udp_port,
	ReuseAddr => 1,
) or die $!;

$socket->mcast_add('224.0.0.9', $tunnel_if) or die $!;

# Set up a route pointing towards amprgw on the tunnel interface,
# so that rp_filter (strict reverse path filtering) will not
# make the kernel drop packets.
my $init_r_cmd = "LANG=C $routebin route add 44.0.0.1/32 dev $tunnel_if $route_table";
my $init_r_out = `$init_r_cmd 2>&1\n`;

# when to expire old routes
my $expire_interval = 60*60;
my $next_expire = time() + $expire_interval;

# Main loop: receive broadcasts, check that they're from the correct
# address and port, and pass them on to processing
do_syslog("entering main loop, waiting for RIPv2 datagrams") if ($verbose);
while (1) {
	my $msg;
	my $remote_address = recv($socket, $msg, 1500, 0);
	
	if (!defined $remote_address) {
		next;
	}
	
	my ($peer_port, $peer_addr) = unpack_sockaddr_in($remote_address);
	my $addr_s = inet_ntoa($peer_addr);
	
	if ($addr_s ne '44.0.0.1' || $peer_port ne 520) {
		do_syslog("ignored packet from $addr_s: $peer_port: " . length($msg) );
		next;
	}
	
	do_syslog("received from $addr_s: $peer_port: " . length($msg) . " bytes") if ($verbose);
	
	my $routes = process_msg($addr_s, $peer_port, $msg);
	do_syslog("processed $routes route entries") if ($verbose && $routes >= 0);
	
	# Consider expiring old routes. This is actually never run if we do not receive
	# any RIP broadcasts at all (the recv() is blocking)
	# The (desired) side effect is that if the RIP announcer
	# dies, the entries do not time out.
	if (time() > $next_expire || $next_expire > time() + $expire_interval) {
		$next_expire = time() + $expire_interval;
		expire_routes();
	}
}

# currently we never, ever get here, but in case a 'last' would appear above:
closelog() if ($log_syslog);

