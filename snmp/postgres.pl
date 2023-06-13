#!/usr/bin/env perl

=head1 DESCRIPTION

This is a SNMP extend for monitoring Postgres via LibreNMS using SNMP.

For more information, see L<https://docs.librenms.org/#Extensions/Applications/#Postgres>.

=head1 SWITCHES

=head2 -p

Pretty print the JSON. If used with -b, this switch will be ignored.

=head2 -b

Gzip the output and convert to Base64.

=head2 -c <config>

Config TOML.

Default: /usr/local/etc/librenms_pg_extend.toml

=head2 -h

Print help.

=head2 -v

Print version.

=head1 Config TOML Keys

    - dsn :: DSN to use for connection.
        Default :: "dbi:Pg:dbname=postgres"

    - user :: User to use.
        Default :: ""

    - pass :: Password to use.
        Default :: ""

Or...

    dsn="dbi:Pg:dbname=postgres"
    user=""
    pass=""

=cut

use strict;
use warnings;
use JSON;
use DBI;
use Getopt::Std;
use File::Slurp;
use MIME::Base64;
use Gzip::Faster;
use TOML qw(from_toml);

# the version of this extend
my $extend_version = 1;

sub main::VERSION_MESSAGE {
	print "Postgres stats extend 0.0.1\n";
}

sub main::HELP_MESSAGE {
	&main::VERSION_MESSAGE;
	print '
-p             Pretty print the results.
-b             Optionally Gzip+Base64 the results.
-c <config>    Config TOML.
               Default: /usr/local/etc/librenms_pg_extend.toml

Config TOML Keys
- dsn :: DSN to use for connection.
    Default :: "dbi:Pg:dbname=postgres"

- user :: User to use.
    Default :: ""

- pass :: Password to use.
    Default :: ""
';
} ## end sub main::HELP_MESSAGE

my %opts = ();
getopts( 'vpbhc:', \%opts );

if ( $opts{h} ) {
	&main::HELP_MESSAGE;
	exit;
}
if ( $opts{v} ) {
	&main::HELP_MESSAGE;
	exit;
}

# create the JSON handling object
my $j = JSON->new;
if ( $opts{p} && !$opts{b} ) {
	$j->pretty(1);
	$j->canonical(1);
}

# gets the config file to optionally use
my $config_file = '/usr/local/etc/librenms_pg_extend.toml';
if ( $opts{c} ) {
	$config_file = $opts{c};
}

# config defaults
my $user = '';
my $pass = '';
my $dsn  = 'dbi:Pg:dbname=postgres';
if ( -f $config_file ) {
	my ( $config, $err );
	eval {
		( $config, $err ) = from_toml( slurp($config_file) );
		unless ($config) {
			die "Error parsing toml: $err";
		}
	};
	if ($@) {
		print $j->encode(
			{
				data        => {},
				version     => $extend_version,
				error       => 1,
				errorString => $@,
			}
		) . "\n";
		exit 1;
	} ## end if ($@)
	if ( defined( $config->{dsn} ) ) {
		$dsn = $config->{dsn};
	}
	if ( defined( $config->{user} ) ) {
		$dsn = $config->{user};
	}
	if ( defined( $config->{pass} ) ) {
		$dsn = $config->{pass};
	}
} ## end if ( -f $config_file )

# attempt to connect
my $dbh;
eval { $dbh = DBI->connect( $dsn, $user, $pass, { PrintError => 0 } ) || die $DBI::errstr; };
if ($@) {
	print $j->encode(
		{
			data        => {},
			version     => $extend_version,
			error       => 2,
			errorString => $@,
		}
	) . "\n";
	exit 2;
} ## end if ($@)

# get the WAL info
my $sth = $dbh->prepare('select * from pg_stat_wal;');
$sth->execute;
my $wal = $sth->fetchrow_hashref;
delete( $wal->{stats_reset} );

# get the bgwriter info
$sth = $dbh->prepare('select * from pg_stat_bgwriter;');
$sth->execute;
my $bgwriter = $sth->fetchrow_hashref;
delete( $bgwriter->{stats_reset} );

# get the archiver info
$sth = $dbh->prepare('select * from pg_stat_archiver;');
$sth->execute;
my $archiver = $sth->fetchrow_hashref;
delete( $archiver->{stats_reset} );

# get the database stats
my $db_stats = {};
$sth = $dbh->prepare('select * from pg_stat_database;');
$sth->execute;
my $line;
while ( $line = $sth->fetchrow_hashref ) {
	delete( $line->{datid} );
	delete( $line->{stats_reset} );
	delete( $line->{checksum_last_failure} );
	my $db_name = $line->{datname};
	if ( !defined($db_name) ) {
		$db_name = '_________shared________';
	}
	delete( $line->{datname} );
	$db_stats->{$db_name} = $line;
} ## end while ( $line = $sth->fetchrow_hashref )

#gets the SLRU info
my $slru_stats;
$sth = $dbh->prepare('select * from pg_stat_slru;');
$sth->execute;
while ( $line = $sth->fetchrow_hashref ) {
	delete( $line->{stats_reset} );
	$slru_stats->{ $line->{name} } = $line;
	delete( $line->{name} );
}

# puts together the return and prints it if no optional compressing is being done
my $return_string = $j->encode(
	{

		data => {
			wal      => $wal,
			database => $db_stats,
			slru     => $slru_stats,
			bgwriter => $bgwriter,
			archiver => $archiver,
		},
		version     => $extend_version,
		error       => 0,
		errorString => ''
	}
);
if ( !$opts{p} && !$opts{b} ) {
	print $return_string. "\n";
	exit 0;
} elsif ( !$opts{b} ) {
	print $return_string;
	exit 0;
}

# handle optional compressing
my $compressed = encode_base64( gzip($return_string) );
$compressed =~ s/\n//g;
$compressed = $compressed . "\n";
if ( length($compressed) > length($return_string) ) {
	print $return_string. "\n";
} else {
	print $compressed;
}

exit 0;
