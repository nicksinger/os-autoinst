#!/usr/bin/perl -w

# this class is what everyone else refers to as $bmwqemu::backend and its code runs
# in the main thread. But its main task is to start a 2nd thread and talk to it over
# a PIPE (thanks to perl's insane approach to threads).
# in that 2nd thread runs the actual backend, derived from backend::baseclass

package backend::driver;
use strict;
use threads;
use threads::shared;
use Carp;
use JSON qw( to_json );
use Data::Dumper;
use File::Path qw(remove_tree);

# TODO: move the whole printing out of bmwqemu
sub diag($) {
    my ($text) = @_;

    print "$text\n";
}

sub new {
    my ($class, $name) = @_;
    my $self = bless( { class => $class }, $class );

    require "backend/$name.pm";
    $self->{'backend'} = "backend::$name"->new();

    $self->start();

    return $self;
}

sub start() {
    my ($self) = @_;

    my $p1, my $p2;
    pipe( $p1, $p2 ) or die "pipe: $!";
    $self->{from_parent} = $p1;
    $self->{to_child}    = $p2;

    $p1 = undef;
    $p2 = undef;
    pipe( $p1, $p2 ) or die "pipe: $!";
    $self->{to_parent}  = $p2;
    $self->{from_child} = $p1;

    printf STDERR "$$: to_child %d, from_child %d\n", fileno( $self->{to_child} ), fileno( $self->{from_child} );

    my $tid = shared_clone( threads->create( \&_run, $self->{'backend'}, fileno( $self->{from_parent} ), fileno( $self->{to_parent} ) ) );
    $self->{runthread} = $tid;
}

# this is the backend thread
sub _run {
    my ($backend, $from_parent, $to_parent) = @_;

    $backend->run($from_parent, $to_parent);
}

sub stop {
    my $self = shift;
    my $cmd  = shift;

    return unless ( $self->{runthread} );

    if ($self->{from_child}) {
      $self->stop_thread();
      close( $self->{from_child} ) if $self->{from_child};
      $self->{from_child} = undef;
    }

    close( $self->{to_child} ) if ($self->{to_child});
    $self->{to_child} = undef;

    diag " waiting for thread to quit...";
    $self->{runthread}->join();
    $self->{runthread} = undef;
}

# new api

sub start_vm($) {
    my $self = shift;
    my $json = to_json( $self->get_info() );
    open( my $runf, ">", 'backend.run' ) or die "can not write 'backend.run'";
    print $runf "$json\n";
    close $runf;

    # remove old screenshots
    print "remove_tree $bmwqemu::screenshotpath\n";
    remove_tree($bmwqemu::screenshotpath);
    mkdir $bmwqemu::screenshotpath;

    $self->_send_json({ 'cmd' => "start_vm"} ) || die "failed to start VM";

    $self->post_start_hook();
    return 1;
}

sub stop_thread($) {
    my $self = shift;
    unlink('backend.run');
    $self->stop_vm();
}

sub get_info($) {
    my $self = shift;
    $self->{'infos'} ||= {
        'backend'      => $self->{'class'},
        'backend_info' => $self->get_backend_info()
    };
    return $self->{'infos'};
}

# new api end

sub send_key($) {
    my ( $self, $key ) = @_;
    return $self->_send_json({ 'cmd' => "send_key", 'arguments' => { 'key' => $key } });
}

sub type_string($$) {
    my ( $self, $text, $max_interval ) = @_;
    return unless ($text);
    return $self->_send_json({ 'cmd' => "type_string", 'arguments' => { 'text' => $text, 'max_interval' => $max_interval } });
}

sub mouse_button($$$) {
    my ( $self, $button, $bstate ) = @_;
    return $self->_send_json({ 'cmd' => "mouse_button", 'arguments' => { 'button' => $button, 'bstate' => $bstate } } );
}

sub mouse_hide(;$) {
    my ($self, $border_offset) = @_;
    $border_offset ||= 0;

    # TODO: come up with a better solution - this is qemu specific.
    my $counter = 0;
    my $rsp;
    while ( $counter < 10 ) {
        $rsp = $self->_send_json({ 'cmd' => "mouse_hide", 'arguments' => { 'border_offset' => $border_offset } } );
        last if $rsp->{absolute} ne '0';
        sleep 1;
        $counter++;
    }
    return $rsp;
}

sub AUTOLOAD {
    my ($self, $args) = @_;
    $args ||= {}; # default

    my $cmd = our $AUTOLOAD;
    $cmd =~ s,.*::,,;

    unless (ref($args) eq 'HASH') {
        die "we require a hash as arguments for $cmd";
    }

    #print "AUTOLOAD " . Dumper($self) . "\n";

    no strict 'refs';  # allow symbolic references
    *$AUTOLOAD = sub { return $self->_send_json({ 'cmd' => $cmd, 'arguments' => $args }); };
    goto &$AUTOLOAD;    # Restart the new routine.
}

# virtual methods end

sub _send_json {
    my $self = shift;
    my $cmd  = shift;

    my $json = JSON::encode_json($cmd);

    return undef unless ( $self->{to_child} );
    my $wb = syswrite( $self->{to_child}, "$json\n" );
    die "syswrite failed $!" unless ( $wb == length($json) + 1 );

    my $rsp = _read_json( $self->{from_child} );
    unless ($rsp) {
        close($self->{from_child});
        $self->{from_child} = undef;
        $self->stop();
        return undef;
    }
    return $rsp->{'rsp'};
}

# utility function
sub _read_json($) {
    my ($socket) = @_;

    my $rsp = '';
    my $s   = IO::Select->new();
    $s->add($socket);

    my $hash;

    # make sure we read the answer completely
    while ( !$hash ) {
        # starting a IPMI host can take a while, so we need to be patient
        my @res = $s->can_read(300);
        unless (@res) {
            backend::baseclass::write_crash_file();
            confess "ERROR: timeout reading JSON reply: $!\n";
        }
        my $qbuffer;
        my $bytes = sysread( $socket, $qbuffer, 1 );
        if ( !$bytes ) { diag("sysread failed: $!"); return undef; }
        $rsp .= $qbuffer;
        if ($rsp eq $backend::baseclass::MAGIC_PIPE_CLOSE_STRING) {
            return undef;
        }
        if ( $rsp !~ m/\n/ ) { next; }
        $hash = eval { JSON::decode_json($rsp); };
    }

    #print STDERR "read json " . JSON::to_json($hash) . "\n";
    return $hash;
}


1;
# vim: set sw=4 et:
