package Apache::Session::Browseable::PgHstore;

use strict;

use Apache::Session;
use Apache::Session::Lock::Null;
use Apache::Session::Browseable::Store::Postgres;
use Apache::Session::Generate::SHA256;
use Apache::Session::Serialize::Hstore;

our $VERSION = '1.2.2';
our @ISA     = qw(Apache::Session);

sub populate {
    my $self = shift;

    $self->{object_store} =
      new Apache::Session::Browseable::Store::Postgres $self;
    $self->{lock_manager} = new Apache::Session::Lock::Null $self;
    $self->{generate}     = \&Apache::Session::Generate::SHA256::generate;
    $self->{validate}     = \&Apache::Session::Generate::SHA256::validate;
    $self->{serialize}    = \&Apache::Session::Serialize::Hstore::serialize;
    $self->{unserialize}  = \&Apache::Session::Serialize::Hstore::unserialize;

    return $self;
}

sub searchOn {
    my ( $class, $args, $selectField, $value, @fields ) = @_;
    $selectField =~ s/'/''/g;
    my $query =
      { query => "a_session -> '$selectField' =?", values => [$value] };
    return $class->_query( $args, $query, @fields );
}

sub searchOnExpr {
    my ( $class, $args, $selectField, $value, @fields ) = @_;
    $selectField =~ s/'/''/g;
    $value =~ s/\*/%/g;
    my $query =
      { query => "a_session -> '$selectField' like ?", values => [$value] };
    return $class->_query( $args, $query, @fields );
}

sub _query {
    my ( $class, $args, $query, @fields ) = @_;
    my %res = ();
    my $index =
      ref( $args->{Index} )
      ? $args->{Index}
      : [ split /\s+/, $args->{Index} ];

    my $dbh        = $class->_classDbh($args);
    my $table_name = $args->{TableName}
      || $Apache::Session::Store::DBI::TableName;

    my $sth;
    my $fields =
      join( ',', 'id', map { s/'//g; "a_session -> '$_' AS $_" } @fields );
    $sth =
      $dbh->prepare("SELECT $fields from $table_name where $query->{query}");
    $sth->execute( @{ $query->{values} } );

    # In this case, PostgreSQL change field name in lowercase
    my $res = $sth->fetchall_hashref('id') or return {};
    foreach (@fields) {
        if ( $_ ne lc($_) ) {
            foreach my $s ( keys %$res ) {
                $res->{$s}->{$_} = delete $res->{$s}->{ lc $_ };
            }
        }
    }
    return $res;
}

sub deleteIfLowerThan {
    my ( $class, $args, $rule ) = @_;
    my $query;
    if ( $rule->{or} ) {
        $query = join ' OR ',
          map { "cast(a_session -> '$_' as integer) < $rule->{or}->{$_}" }
          keys %{ $rule->{or} };
    }
    elsif ( $rule->{and} ) {
        $query = join ' AND ',
          map { "cast(a_session -> '$_' as integer) < $rule->{or}->{$_}" }
          keys %{ $rule->{or} };
    }
    if ( $rule->{not} ) {
        $query = "($query) AND "
          . join( ' AND ',
            map { "a_session -> '$_' <> '$rule->{not}->{$_}'" }
              keys %{ $rule->{not} } );
    }
    return 0 unless ($query);
    my $dbh        = $class->_classDbh($args);
    my $table_name = $args->{TableName}
      || $Apache::Session::Store::DBI::TableName;
    my $sth = $dbh->do("DELETE FROM $table_name WHERE $query");
    return 1;
}

sub get_key_from_all_sessions {
    my ( $class, $args, $data ) = @_;

    my $table_name = $args->{TableName}
      || $Apache::Session::Store::DBI::TableName;
    my $dbh = $class->_classDbh($args);
    my $sth;

    # Special case if all wanted fields are indexed
    if ( $data and ref($data) ne 'CODE' ) {
        $data = [$data] unless ( ref($data) );
        my $fields = join ',', map { s/'//g; "a_session -> '$_' AS $_" } @$data;
        $sth = $dbh->prepare("SELECT $fields from $table_name");
        $sth->execute;
        return $sth->fetchall_hashref('id');
    }
    $sth = $dbh->prepare_cached("SELECT id,a_session from $table_name");
    $sth->execute;
    my %res;
    while ( my @row = $sth->fetchrow_array ) {
        no strict 'refs';
        my $self = eval "&${class}::populate();";
        my $sub  = $self->{unserialize};
        my $tmp  = &$sub( { serialized => $row[1] } );
        if ( ref($data) eq 'CODE' ) {
            $tmp = &$data( $tmp, $row[0] );
            $res{ $row[0] } = $tmp if ( defined($tmp) );
        }
        elsif ($data) {
            $data = [$data] unless ( ref($data) );
            $res{ $row[0] }->{$_} = $tmp->{$_} foreach (@$data);
        }
        else {
            $res{ $row[0] } = $tmp;
        }
    }
    return \%res;
}

sub _classDbh {
    my ( $class, $args ) = @_;

    my $datasource = $args->{DataSource} or die "No datasource given !";
    my $username   = $args->{UserName};
    my $password   = $args->{Password};
    my $dbh =
      DBI->connect_cached( $datasource, $username, $password,
        { RaiseError => 1, AutoCommit => 1 } )
      || die $DBI::errstr;
}

1;
__END__

=head1 NAME

Apache::Session::Browseable::PgHstore - Hstore type support for
L<Apache::Session::Browseable::Postgres>

=head1 SYNOPSIS

Enable "hstore" extension in PostgreSQL database

  CREATE EXTENSION hstore;

Create table:

  CREATE TABLE sessions (
      id varchar(64) not null primary key,
      a_session hstore,
  );

Use it like L<Apache::Session::Browseable::Postgres> except that you don't
need to declare indexes

=head1 DESCRIPTION

Apache::Session::Browseable provides some class methods to manipulate all
sessions and add the capability to index some fields to make research faster.

Apache::Session::Browseable::PgHstore implements it for PosqtgreSQL databases
using "hstore" extension to be able to browse sessions.

=head1 SEE ALSO

L<http://lemonldap-ng.org>, L<Apache::Session::Postgres>

=head1 AUTHOR

Xavier Guimard, E<lt>x.guimard@free.frE<gt>

=head1 COPYRIGHT AND LICENSE

=encoding utf8

Copyright (C) 2009-2017 by Xavier Guimard
              2013-2017 by Clément Oudot

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.1 or,
at your option, any later version of Perl 5 you may have available.

=cut
