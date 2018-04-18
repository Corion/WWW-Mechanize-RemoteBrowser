package RemoteBrowser;
use strict;
use Moo 2;
no warnings 'experimental::signatures';
use feature 'signatures';
use IO::Async;
use Future;
use IO::Async::Loop;
use Net::Async::WebSocket::Server;
Net::Async::WebSocket::Server->VERSION(0.12); # fixes some errors with masked frames

use JSON 'encode_json', 'decode_json';

use Scalar::Util 'weaken';


has 'loop' => is => 'lazy', default => sub { IO::Async::Loop->new() };
has 'port' => is => 'ro', default => 3000;
has 'connection' => is => 'rw';

#sub connect( $self, $handler, $url, $logger=undef ) {
#    $logger ||= sub{};
#    die "Got an undefined endpoint" unless defined $url;
#    weaken $handler;
#
#    my $client;
#    $client = Net::Async::WebSocket::Client->new(
#        # Kick off the continous polling
#        on_frame => sub {
#            my( $connection, $message )=@_;
#			use Data::Dumper;
#			warn Dumper \@_;
#            #$handler->on_response( $connection, $message )
#        },
#    );
#    $self->loop->add( $client );
#    $self->{connection} ||= $client;
#
#    $logger->('debug',"Connecting to $url");
#    $client->connect( url => $url, on_connected => sub {
#        $logger->('info',"Connected to $url");
#    })->catch(sub{
#        #require Data::Dumper;
#        #warn "caught";
#        #warn Data::Dumper::Dumper( \@_ );
#        Future->fail( @_ );
#    });
#}

my $i = 0;
sub listen( $self, $port=$self->port ) {
    my $server; $server = Net::Async::WebSocket::Server->new(
        on_client => sub {
           my ( undef, $client ) = @_;
		   $self->connection( $client );

           $client->configure(
              on_text_frame => sub {
                 my ( $s, $frame ) = @_;
				 use Data::Dumper;
				 if( length( $frame ) == 4 and $frame eq 'ping' ) { # yeah, hand-rolled pings
                    $self->connection->send_text_frame( 'pong' );
                    return
                 };
				 warn Dumper $frame;
				 my $p = decode_json( $frame );
				 if( $p->{clientType}) {
                     # initial client connected
					 $self->send( {"success" => JSON::true() } ); # await browser.tabs.update({ "url": "about:blank" })' );
                 } elsif( $p->{response} ) {
                     print "Got response\n";
                     print Dumper $frame;
                     
				 } else {
				     # Try to send a command
					 #$self->send( {"success" => JSON::true() } ); # await browser.tabs.update({ "url": "about:blank" })' );
                     # browser.tabs.update({ url: 'https://intoli.com/blog' })
					 #$self->send( {"channel" => "evaluateInBackground", data => {'asyncFunction' => 'async (args) => (browser.tabs.create(args))', args =>[{ "url" => "https://datenzoo.de" }]}, messageIndex => $i++, response => JSON::false() } );
                     # get tab id
					 $self->send( {"channel" => "evaluateInContent", data => {'asyncFunction' => 'async (args) => (window.alert(args))', args =>["Hello"]}, messageIndex => $i++, response => JSON::false(), id => 1 } );
				 };
              },
           );
		   
        }
     );

    $self->loop->add( $server );

    $server->listen(
        service => $port,
    );
};

sub send( $self, $message ) {
    my $payload = encode_json( $message );
    $self->send_text( $payload )
}

sub send_text( $self, $message ) {
    print "==> $message\n";
    $self->connection->send_text_frame( $message )
}

sub close( $self ) {
    my $c = delete $self->{connection};
    $c->finish
        if $c;
    delete $self->{ua};
}

sub future( $self ) {
    my $res = $self->loop->new_future;
    return $res
}

sub connectionUrl( $self ) {
    sprintf 'ws://localhost:%d', $self->port;
};

package main;
use strict;

my $b = RemoteBrowser->new();
my $url = $b->connectionUrl;
$b->listen()->get;

my $sessionId = 666;
my $browserUrl = "file:///?remoteBrowserUrl=${url}&remoteBrowserSessionId=${sessionId}";

print "$browserUrl\n";

#$b->connect(undef, 'ws://localhost:8000')->get;

$b->loop->run;

# add contentScript to retrieve the DOM of a page
# (and other window properties)