#!/usr/bin/perl

use strict;
use warnings;
use autodie;
use Data::Dumper;
use FindBin qw($Bin);
use JSON::XS;
use Getopt::Long;

BEGIN {
 push @INC, "$Bin";
}
use WebService::Docker::API;
use WebService::Docker::Info;
use Config::HostsFile;
use DFWFW::Config;
use DFWFW::Iptables;

local $| = 1;


my ($c_dry_run, $c_one_shot) = (0, 0);

  GetOptions ("dry-run" => \$c_dry_run,
              "one-shot"   => \$c_one_shot)
  or die("Usage: $0 [--dry-run] [--one-shot]");


my $dfwfw_conf;
my $iptables = new DFWFW::Iptables(\&mylog, $c_dry_run);

my $docker_info;

local $SIG{TERM} = sub {
  mylog("Received term signal, exiting");
  exit;
};
local $SIG{ALRM} = sub {
  mylog("Received alarm signal, rebuilding Docker configuration");
  ### Networks by name before: $docker_info->{'network_by_name'}
  fetch_docker_configuration();
};
local $SIG{HUP} = sub {
  mylog("Received HUP signal, rebuilding everything");
  return if(!on_hup(1));

  rebuild();
};


on_hup();

init_dfwfw_rules();

monitor_changes();

sub on_hup {
  my $safe = shift;

  return if(!parse_dfwfw_conf($safe));

  fetch_docker_configuration();
  init_user_rules();

  return 1;
}

sub rebuild {
  # this sub is called usually in context of LWP which hides the default exception outputs, so we workaround it here:
  eval {
    build_firewall_ruleset();
    build_container_aliases();
  };
  if($@) {
     mylog($@);
     die($@);
  }

}

sub dfwfw_already_initiated {
   my $chain = shift;
   my $table = shift || "filter";
   return 0 == system("iptables -n -t $table --list $chain >/dev/null 2>&1");
}

sub dfwfw_rules_head {
  my $cat = shift;
  my $stateful = shift;

  my $re = "################ $cat head:
-F $cat
";
$re.= "-A $cat -m state --state INVALID -j DROP
-A $cat -m state --state RELATED,ESTABLISHED -j ACCEPT
" if($stateful);

  $re .= "\n";

  return $re;
}

sub dfwfw_rules_tail {
  my $cat = shift;
  return "" if($cat eq "DFWFW_INPUT"); # exception

  return "################ $cat tail:
-A $cat -j DROP

";
}

sub init_user_rules {
  $dfwfw_conf->{'initialization'}->commit($docker_info, $iptables);
}

sub init_dfwfw_rules {


   if (!dfwfw_already_initiated("DFWFW_FORWARD")) {
     mylog("DFWFW_FORWARD chain not found, initializing");

     $iptables->commit_rules_table("filter", <<'EOF');
:DFWFW_FORWARD - [0:0]
-I FORWARD -j DFWFW_FORWARD
EOF
   }

   if (!dfwfw_already_initiated("DFWFW_INPUT")) {
     mylog("DFWFW_INPUT chain not found, initializing");

     $iptables->commit_rules_table("filter", <<'EOF');
:DFWFW_INPUT - [0:0]
-I INPUT -j DFWFW_INPUT
EOF
   }


   if (!dfwfw_already_initiated("DFWFW_POSTROUTING", "nat")) {
     mylog("DFWFW_POSTROUTING chain not found, initializing");

     $iptables->commit_rules_table("nat", <<"EOF");
:DFWFW_POSTROUTING - [0:0]
-I POSTROUTING -j DFWFW_POSTROUTING
-F DFWFW_POSTROUTING
-I DFWFW_POSTROUTING -o $dfwfw_conf->{'external_network_interface'} -j MASQUERADE
EOF

   }


   if (!dfwfw_already_initiated("DFWFW_PREROUTING", "nat")) {
     mylog("DFWFW_PREROUTING chain not found, initializing");

     $iptables->commit_rules_table("nat", <<"EOF");
:DFWFW_PREROUTING - [0:0]
-I PREROUTING -j DFWFW_PREROUTING
EOF

   }


}


sub event_cb {
   my $d = shift;

   return if($d->{'status'} !~ /^(start|die)$/);

   mylog("Docker event: $d->{'status'} of $d->{'from'}");
   fetch_docker_configuration();

   rebuild();
}

sub headers_cb {
   # first time HTTP headers arrived from the docker daemon
   # this is a tricky solution to reach a race condition free state

   rebuild();

}


sub monitor_changes {
   my $api = WebService::Docker::API->new($dfwfw_conf->{'docker_socket'});

   $api->set_headers_callback(\&headers_cb);
   $api->events(\&event_cb);
}



sub build_container_aliases {

   $dfwfw_conf->{'container_aliases'}->commit($docker_info);

}



sub build_firewall_ruleset {
  mylog("Rebuilding firewall ruleset...");

  my %rules;

  $rules{'filter'}  = dfwfw_rules_head("DFWFW_FORWARD", 1);
  $rules{'filter'} .= dfwfw_rules_head("DFWFW_INPUT");

  $rules{'nat'}     = dfwfw_rules_head("DFWFW_PREROUTING");

  $dfwfw_conf->{'container_to_container'}->build($docker_info, \%rules);
  $dfwfw_conf->{'container_to_wider_world'}->build($docker_info, \%rules);
  $dfwfw_conf->{'container_to_host'}->build($docker_info, \%rules);
  $dfwfw_conf->{'wider_world_to_container'}->build($docker_info, \%rules);
  $dfwfw_conf->{'container_dnat'}->build($docker_info, \%rules);

  # and the final rule just for sure.
  $rules{'filter'} .= dfwfw_rules_tail("DFWFW_FORWARD");

  $iptables->commit_rules(\%rules);

  $dfwfw_conf->{'container_internals'}->commit($docker_info, $iptables);

  if($c_one_shot) {
     mylog("Exiting, one-shot was specified");
     exit 0;
  }
}



sub parse_dfwfw_conf {
  my $safe = shift;

  eval {
     my $new_dfwfw_conf = new DFWFW::Config(\&mylog);
     # success
     $dfwfw_conf = $new_dfwfw_conf;
  }; 
  if($@) {
     if($safe) {
         print "Syntax error in configuration file:\n$@\n\nReverting to original config and not proceeding to firewall ruleset rebuild\n";
         return 0;
     }

     die $@;
  }

  return 1;
}

sub fetch_docker_configuration {

  mylog("Talking to Docker daemon to learn current network and container configuration");

  my $extra_info_needed = 
    (
     (($dfwfw_conf->{'container_internals'}->{'rules'})&&(scalar @{$dfwfw_conf->{'container_internals'}->{'rules'}})) 
     ||
     (($dfwfw_conf->{'container_aliases'}->{'rules'})&&(scalar @{$dfwfw_conf->{'container_aliases'}->{'rules'}})) 
    ) 
    ?
    1 : 0;

  $docker_info = new WebService::Docker::Info($dfwfw_conf->{'docker_socket'}, $extra_info_needed);

}

sub mylog {
  my $msg = shift;

  print ("[".localtime."] $msg\n");
}